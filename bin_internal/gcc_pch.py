#!/usr/bin/env python3
"""Linux の自動プリコンパイル済みヘッダーを用意する。

ソース先頭の無条件 #include が一致するグループに対し、GCC の .gch を
ライブラリ ルートの obj に 1 つ作る。利用側のコンパイルには -include を足す。
GCC はヘッダーの更新だけでは .gch を無効にしないため、依存ヘッダーの日時は
このスクリプトが比較する。
see: https://gcc.gnu.org/onlinedocs/gcc/Precompiled-Headers.html
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

# 収集中の Coverity と同じく、0 のときだけ自動 PCH を止める。
_DISABLE_VALUES = {"0"}
_INCLUDE_ENV_VARS = (
    "CPATH",
    "C_INCLUDE_PATH",
    "CPLUS_INCLUDE_PATH",
    "OBJC_INCLUDE_PATH",
)
_PATH_OPTIONS = (
    "-idirafter",
    "-iquote",
    "-isystem",
    "-imacros",
    "-include",
    "-I",
    "-B",
)
_OPTIONS_WITH_ARGUMENT = _PATH_OPTIONS + (
    "-D",
    "-MF",
    "-MQ",
    "-MT",
    "-U",
    "-o",
    "-x",
)
_GCH_STRIP_OPTIONS = {"-c", "-MD", "-MMD", "-MP"}
_GCH_STRIP_WITH_ARGUMENT = {"-MF", "-MQ", "-MT", "-o", "-x"}
_LOCK_TIMEOUT_SECONDS = 600
_PREDEF_SUFFIX = "/stdc-predef.h"


class GccPchError(RuntimeError):
    """自動 PCH の準備に失敗したことを表す。"""


def include_prefix(path: Path) -> list[str]:
    """ソース先頭の無条件 include だけを、出現順に返す。

    コメントと空行は飛ばす。マクロ、条件分岐、行継続、include 以外のトークンで止める。
    """
    try:
        lines = path.read_text(encoding="utf-8-sig").splitlines()
    except OSError:
        return []
    prefix: list[str] = []
    in_comment = False
    include_pattern = re.compile(r'^#\s*include\s*([<"][^>"]+[>"])\s*(?://.*)?$')
    for raw_line in lines:
        line = raw_line.strip()
        while True:
            if in_comment:
                end = line.find("*/")
                if end < 0:
                    line = ""
                    break
                line = line[end + 2 :].lstrip()
                in_comment = False
            elif line.startswith("/*"):
                in_comment = True
                line = line[2:]
            else:
                break
        if line == "":
            continue
        # 行継続はコメントや directive の解釈を変えるため、自動共有を打ち切る。
        if line.endswith("\\"):
            break
        if line.startswith("//"):
            continue
        matched = include_pattern.match(line)
        if matched:
            prefix.append(matched.group(1))
            continue
        break
    return prefix


def language_of(path: Path) -> str:
    """拡張子が .c のときだけ C とし、それ以外の翻訳単位は C++ とする。"""
    return "c" if path.suffix == ".c" else "cpp"


def _debug(message: str) -> None:
    if os.environ.get("MAKEFW_GCC_PCH_DEBUG") == "1":
        print(f"gcc-pch: {message}", file=sys.stderr)


def _which(compiler: str) -> Path:
    found = shutil.which(compiler)
    if found is None:
        raise GccPchError(f"コンパイラが見つかりません: {compiler}")
    return Path(found).resolve()


def _split_flags(tokens: list[str]) -> list[tuple[str, str | None]]:
    """オプションを (名前, 引数) に分ける。引数を取らないものは引数が None。"""
    parsed: list[tuple[str, str | None]] = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token in _OPTIONS_WITH_ARGUMENT and index + 1 < len(tokens):
            parsed.append((token, tokens[index + 1]))
            index += 2
            continue
        for name in _PATH_OPTIONS:
            if token.startswith(name) and len(token) > len(name):
                parsed.append((name, token[len(name) :]))
                break
        else:
            if token.startswith("-D") and len(token) > 2:
                parsed.append(("-D", token[2:]))
            elif token.startswith("-U") and len(token) > 2:
                parsed.append(("-U", token[2:]))
            else:
                parsed.append((token, None))
        index += 1
    return parsed


def _absolute_option_path(value: str, base: Path) -> str:
    path = Path(value)
    if path.is_absolute():
        return os.path.normpath(str(path))
    return os.path.normpath(str((base / path).resolve(strict=False)))


def _normalize_flags(tokens: list[str], base: Path) -> list[str]:
    """include 探索先を絶対パスにした、比較用のオプション列を返す。"""
    normalized: list[str] = []
    for name, argument in _split_flags(tokens):
        if argument is None:
            normalized.append(name)
            continue
        if name in _PATH_OPTIONS:
            normalized.append(name)
            normalized.append(_absolute_option_path(argument, base))
            continue
        if name in {"-D", "-U"}:
            normalized.append(f"{name}{argument}")
            continue
        normalized.append(name)
        normalized.append(argument)
    return normalized


def _flags_disable_pch(tokens: list[str]) -> bool:
    """先頭 include を奪う -include / -imacros があるときに True。"""
    return any(name in {"-include", "-imacros"} for name, _argument in _split_flags(tokens))


def _strip_gch_flags(tokens: list[str]) -> list[str]:
    """ヘッダーコンパイルに渡さない、出力先と依存ファイルのオプションを除く。"""
    kept: list[str] = []
    for name, argument in _split_flags(tokens):
        if name in _GCH_STRIP_OPTIONS or name in _GCH_STRIP_WITH_ARGUMENT:
            continue
        if name.startswith("-fdiagnostics-color"):
            continue
        if argument is None:
            kept.append(name)
        elif name in {"-D", "-U"}:
            kept.append(f"{name}{argument}")
        else:
            kept.append(name)
            kept.append(argument)
    return kept


def _env_identity() -> str:
    return "\n".join(f"{name}={os.environ.get(name, '')}" for name in _INCLUDE_ENV_VARS)


def _hash_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def _compiler_identity(compiler: Path) -> str:
    stat = compiler.stat()
    return f"{compiler}\n{stat.st_mtime_ns}"


def _quoted(include: str) -> bool:
    return include.startswith('"')


def _group_key(source: Path, prefix: list[str]) -> tuple[str, str, str]:
    directory = str(source.resolve().parent)
    language = language_of(source)
    first = prefix[0] if prefix else str(source.resolve())
    return directory, language, first


def group_sources(sources: list[str]) -> list[dict[str, object]]:
    """同じディレクトリ、言語、先頭 include のソースをまとめ、接頭辞は共通部分だけ残す。"""
    groups: dict[tuple[str, str, str], dict[str, object]] = {}
    order: list[tuple[str, str, str]] = []
    for name in sources:
        path = Path(name)
        prefix = include_prefix(path)
        key = _group_key(path, prefix)
        if key not in groups:
            groups[key] = {
                "sources": [],
                "prefix": list(prefix),
                "language": key[1],
                "directory": key[0],
            }
            order.append(key)
        group = groups[key]
        source_list = group["sources"]
        assert isinstance(source_list, list)
        source_list.append(name)
        current = group["prefix"]
        assert isinstance(current, list)
        limit = 0
        while limit < len(current) and limit < len(prefix) and current[limit] == prefix[limit]:
            limit += 1
        group["prefix"] = current[:limit]
    return [groups[key] for key in order]


def _select_peers(peers: list[str], source: str, test_names: set[str], for_test: bool) -> list[str]:
    language = language_of(Path(source))
    selected = []
    for peer in peers:
        path = Path(peer)
        if language_of(path) != language:
            continue
        if (path.name in test_names) != for_test:
            continue
        selected.append(peer)
    source_resolved = str(Path(source).resolve())
    if all(str(Path(peer).resolve()) != source_resolved for peer in selected):
        selected.append(source)
    return selected


def _strip_comments(text: str) -> str:
    without_block = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//.*?$", "", without_block, flags=re.M)


def _has_include_guard(path: Path) -> bool:
    """インクルード ガードか #pragma once があるヘッダーだけを境界にできる。"""
    try:
        data = path.read_bytes()
    except OSError:
        return False
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError:
        # システム ヘッダーには UTF-8 でないコメントが残ることがある。判定文字は ASCII なので latin-1 で読む。
        text = data.decode("iso-8859-1")
    stripped = _strip_comments(text)
    if re.search(r"^\s*#\s*pragma\s+once\b", stripped, flags=re.M):
        return True
    ifndef = re.search(r"^\s*#\s*ifndef\s+([A-Za-z_][A-Za-z0-9_]*)\b", stripped, flags=re.M)
    if ifndef and re.search(
        rf"^\s*#\s*define\s+{re.escape(ifndef.group(1))}\b", stripped, flags=re.M
    ):
        return True
    plain = re.search(
        r"^\s*#\s*if\s+!\s*defined\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)",
        stripped,
        flags=re.M,
    )
    if plain and re.search(
        rf"^\s*#\s*define\s+{re.escape(plain.group(1))}\b", stripped, flags=re.M
    ):
        return True
    return False


def _parse_include_trace(stderr: str) -> list[tuple[int, str]]:
    rows: list[tuple[int, str]] = []
    for line in stderr.splitlines():
        if not line or line[0] not in ".!x":
            continue
        depth = 0
        while depth < len(line) and line[depth] in ".!x":
            depth += 1
        if depth == 0 or depth >= len(line) or line[depth] != " ":
            continue
        rows.append((depth, line[depth + 1 :]))
    return rows


def _resolve_includes(
    compiler: str,
    flags: list[str],
    language: str,
    includes: list[str],
    source_directory: Path,
) -> list[Path] | None:
    """接頭辞の各 include が開くファイルを、GCC の探索順で返す。失敗時は None。"""
    probe = source_directory / f".makefw-pch-resolve-{os.getpid()}.c"
    probe.write_text("\n".join(f"#include {include}" for include in includes) + "\n", encoding="utf-8")
    header_language = "c" if language == "c" else "c++"
    command = [compiler, *flags, "-H", "-E", "-fsyntax-only", "-x", header_language, str(probe)]
    env = os.environ.copy()
    env["LC_ALL"] = "C.UTF-8"
    try:
        result = subprocess.run(
            command,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            env=env,
            check=False,
        )
    finally:
        probe.unlink(missing_ok=True)
    if result.returncode != 0:
        _debug(f"include の解決に失敗したため通常コンパイルに戻します: {result.stderr.strip()}")
        return None
    direct = [
        path
        for depth, path in _parse_include_trace(result.stderr)
        if depth == 1 and not path.endswith(_PREDEF_SUFFIX)
    ]
    if len(direct) != len(includes):
        _debug(
            "include の解決結果が接頭辞と一致しないため通常コンパイルに戻します: "
            f"{includes} -> {direct}"
        )
        return None
    return [Path(path) for path in direct]


def _usable_prefix(
    compiler: str,
    flags: list[str],
    language: str,
    prefix: list[str],
    source_directory: Path,
) -> tuple[list[str], list[Path]] | None:
    """ガードのないヘッダーを境界から外し、残った接頭辞と解決先を返す。"""
    if not prefix:
        return None
    resolved = _resolve_includes(compiler, flags, language, prefix, source_directory)
    if resolved is None:
        return None
    limit = len(prefix)
    for index, header in enumerate(resolved):
        if not _has_include_guard(header):
            limit = index
            break
    if limit == 0:
        return None
    return prefix[:limit], resolved[:limit]


def _synthetic_lines(includes: list[str], headers: list[Path]) -> list[str]:
    """引用符 include は合成ヘッダーの場所に依存しない絶対パスで書く。"""
    lines = []
    for include, header in zip(includes, headers):
        if _quoted(include):
            lines.append(f'#include "{header.as_posix()}"')
        else:
            lines.append(f"#include {include}")
    return lines


def _provisional_key(
    compiler: Path,
    flags: list[str],
    language: str,
    prefix: list[str],
    source_directory: Path,
    base: Path,
) -> str:
    """解決前のキャッシュ名。言語を省くと、同じ接頭辞の C と C++ が決定ファイルを共有する。"""
    quoted_context = str(source_directory) if any(_quoted(include) for include in prefix) else ""
    text = "\n".join(
        (
            _compiler_identity(compiler),
            language,
            "\n".join(_normalize_flags(flags, base)),
            "\n".join(prefix),
            quoted_context,
            _env_identity(),
        )
    )
    return _hash_text(text)


def _final_key(
    compiler: Path,
    flags: list[str],
    language: str,
    includes: list[str],
    source_directory: Path,
    base: Path,
) -> str:
    quoted_context = str(source_directory) if any(_quoted(include) for include in includes) else ""
    text = "\n".join(
        (
            _compiler_identity(compiler),
            language,
            "\n".join(_normalize_flags(flags, base)),
            "\n".join(includes),
            quoted_context,
            _env_identity(),
        )
    )
    return _hash_text(text)


def _with_lock(lock_path: Path):
    import fcntl

    lock_path.parent.mkdir(parents=True, exist_ok=True)
    handle = lock_path.open("a", encoding="utf-8")
    deadline = time.monotonic() + _LOCK_TIMEOUT_SECONDS
    while True:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            return handle
        except BlockingIOError:
            if time.monotonic() >= deadline:
                handle.close()
                raise GccPchError(f"PCH 作成ロックが時間内に取得できません: {lock_path}")
            time.sleep(0.2)


def _unlock(handle) -> None:
    import fcntl

    fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    handle.close()


def _parse_gcc_depfile(path: Path) -> list[Path]:
    text = path.read_text(encoding="utf-8")
    logical: list[str] = []
    pending = ""
    for line in text.splitlines():
        if line.endswith("\\"):
            pending += line[:-1] + " "
            continue
        pending += line
        logical.append(pending)
        pending = ""
    if not logical or ":" not in logical[0]:
        raise GccPchError(f"依存ファイルを解釈できません: {path}")
    _target, deps = logical[0].split(":", 1)
    words: list[str] = []
    token: list[str] = []
    index = 0
    while index < len(deps):
        char = deps[index]
        if char == "\\" and index + 1 < len(deps):
            token.append(deps[index + 1])
            index += 2
            continue
        if char in " \t":
            if token:
                words.append("".join(token))
                token = []
            index += 1
            continue
        token.append(char)
        index += 1
    if token:
        words.append("".join(token))
    return [Path(word).resolve(strict=False) for word in words]


def _gch_is_fresh(gch: Path, sidecar: Path) -> bool:
    if not gch.is_file() or not sidecar.is_file():
        return False
    try:
        lines = [line for line in sidecar.read_text(encoding="utf-8").splitlines() if line]
        headers = [Path(line) for line in lines]
    except (OSError, UnicodeError):
        return False
    if not headers:
        return False
    gch_time = gch.stat().st_mtime_ns
    for header in headers:
        if not header.is_file():
            return False
        if header.stat().st_mtime_ns > gch_time:
            return False
    return True


def _write_text_if_changed(path: Path, text: str) -> None:
    if path.is_file() and path.read_text(encoding="utf-8") == text:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(text, encoding="utf-8")
    os.replace(temporary, path)


def _compile_gch(
    compiler: str,
    flags: list[str],
    language: str,
    synthetic: Path,
    gch: Path,
    depfile: Path,
) -> list[Path]:
    header_language = "c-header" if language == "c" else "c++-header"
    temporary_gch = gch.with_name(gch.name + ".tmp")
    temporary_dep = depfile.with_name(depfile.name + ".tmp")
    command = [
        compiler,
        *_strip_gch_flags(flags),
        "-x",
        header_language,
        "-c",
        "-o",
        str(temporary_gch),
        str(synthetic),
        "-MMD",
        "-MP",
        "-MF",
        str(temporary_dep),
    ]
    _debug(" ".join(shlex.quote(part) for part in command))
    result = subprocess.run(command, stderr=subprocess.PIPE, check=False)
    stderr_bytes = result.stderr or b""
    if stderr_bytes:
        sys.stderr.buffer.write(stderr_bytes)
        sys.stderr.buffer.flush()
    if result.returncode != 0:
        temporary_gch.unlink(missing_ok=True)
        temporary_dep.unlink(missing_ok=True)
        raise GccPchError(f"PCH の作成に失敗しました: {synthetic}")
    try:
        headers = _parse_gcc_depfile(temporary_dep)
    except (OSError, GccPchError) as error:
        temporary_gch.unlink(missing_ok=True)
        temporary_dep.unlink(missing_ok=True)
        raise GccPchError(f"PCH の依存情報を読めません: {temporary_dep}") from error
    os.replace(temporary_gch, gch)
    os.replace(temporary_dep, depfile)
    _write_gch_warnings(gch, stderr_bytes)
    return headers


def _write_gch_warnings(gch: Path, stderr_bytes: bytes) -> None:
    """作成時の警告を auto_<識別子>.warn に残し、警告が無ければ消す。"""
    text = re.sub(r"\x1b\[[0-9;]*[mK]", "", stderr_bytes.decode("utf-8", errors="replace"))
    warnings = [line for line in text.splitlines() if re.search(r": (warning|警告)[ :]", line)]
    warn_path = gch.with_name(gch.name.removesuffix(".h.gch") + ".warn")
    if warnings:
        warn_path.write_text("\n".join(warnings) + "\n", encoding="utf-8")
        return
    warn_path.unlink(missing_ok=True)


def _load_decision(path: Path, prefix: list[str], language: str) -> dict[str, object] | None:
    if not path.is_file():
        return None
    try:
        decision = json.loads(path.read_text(encoding="utf-8"))
        headers = [Path(header) for header in decision["headers"]]
        includes = list(decision["includes"])
    except (OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError):
        return None
    if decision.get("language") != language:
        return None
    if includes != prefix[: len(includes)]:
        return None
    if includes and not isinstance(decision.get("lines"), list):
        return None
    if not includes:
        return decision
    decision_time = path.stat().st_mtime_ns
    for header in headers:
        if not header.is_file() or header.stat().st_mtime_ns > decision_time:
            return None
    return decision


def _write_outputs(arg_file: Path, dep_list: Path, include_path: Path | None, deps: list[Path]) -> None:
    arg_file.parent.mkdir(parents=True, exist_ok=True)
    if include_path is None:
        arg_file.write_text("", encoding="utf-8")
        dep_list.write_text("", encoding="utf-8")
        return
    arg_file.write_text(f"-include\n{include_path.as_posix()}\n", encoding="utf-8")
    body = "\n".join([include_path.with_name(include_path.name + ".gch").as_posix(), *[path.as_posix() for path in deps]])
    dep_list.write_text(body + "\n", encoding="utf-8")


def _min_sources(argument: int | None) -> int:
    if argument is not None:
        return argument
    raw = os.environ.get("MAKEFW_GCC_PCH_MIN_SOURCES")
    if raw:
        return int(raw)
    return 2


def prepare(arguments: argparse.Namespace) -> None:
    """このソースに使う -include と、オブジェクトへ足す依存をファイルへ書く。"""
    if os.environ.get("MAKEFW_GCC_PCH", "") in _DISABLE_VALUES:
        _debug("MAKEFW_GCC_PCH=0")
        _write_outputs(Path(arguments.arg_file), Path(arguments.dep_list), None, [])
        return
    flags = list(arguments.flags)
    if flags[:1] == ["--"]:
        flags = flags[1:]
    if _flags_disable_pch(flags):
        _debug("既存の -include または -imacros があるため自動 PCH を使いません")
        _write_outputs(Path(arguments.arg_file), Path(arguments.dep_list), None, [])
        return
    peers = _select_peers(arguments.peers, arguments.source, set(arguments.test_names), arguments.for_test)
    groups = group_sources(peers)
    source_resolved = str(Path(arguments.source).resolve())
    group = next(
        (
            item
            for item in groups
            if any(str(Path(name).resolve()) == source_resolved for name in item["sources"])
        ),
        None,
    )
    if group is None:
        _write_outputs(Path(arguments.arg_file), Path(arguments.dep_list), None, [])
        return
    prefix = list(group["prefix"])
    language = str(group["language"])
    source_directory = Path(str(group["directory"]))
    if not prefix:
        _debug(f"共通 include が無いため通常コンパイルにします: {arguments.source}")
        _write_outputs(Path(arguments.arg_file), Path(arguments.dep_list), None, [])
        return
    compiler = _which(arguments.compiler)
    base = Path.cwd()
    objdir = Path(arguments.objdir)
    if not objdir.is_absolute():
        objdir = base / objdir
    pch_root = Path(arguments.pch_root)
    if not pch_root.is_absolute():
        pch_root = base / pch_root
    shared_dir = (pch_root / Path(arguments.objdir).name).resolve()
    provisional = _provisional_key(compiler, flags, language, prefix, source_directory, base)
    decision_path = (objdir / f"gcc-pch-{provisional}.json").resolve()
    decision_lock = _with_lock(decision_path.with_suffix(".lock"))
    try:
        decision = _load_decision(decision_path, prefix, language)
        if decision is None:
            usable = _usable_prefix(compiler, flags, language, prefix, source_directory)
            if usable is None:
                decision = {"includes": [], "headers": [], "final": "", "language": language}
            else:
                kept, headers = usable
                final = _final_key(compiler, flags, language, kept, source_directory, base)
                decision = {
                    "includes": kept,
                    "headers": [header.as_posix() for header in headers],
                    "lines": _synthetic_lines(kept, headers),
                    "final": final,
                    "language": language,
                }
            _write_text_if_changed(
                decision_path, json.dumps(decision, ensure_ascii=False, indent=2) + "\n"
            )
    finally:
        _unlock(decision_lock)
    includes = list(decision.get("includes", []))
    if not includes:
        _debug(f"使える境界が無いため通常コンパイルにします: {arguments.source}")
        _write_outputs(Path(arguments.arg_file), Path(arguments.dep_list), None, [])
        return
    final = str(decision["final"])
    synthetic = shared_dir / f"auto_{final}.h"
    gch = shared_dir / f"auto_{final}.h.gch"
    sidecar = shared_dir / f"auto_{final}.deps"
    depfile = shared_dir / f"auto_{final}.d"
    gch_lock = _with_lock(shared_dir / f"auto_{final}.lock")
    try:
        minimum = _min_sources(arguments.min_sources)
        source_count = len(group["sources"])
        if not gch.is_file() and source_count < minimum:
            _debug(f"ソース数 {source_count} が下限 {minimum} 未満のため新規作成しません")
            _write_outputs(Path(arguments.arg_file), Path(arguments.dep_list), None, [])
            return
        if not _gch_is_fresh(gch, sidecar):
            lines = list(decision["lines"])
            _write_text_if_changed(synthetic, "\n".join(lines) + "\n")
            headers = _compile_gch(arguments.compiler, flags, language, synthetic, gch, depfile)
            sidecar.write_text("".join(f"{header.as_posix()}\n" for header in headers), encoding="utf-8")
        header_lines = [line for line in sidecar.read_text(encoding="utf-8").splitlines() if line]
        _write_outputs(
            Path(arguments.arg_file),
            Path(arguments.dep_list),
            synthetic,
            [Path(line) for line in header_lines],
        )
        _debug(f"use {gch}")
    finally:
        _unlock(gch_lock)


def _make_escape(path: str) -> str:
    return path.replace("$", "$$").replace("#", "\\#").replace(" ", "\\ ")


def record(arguments: argparse.Namespace) -> None:
    """gcc が書いた .d に、.gch とその中のヘッダーを前提条件として足す。"""
    dep_list = Path(arguments.dep_list)
    if not dep_list.is_file():
        return
    deps = [line for line in dep_list.read_text(encoding="utf-8").splitlines() if line]
    if not deps:
        return
    depfile = Path(arguments.dep)
    if depfile.is_file():
        text = depfile.read_text(encoding="utf-8")
        target = text.split(":", 1)[0].strip()
    else:
        if not arguments.target:
            raise GccPchError(f"依存ファイルが無く、ターゲットも指定されていません: {depfile}")
        text = ""
        target = _make_escape(arguments.target)
    if not target:
        raise GccPchError(f"依存ファイルのターゲットを読めません: {depfile}")
    escaped = [_make_escape(dep) for dep in deps]
    addition = f"{target}: {' '.join(escaped)}\n" + "".join(f"{dep}:\n" for dep in escaped)
    if text and not text.endswith("\n"):
        text += "\n"
    depfile.parent.mkdir(parents=True, exist_ok=True)
    depfile.write_text(text + addition, encoding="utf-8")


def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="GCC の自動 PCH を用意します。")
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare_parser = subparsers.add_parser("prepare")
    prepare_parser.add_argument("--compiler", required=True)
    prepare_parser.add_argument("--objdir", required=True)
    prepare_parser.add_argument("--pch-root", required=True)
    prepare_parser.add_argument("--source", required=True)
    prepare_parser.add_argument("--arg-file", required=True)
    prepare_parser.add_argument("--dep-list", required=True)
    prepare_parser.add_argument("--for-test", type=int, choices=(0, 1), default=0)
    prepare_parser.add_argument("--min-sources", type=int)
    prepare_parser.add_argument("--peer", dest="peers", action="append", default=[])
    prepare_parser.add_argument("--test-name", dest="test_names", action="append", default=[])
    prepare_parser.add_argument("flags", nargs=argparse.REMAINDER)
    prepare_parser.set_defaults(func=prepare)

    record_parser = subparsers.add_parser("record")
    record_parser.add_argument("--dep", required=True)
    record_parser.add_argument("--dep-list", required=True)
    record_parser.add_argument("--target", default="")
    record_parser.set_defaults(func=record)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    """コマンドの入口。"""
    arguments = _parse_args(sys.argv[1:] if argv is None else argv)
    try:
        arguments.for_test = bool(getattr(arguments, "for_test", 0))
        arguments.func(arguments)
    except (GccPchError, OSError, subprocess.SubprocessError) as error:
        print(f"gcc-pch: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
