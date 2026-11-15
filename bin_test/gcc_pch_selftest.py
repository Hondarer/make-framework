#!/usr/bin/env python3
"""GCC の自動 PCH と、Coverity 収集時の無効化を確認する。

Linux で実行する。一時ディレクトリのソースだけを使い、ワークスペースの成果物は変えない。
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
from contextlib import redirect_stdout
from io import StringIO
from unittest import mock

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bin_internal"))
import gcc_pch

# run-bin-tests.py が参照する。Linux の gcc と flock に依存する。
BIN_TEST_PLATFORM = "linux"

MAKEFW = Path(__file__).resolve().parents[1]
GCC_PCH = MAKEFW / "bin_internal" / "gcc_pch.py"
COV_WRAPPER = MAKEFW / "bin_internal" / "cov-build-app.sh"
FLAGS = ["-O2", "-g"]


def run(argv, **kwargs):
    result = subprocess.run(argv, capture_output=True, text=True, encoding="utf-8", **kwargs)
    if result.returncode:
        raise AssertionError(f"コマンド失敗: {argv}\n{result.stdout}\n{result.stderr}")
    return result


def invoke(argv):
    stdout = StringIO()
    with redirect_stdout(stdout):
        code = gcc_pch.main(argv)
    if code != 0:
        raise AssertionError(f"gcc_pch.py が失敗しました ({code}): {argv}")
    if stdout.getvalue():
        raise AssertionError(f"prepare/record が標準出力へ書きました: {stdout.getvalue()}")


class Tree:
    def __init__(self, root: Path, pch_root: Path | None = None):
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True)
        self.obj = root / "obj"
        self.obj.mkdir()
        self.pch_root = root if pch_root is None else pch_root
        (self.pch_root / "obj").mkdir(parents=True, exist_ok=True)

    def write(self, name: str, text: str) -> Path:
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    @property
    def shared(self) -> Path:
        return self.pch_root / self.obj.name

    def gchs(self) -> list[Path]:
        return sorted(self.shared.glob("auto_*.h.gch"))

    def prepare(self, source: Path, peers: list[Path], flags: list[str], min_sources: int = 2,
                compiler: str = "gcc", for_test: int = 0, test_names: tuple[str, ...] = ()) -> list[str]:
        arg = self.obj / f"{source.name}.pchargs"
        deps = self.obj / f"{source.name}.pchdeps"
        argv = [
            "prepare", "--compiler", compiler, "--objdir", str(self.obj),
            "--pch-root", str(self.pch_root), "--source", str(source),
            "--arg-file", str(arg), "--dep-list", str(deps),
            "--for-test", str(for_test), "--min-sources", str(min_sources),
        ]
        for peer in peers:
            argv.extend(["--peer", str(peer)])
        for name in test_names:
            argv.extend(["--test-name", name])
        argv.append("--")
        argv.extend(flags)
        invoke(argv)
        return arg.read_text(encoding="utf-8").splitlines()

    def compile(self, source: Path, flags: list[str], extra: list[str],
                compiler: str = "gcc", cwd: Path | None = None) -> tuple[Path, Path, str]:
        out = self.obj / f"{source.stem}.o"
        dep = self.obj / f"{source.stem}.d"
        argv = [
            compiler, "-MT", str(out), "-MMD", "-MP", "-MF", str(dep),
            *flags, *extra, "-H", "-c", "-o", str(out), str(source),
            "-fdiagnostics-color=always",
        ]
        result = run(argv, cwd=cwd)
        return out, dep, result.stderr


def assert_used(stderr: str, gch: Path) -> None:
    matched = [line for line in stderr.splitlines() if gch.name in line]
    if not matched or any(line.startswith("x") for line in matched):
        raise AssertionError(f"PCH が使われていません:\n{stderr}")
    if not any(line.startswith("!") for line in matched):
        raise AssertionError(f"PCH の使用印がありません:\n{stderr}")


def stamp_newer_than_headers(gch: Path) -> float:
    sidecar = gch.with_name(gch.name.removesuffix(".h.gch") + ".deps")
    headers = [Path(line) for line in sidecar.read_text(encoding="utf-8").splitlines() if line]
    newest = max(path.stat().st_mtime for path in headers)
    stamp = newest + 100
    os.utime(gch, (stamp, stamp))
    return stamp


def assert_kept(gch: Path, stamp: float) -> None:
    if abs(gch.stat().st_mtime - stamp) > 1:
        raise AssertionError(f"PCH を作り直しました: {gch}")


def assert_rebuilt(gch: Path, stamp: float) -> None:
    if abs(gch.stat().st_mtime - stamp) <= 1:
        raise AssertionError(f"PCH が古いままです: {gch}")


def check_normalize(root: Path) -> None:
    normalized = gcc_pch._normalize_flags(["-Irelative", "-DFOO=1", "-O2"], root)
    expected_dir = os.path.normpath(str((root / "relative").resolve()))
    if normalized != ["-I", expected_dir, "-DFOO=1", "-O2"]:
        raise AssertionError(f"フラグの正規化が不正です: {normalized}")
    split = gcc_pch._normalize_flags(["-D", "FOO=1", "-isystemrelative"], root)
    system_dir = os.path.normpath(str((root / "relative").resolve()))
    if split != ["-DFOO=1", "-isystem", system_dir]:
        raise AssertionError(f"分割フラグの正規化が不正です: {split}")
    print("PASS: フラグの正規化")


def check_prefix(root: Path) -> None:
    root.mkdir(parents=True)
    source = root / "sample.c"
    source.write_text(
        "/* block\n   comment */\n\n#include <first.h> // note\n#define STOP \\\n  1\n#include <second.h>\n",
        encoding="utf-8",
    )
    if gcc_pch.include_prefix(source) != ["<first.h>"]:
        raise AssertionError(f"接頭辞が不正です: {gcc_pch.include_prefix(source)}")
    stopped = root / "cond.c"
    stopped.write_text('#include "common.h"\n#if 0\n#include "other.h"\n#endif\n', encoding="utf-8")
    if gcc_pch.include_prefix(stopped) != ['"common.h"']:
        raise AssertionError("条件分岐の先を接頭辞に含めました")
    print("PASS: include 接頭辞")


def check_language_key() -> None:
    compiler = gcc_pch._which("gcc")
    base = Path("/tmp")
    prefix = ["<stdio.h>"]
    directory = Path("/tmp/src")
    flags = ["-O2"]
    c_key = gcc_pch._provisional_key(compiler, flags, "c", prefix, directory, base)
    cpp_key = gcc_pch._provisional_key(compiler, flags, "cpp", prefix, directory, base)
    if c_key == cpp_key:
        raise AssertionError("C と C++ の決定キャッシュ名が一致しました")
    print("PASS: 言語ごとの決定キャッシュ")


def common_headers(tree: Tree) -> None:
    tree.write("detail.h", "#pragma once\nstatic inline int detail_value(void) { return 4; }\n")
    tree.write("common.h", "#pragma once\n#include \"detail.h\"\n"
               "static inline int common_value(void) { return detail_value(); }\n")


def check_basic(root: Path) -> None:
    tree = Tree(root)
    common_headers(tree)
    a_c = tree.write("a.c", '#include "common.h"\nint from_a(void) { return common_value(); }\n')
    b_c = tree.write("b.c", '#include "common.h"\n#include <stdio.h>\n'
                     "int main(void) { printf(\"%d\\n\", common_value()); return 0; }\n")
    peers = [a_c, b_c]
    extra_a = tree.prepare(a_c, peers, FLAGS)
    extra_b = tree.prepare(b_c, peers, FLAGS)
    gch = tree.gchs()
    if len(gch) != 1 or extra_a[:1] != ["-include"] or extra_b[:1] != ["-include"]:
        raise AssertionError(f"PCH を 1 つ作れませんでした: {gch} {extra_a} {extra_b}")
    _obj_a, dep_a, stderr_a = tree.compile(a_c, FLAGS, extra_a)
    obj_b, _dep_b, stderr_b = tree.compile(b_c, FLAGS, extra_b)
    assert_used(stderr_a, gch[0])
    assert_used(stderr_b, gch[0])
    invoke(["record", "--dep", str(dep_a), "--dep-list", str(tree.obj / "a.c.pchdeps"), "--target", str(tree.obj / "a.o")])
    recorded = dep_a.read_text(encoding="utf-8")
    if gch[0].as_posix() not in recorded or "detail.h" not in recorded:
        raise AssertionError(f"依存へ PCH を追記できていません:\n{recorded}")
    program = root / "prog"
    run(["gcc", "-o", str(program), str(tree.obj / "a.o"), str(obj_b)])
    printed = run([str(program)]).stdout
    if printed != "4\n":
        raise AssertionError(f"実行結果が不正です: {printed}")
    stamp = stamp_newer_than_headers(gch[0])
    tree.prepare(a_c, peers, FLAGS)
    assert_kept(gch[0], stamp)
    a_c.write_text(a_c.read_text(encoding="utf-8") + "\n", encoding="utf-8")
    tree.prepare(a_c, peers, FLAGS)
    assert_kept(gch[0], stamp)
    detail = root / "detail.h"
    detail.write_text(detail.read_text(encoding="utf-8").replace("return 4", "return 9"), encoding="utf-8")
    os.utime(detail, (stamp + 100, stamp + 100))
    tree.prepare(a_c, peers, FLAGS)
    tree.prepare(b_c, peers, FLAGS)
    assert_rebuilt(gch[0], stamp)
    tree.compile(a_c, FLAGS, extra_a)
    tree.compile(b_c, FLAGS, extra_b)
    run(["gcc", "-o", str(program), str(tree.obj / "a.o"), str(tree.obj / "b.o")])
    printed = run([str(program)]).stdout
    if printed != "9\n":
        raise AssertionError(f"更新後のヘッダーが実行へ反映されません: {printed}")
    rebuilt = stamp_newer_than_headers(gch[0])
    sidecar = gch[0].with_name(gch[0].name.removesuffix(".h.gch") + ".deps")
    sidecar.unlink()
    tree.prepare(a_c, peers, FLAGS)
    assert_rebuilt(gch[0], rebuilt)
    rebuilt = stamp_newer_than_headers(gch[0])
    sidecar.write_text("{\n", encoding="utf-8")
    tree.prepare(a_c, peers, FLAGS)
    assert_rebuilt(gch[0], rebuilt)
    rebuilt = stamp_newer_than_headers(gch[0])
    gch[0].unlink()
    tree.prepare(a_c, peers, FLAGS)
    if not gch[0].is_file() or abs(gch[0].stat().st_mtime - rebuilt) <= 1:
        raise AssertionError("削除した PCH を作り直していません")
    print("PASS: 作成、再利用、ヘッダー更新、依存の欠落")


def check_threshold(root: Path) -> None:
    tree = Tree(root)
    common_headers(tree)
    a_c = tree.write("a.c", '#include "common.h"\nint from_a(void) { return 0; }\n')
    b_c = tree.write("b.c", '#include "common.h"\nint from_b(void) { return 0; }\n')
    peers = [a_c, b_c]
    skipped = tree.prepare(a_c, peers, FLAGS, min_sources=3)
    if skipped or tree.gchs():
        raise AssertionError("下限未満で PCH を作りました")
    tree.prepare(a_c, peers, FLAGS, min_sources=2)
    gch = tree.gchs()[0]
    stamp = stamp_newer_than_headers(gch)
    tree.prepare(a_c, peers, FLAGS, min_sources=100)
    assert_kept(gch, stamp)
    print("PASS: 新規作成の下限と、既存 PCH の再利用")


def check_disabled(root: Path) -> None:
    tree = Tree(root)
    common_headers(tree)
    a_c = tree.write("a.c", '#include "common.h"\nint from_a(void) { return 0; }\n')
    b_c = tree.write("b.c", '#include "common.h"\nint from_b(void) { return 0; }\n')
    os.environ["MAKEFW_GCC_PCH"] = "0"
    try:
        skipped = tree.prepare(a_c, [a_c, b_c], FLAGS)
    finally:
        os.environ.pop("MAKEFW_GCC_PCH", None)
    if skipped or tree.gchs():
        raise AssertionError("MAKEFW_GCC_PCH=0 でも PCH を作りました")
    print("PASS: MAKEFW_GCC_PCH=0")


def check_configurations(root: Path) -> None:
    tree = Tree(root)
    common_headers(tree)
    a_c = tree.write("a.c", '#include "common.h"\nint from_a(void) { return common_value(); }\n')
    b_c = tree.write("b.c", '#include "common.h"\nint from_b(void) { return common_value(); }\n')
    a_cpp = tree.write("a.cpp", '#include "common.h"\nint from_cpp(void) { return common_value(); }\n')
    b_cpp = tree.write("b.cpp", '#include "common.h"\nint from_cpp_b(void) { return common_value(); }\n')
    tree.prepare(a_c, [a_c, b_c, a_cpp, b_cpp], FLAGS)
    tree.prepare(a_c, [a_c, b_c, a_cpp, b_cpp], ["-O2", "-g", "-DOTHER=1"])
    tree.prepare(a_cpp, [a_c, b_c, a_cpp, b_cpp], FLAGS)
    if len(tree.gchs()) != 3:
        raise AssertionError(f"構成ごとの PCH 数が不正です: {tree.gchs()}")
    print("PASS: -D と言語で PCH を分ける")


def check_directories(root: Path) -> None:
    include = root / "inc"
    include.mkdir(parents=True)
    (include / "common.h").write_text(
        "#pragma once\nstatic inline int common_value(void) { return 6; }\n", encoding="utf-8")
    flags = ["-I", str(include), *FLAGS]
    trees = []
    for name in ("left", "right"):
        tree = Tree(root / name, pch_root=root)
        source_a = tree.write("a.c", '#include <common.h>\nint from_a(void) { return common_value(); }\n')
        source_b = tree.write("b.c", '#include <common.h>\n#include <stdio.h>\n'
                              'int main(void) { printf("%d\\n", common_value()); return 0; }\n')
        trees.append((tree, source_a, source_b))
    left, left_a, left_b = trees[0]
    left.prepare(left_a, [left_a, left_b], flags)
    gch = left.gchs()
    if len(gch) != 1:
        raise AssertionError(f"山括弧 include の共有に失敗しました: {gch}")
    stamp = stamp_newer_than_headers(gch[0])
    right, right_a, right_b = trees[1]
    right.prepare(right_a, [right_a, right_b], flags)
    assert_kept(gch[0], stamp)
    if len(left.gchs()) != 1:
        raise AssertionError("ディレクトリをまたいで PCH が増えました")
    print("PASS: 山括弧 include はディレクトリをまたいで共有する")


def check_quoted(root: Path) -> None:
    programs = []
    for name, value in (("one", 1), ("two", 2)):
        tree = Tree(root / name, pch_root=root)
        tree.write("local.h", "#pragma once\nstatic inline int local_value(void) "
                   f"{{ return {value}; }}\n")
        source_a = tree.write("a.c", '#include "local.h"\nint from_a(void) { return local_value(); }\n')
        source_b = tree.write("b.c", '#include "local.h"\n#include <stdio.h>\n'
                              'int main(void) { printf("%d\\n", local_value()); return 0; }\n')
        extra = tree.prepare(source_a, [source_a, source_b], FLAGS)
        tree.compile(source_a, FLAGS, extra)
        extra_b = tree.prepare(source_b, [source_a, source_b], FLAGS)
        _obj, _dep, stderr = tree.compile(source_b, FLAGS, extra_b)
        program = root / name / "prog"
        run(["gcc", "-o", str(program), str(tree.obj / "a.o"), str(tree.obj / "b.o")])
        programs.append((program, value, stderr))
    gchs = list((root / "obj").glob("auto_*.h.gch"))
    if len(gchs) != 2:
        raise AssertionError(f"引用符 include の PCH 数が不正です: {gchs}")
    for program, value, stderr in programs:
        printed = run([str(program)]).stdout.strip()
        if printed != str(value):
            raise AssertionError(f"{program} の値が {printed} です")
        assert_used(stderr, gchs[0] if gchs[0].name in stderr else gchs[1])
    print("PASS: 引用符 include はソース ディレクトリごとに分ける")


def check_guards(root: Path) -> None:
    tree = Tree(root)
    tree.write("bare.h", "static int bare_value = 3;\n")
    a_c = tree.write("a.c", '#include "bare.h"\nint from_a(void) { return bare_value; }\n')
    b_c = tree.write("b.c", '#include "bare.h"\nint main(void) { return bare_value == 3 ? 0 : 1; }\n')
    extra = tree.prepare(a_c, [a_c, b_c], FLAGS)
    if extra or tree.gchs():
        raise AssertionError("ガードの無い接頭辞で PCH を作りました")
    run(["gcc", *FLAGS, "-c", "-o", str(tree.obj / "a.o"), str(a_c)])
    run(["gcc", *FLAGS, "-c", "-o", str(tree.obj / "b.o"), str(b_c)])
    run(["gcc", "-o", str(root / "prog"), str(tree.obj / "a.o"), str(tree.obj / "b.o")])
    run([str(root / "prog")])
    print("PASS: ガードの無い接頭辞は通常コンパイルへ戻る")


def check_guard_boundaries(root: Path) -> None:
    cases = {
        "partial": ("#ifndef FEATURE\n#define FEATURE 1\n#endif\nstruct Item {int x;};\n", False),
        "leading": ("struct Item {int x;};\n#ifndef H\n#define H\n#endif\n", False),
        "outer_else": ("#ifndef H\n#define H\n#else\nstruct Item {int x;};\n#endif\n", False),
        "conditional_once": ("#if 0\n#pragma once\n#endif\nstruct Item {int x;};\n", False),
        "nested": ("#ifndef H\n#define H\n#if 1\nstruct Item {int x;};\n#endif\n#endif\n", True),
        "defined": ("#if !defined(H)\n#define H\nstruct Item {int x;};\n#endif\n", True),
    }
    for name, (header, expected) in cases.items():
        tree = Tree(root / name)
        tree.write("common.h", header)
        body = '#include "common.h"\nint value(void) {return 0;}\n'
        a_c = tree.write("a.c", body)
        b_c = tree.write("b.c", body)
        extra = tree.prepare(a_c, [a_c, b_c], FLAGS)
        if bool(extra) != expected:
            raise AssertionError(f"ガード判定が不正です: {name}: {extra}")
        _obj, _dep, stderr = tree.compile(a_c, FLAGS, extra)
        if expected:
            assert_used(stderr, tree.gchs()[0])
    print("PASS: ファイル全体を保護するガードだけを共有する")


def check_system_header_update(root: Path) -> None:
    tree = Tree(root)
    header = tree.write("sys/value.h", "#ifndef VALUE_H\n#define VALUE_H\n"
                        "static inline int value(void) {return 1;}\n#endif\n")
    body = '#include <value.h>\nint main(void) {return value() == 2 ? 0 : 1;}\n'
    a_c = tree.write("a.c", body)
    b_c = tree.write("b.c", body)
    flags = [*FLAGS, "-isystem", str(header.parent)]
    tree.prepare(a_c, [a_c, b_c], flags)
    gch = tree.gchs()[0]
    sidecar = gch.with_name(gch.name.removesuffix(".h.gch") + ".deps")
    if str(header) not in sidecar.read_text(encoding="utf-8").splitlines():
        raise AssertionError("システムヘッダーが依存情報にありません")
    stamp = gch.stat().st_mtime_ns
    header.write_text(header.read_text(encoding="utf-8").replace("return 1", "return 2"), encoding="utf-8")
    # ファイルシステムの時刻分解能によらず、更新を明示する。
    newer = max(time.time_ns(), stamp) + 1_000_000_000
    os.utime(header, ns=(newer, newer))
    extra = tree.prepare(a_c, [a_c, b_c], flags)
    _obj, dep, stderr = tree.compile(a_c, flags, extra)
    assert_used(stderr, gch)
    invoke(["record", "--dep", str(dep), "--dep-list", str(tree.obj / "a.c.pchdeps")])
    if str(header) not in dep.read_text(encoding="utf-8"):
        raise AssertionError("オブジェクトの依存情報にシステムヘッダーがありません")
    program = root / "prog"
    run(["gcc", "-o", str(program), str(tree.obj / "a.o")])
    run([str(program)])
    print("PASS: システムヘッダー更新後は PCH の関数実装も更新する")


def check_conditional(root: Path) -> None:
    tree = Tree(root)
    common_headers(tree)
    tree.write("other.h", "int other_value;\n")
    body = '#include "common.h"\n#if 0\n#include "other.h"\n#endif\n'
    a_c = tree.write("a.c", body + "int from_a(void) { return common_value(); }\n")
    b_c = tree.write("b.c", body + "int from_b(void) { return common_value(); }\n")
    extra = tree.prepare(a_c, [a_c, b_c], FLAGS)
    synthetic = Path(extra[1]).read_text(encoding="utf-8")
    if "other.h" in synthetic or "common.h" not in synthetic:
        raise AssertionError(f"条件分岐の先を合成ヘッダーへ入れました:\n{synthetic}")
    print("PASS: 条件分岐の先は接頭辞に含めない")


def check_forced(root: Path) -> None:
    for option in ("-include", "-imacros"):
        tree = Tree(root / option.lstrip("-"))
        tree.write("force.h", "#define FORCED 1\n")
        common_headers(tree)
        a_c = tree.write("a.c", '#include "common.h"\nint from_a(void) { return FORCED; }\n')
        b_c = tree.write("b.c", '#include "common.h"\nint from_b(void) { return FORCED; }\n')
        flags = [option, str(tree.root / "force.h"), *FLAGS]
        extra = tree.prepare(a_c, [a_c, b_c], flags)
        if extra or tree.gchs():
            raise AssertionError(f"{option} があるのに PCH を作りました")
        run(["gcc", *flags, "-c", "-o", str(tree.obj / "a.o"), str(a_c)])
    print("PASS: -include と -imacros では自動 PCH を使わない")


def check_test_split(root: Path) -> None:
    tree = Tree(root)
    tree.write("common.h", "#pragma once\nstatic inline int common_value(void) { return 1; }\n")
    tree.write("extra.h", "#pragma once\nstatic inline int extra_value(void) { return 2; }\n")
    normal_body = '#include "common.h"\n#include "extra.h"\n'
    a_c = tree.write("a.c", normal_body + "int from_a(void) { return extra_value(); }\n")
    b_c = tree.write("b.c", normal_body + "int from_b(void) { return extra_value(); }\n")
    t_c = tree.write("t.c", '#include "common.h"\nint from_t(void) { return common_value(); }\n')
    u_c = tree.write("u.c", '#include "common.h"\nint from_u(void) { return common_value(); }\n')
    peers = [a_c, b_c, t_c, u_c]
    normal = tree.prepare(a_c, peers, FLAGS, test_names=("t.c", "u.c"))
    tested = tree.prepare(t_c, peers, FLAGS, for_test=1, test_names=("t.c", "u.c"))
    if "extra.h" not in Path(normal[1]).read_text(encoding="utf-8"):
        raise AssertionError("通常ソースの接頭辞がテストソースに縮められました")
    if "extra.h" in Path(tested[1]).read_text(encoding="utf-8"):
        raise AssertionError("テストソースの接頭辞に通常ソース専用のヘッダーがあります")
    print("PASS: 通常ソースとテストソースで接頭辞を分ける")


def check_warning(root: Path) -> None:
    tree = Tree(root)
    tree.write("common.h", "#pragma once\n#warning pch-marker\nstatic inline int common_value(void) { return 1; }\n")
    a_c = tree.write("a.c", '#include "common.h"\nint from_a(void) { return common_value(); }\n')
    b_c = tree.write("b.c", '#include "common.h"\nint from_b(void) { return common_value(); }\n')
    tree.prepare(a_c, [a_c, b_c], FLAGS)
    warns = list(tree.shared.glob("auto_*.warn"))
    if len(warns) != 1 or "pch-marker" not in warns[0].read_text(encoding="utf-8"):
        raise AssertionError(f"作成時の警告を残せませんでした: {warns}")
    print("PASS: 作成時の警告を .warn に残す")


def check_wrapper(root: Path) -> None:
    tree = Tree(root)
    common_headers(tree)
    wrapper = root / "cc"
    wrapper.write_text("#!/bin/sh\nexec gcc \"$@\"\n", encoding="utf-8")
    wrapper.chmod(0o755)
    a_c = tree.write("a.c", '#include "common.h"\nint from_a(void) { return common_value(); }\n')
    b_c = tree.write("b.c", '#include "common.h"\nint from_b(void) { return common_value(); }\n')
    tree.prepare(a_c, [a_c, b_c], FLAGS, compiler=str(wrapper))
    future = time.time() + 10
    os.utime(wrapper, (future, future))
    tree.prepare(a_c, [a_c, b_c], FLAGS, compiler=str(wrapper))
    if len(tree.gchs()) != 2:
        raise AssertionError(f"コンパイラの更新時刻で PCH を分けられません: {tree.gchs()}")
    print("PASS: コンパイラの更新時刻を識別子に含める")


def check_concurrent(root: Path) -> None:
    tree = Tree(root)
    common_headers(tree)
    a_c = tree.write("a.c", '#include "common.h"\nint from_a(void) { return common_value(); }\n')
    b_c = tree.write("b.c", '#include "common.h"\nint from_b(void) { return common_value(); }\n')
    commands = []
    for source in (a_c, b_c):
        arg = tree.obj / f"{source.name}.pchargs"
        deps = tree.obj / f"{source.name}.pchdeps"
        commands.append([
            sys.executable, str(GCC_PCH), "prepare", "--compiler", "gcc",
            "--objdir", str(tree.obj), "--pch-root", str(tree.pch_root),
            "--source", str(source), "--arg-file", str(arg), "--dep-list", str(deps),
            "--min-sources", "2", "--peer", str(a_c), "--peer", str(b_c), "--", *FLAGS,
        ])
    processes = [subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE) for command in commands]
    for process in processes:
        stdout, stderr = process.communicate(timeout=60)
        if process.returncode != 0:
            raise AssertionError(stderr.decode("utf-8", errors="replace"))
        if stdout:
            raise AssertionError(stdout.decode("utf-8", errors="replace"))
    if len(tree.gchs()) != 1:
        raise AssertionError(f"並行作成で PCH が複数できました: {tree.gchs()}")
    print("PASS: 並行作成でも PCH は 1 つ")


def check_special_flags(root: Path, flags: list[str], link_flags: list[str], label: str) -> None:
    tree = Tree(root)
    common_headers(tree)
    a_c = tree.write("a.c", '#include "common.h"\nint from_a(void) { return common_value(); }\n')
    b_c = tree.write("b.c", '#include "common.h"\nint from_a(void);\n'
                     "int main(void) { return from_a() == 4 ? 0 : 1; }\n")
    peers = [a_c, b_c]
    extra_a = tree.prepare(a_c, peers, flags)
    extra_b = tree.prepare(b_c, peers, flags)
    tree.compile(a_c, flags, extra_a)
    _obj, _dep, stderr = tree.compile(b_c, flags, extra_b)
    assert_used(stderr, tree.gchs()[0])
    program = root / "prog"
    run(["gcc", *link_flags, "-o", str(program), str(tree.obj / "a.o"), str(tree.obj / "b.o")])
    run([str(program)])
    if label == "coverage" and not list(tree.obj.glob("*.gcno")):
        raise AssertionError(".gcno がありません")
    if label == "coverage":
        run(["gcov", "-o", str(tree.obj), "a.c"], cwd=root)
    print(f"PASS: {label}")


def check_coverity(root: Path) -> None:
    home = root / "cov"
    binary = home / "bin" / "cov-build"
    binary.parent.mkdir(parents=True)
    binary.write_text("#!/bin/sh\necho MSVC=$MAKEFW_MSVC_PCH\necho GCC=$MAKEFW_GCC_PCH\n", encoding="utf-8")
    binary.chmod(0o755)
    env = os.environ.copy()
    env["COVERITY_HOME"] = str(home)
    env["WORKSPACE_DIR"] = str(root / "ws")
    env["MAKEFW_MSVC_PCH"] = "1"
    env["MAKEFW_GCC_PCH"] = "1"
    result = run(["bash", str(COV_WRAPPER), "c_cpp", "true"], env=env)
    if "MSVC=0" not in result.stdout or "GCC=0" not in result.stdout:
        raise AssertionError(f"Coverity 中の PCH 無効化が不足しています:\n{result.stdout}")
    print("PASS: with-cov は Windows と Linux の PCH を無効にする")


def check_probe_location_and_cleanup(root: Path) -> None:
    # 1. GCC 呼び出し中にプローブが objdir 配下の空一時ディレクトリへ置かれ、ソース側へ作られないこと。
    tree = Tree(root / "normal")
    common_headers(tree)
    a_c = tree.write("a.c", '#include "common.h"\nint from_a(void) { return common_value(); }\n')
    b_c = tree.write("b.c", '#include "common.h"\nint from_b(void) { return common_value(); }\n')
    observed = root / "observed.txt"
    wrapper = root / "probe-observer"
    wrapper.write_text(
        "#!/usr/bin/env python3\n"
        "import os, sys\n"
        "from pathlib import Path\n"
        "args = sys.argv[1:]\n"
        "if '-H' in args and '-E' in args and '-fsyntax-only' in args:\n"
        "    probe = Path(args[-1])\n"
        "    entries = sorted(p.name for p in probe.parent.iterdir())\n"
        "    src_probes = sorted(p.name for p in Path(os.environ['OBS_SRC']).glob('.makefw-pch-resolve-*'))\n"
        "    with open(os.environ['OBS_FILE'], 'a', encoding='utf-8') as f:\n"
        "        f.write(f'{probe}\\t{entries}\\t{src_probes}\\n')\n"
        "os.execvp('gcc', ['gcc', *args])\n",
        encoding="utf-8",
    )
    wrapper.chmod(0o755)
    os.environ["OBS_FILE"] = str(observed)
    os.environ["OBS_SRC"] = str(tree.root)
    try:
        extra = tree.prepare(a_c, [a_c, b_c], FLAGS, compiler=str(wrapper))
    finally:
        os.environ.pop("OBS_FILE", None)
        os.environ.pop("OBS_SRC", None)
    if not extra or not observed.is_file():
        raise AssertionError("プローブ観測ラッパー経由の prepare が失敗しました")
    lines = observed.read_text(encoding="utf-8").splitlines()
    if len(lines) != 1:
        raise AssertionError(f"プローブ観測回数が不正です: {lines}")
    probe_str, entries_str, src_probes_str = lines[0].split("\t")
    probe_path = Path(probe_str)
    if probe_path.parent.parent != tree.obj or not probe_path.parent.name.startswith(".makefw-pch-resolve-"):
        raise AssertionError(f"プローブが objdir 配下の固有ディレクトリにありません: {probe_path}")
    if probe_path.name != "probe.c" or entries_str != "['probe.c']":
        raise AssertionError(f"プローブ名または一時ディレクトリ内容が不正です: {probe_path} {entries_str}")
    if src_probes_str != "[]":
        raise AssertionError(f"GCC 実行中にソース側へプローブが作られました: {src_probes_str}")
    if list(tree.obj.glob(".makefw-pch-resolve-*")) or list(tree.root.glob(".makefw-pch-resolve-*")):
        raise AssertionError("正常終了後にプローブ一時ディレクトリが残りました")

    # 2. GCC 非ゼロ終了時に通常コンパイルへ戻り、一時ディレクトリが削除されること。
    fail_tree = Tree(root / "gcc-fail")
    fa = fail_tree.write("a.c", '#include "missing_header.h"\nint a(void) { return 0; }\n')
    fb = fail_tree.write("b.c", '#include "missing_header.h"\nint b(void) { return 0; }\n')
    fail_extra = fail_tree.prepare(fa, [fa, fb], FLAGS)
    if fail_extra or fail_tree.gchs():
        raise AssertionError("GCC 失敗時に通常コンパイルへ戻りませんでした")
    if list(fail_tree.obj.glob(".makefw-pch-resolve-*")) or list(fail_tree.root.glob(".makefw-pch-resolve-*")):
        raise AssertionError("GCC 非ゼロ終了後にプローブ一時ディレクトリが残りました")

    # 3. プローブ書き込み例外時も一時ディレクトリが削除されること。
    err_tree = Tree(root / "write-fail")
    ea = err_tree.write("a.c", '#include "common.h"\nint a(void) { return 0; }\n')
    eb = err_tree.write("b.c", '#include "common.h"\nint b(void) { return 0; }\n')
    original_write_text = Path.write_text

    def fail_probe_write(self: Path, data: str, *args, **kwargs) -> int:
        if self.name == "probe.c" and self.parent.name.startswith(".makefw-pch-resolve-"):
            raise OSError("simulated write failure")
        return original_write_text(self, data, *args, **kwargs)

    with mock.patch.object(Path, "write_text", fail_probe_write):
        raised = False
        try:
            gcc_pch._resolve_includes("gcc", FLAGS, "c", ['"common.h"'], err_tree.root, err_tree.obj)
        except OSError:
            raised = True
        if not raised:
            raise AssertionError("プローブ書き込み例外が送出されませんでした")
    if list(err_tree.obj.glob(".makefw-pch-resolve-*")) or list(err_tree.root.glob(".makefw-pch-resolve-*")):
        raise AssertionError("書き込み例外後にプローブ一時ディレクトリが残りました")
    with mock.patch.object(Path, "write_text", fail_probe_write):
        code = gcc_pch.main([
            "prepare", "--compiler", "gcc", "--objdir", str(err_tree.obj),
            "--pch-root", str(err_tree.pch_root), "--source", str(ea),
            "--arg-file", str(err_tree.obj / "a.pchargs"),
            "--dep-list", str(err_tree.obj / "a.pchdeps"),
            "--peer", str(ea), "--peer", str(eb), "--", *FLAGS,
        ])
    if code != 1:
        raise AssertionError(f"書き込み例外時の終了コードが不正です: {code}")
    if list(err_tree.obj.glob(".makefw-pch-resolve-*")) or list(err_tree.root.glob(".makefw-pch-resolve-*")):
        raise AssertionError("main 経由の書き込み例外後に一時ディレクトリが残りました")
    print("PASS: プローブの配置先と正常・失敗・例外時の後始末")


def check_objdir_same_name_and_nesting(root: Path) -> None:
    for lang, ext, compiler in (("c", ".c", "gcc"), ("cpp", ".cpp", "g++")):
        # 1. objdir 側に同名ヘッダーがあってもソース側を優先すること。
        tree = Tree(root / f"{lang}-same")
        tree.write("local.h", "#pragma once\nstatic inline int local_val(void) { return 11; }\n")
        (tree.obj / "local.h").write_text(
            "#pragma once\nstatic inline int local_val(void) { return 99; }\n", encoding="utf-8"
        )
        a_src = tree.write(f"a{ext}", '#include "local.h"\nint from_a(void) { return local_val(); }\n')
        b_src = tree.write(
            f"b{ext}",
            '#include "local.h"\n#include <stdio.h>\nint from_a(void);\n'
            'int main(void) { printf("%d\\n", from_a() + local_val()); return 0; }\n',
        )
        extra_a = tree.prepare(a_src, [a_src, b_src], FLAGS, compiler=compiler)
        extra_b = tree.prepare(b_src, [a_src, b_src], FLAGS, compiler=compiler)
        gchs = tree.gchs()
        if len(gchs) != 1:
            raise AssertionError(f"{lang}: objdir 同名ヘッダー検証で PCH 数が不正です: {gchs}")
        obj_a, _dep_a, stderr_a = tree.compile(a_src, FLAGS, extra_a, compiler=compiler)
        obj_b, _dep_b, stderr_b = tree.compile(b_src, FLAGS, extra_b, compiler=compiler)
        assert_used(stderr_a, gchs[0])
        assert_used(stderr_b, gchs[0])
        prog = tree.root / "prog"
        run([compiler, "-o", str(prog), str(obj_a), str(obj_b)])
        out = run([str(prog)]).stdout.strip()
        if out != "22":
            raise AssertionError(f"{lang}: objdir 側の同名ヘッダーが選択されました: {out}")

        # 2. 入れ子の引用符 include でソース側が探索パスより優先されないこと。
        nest = Tree(root / f"{lang}-nest")
        inc_a = nest.root / "inc_a"
        inc_b = nest.root / "inc_b"
        inc_a.mkdir()
        inc_b.mkdir()
        (inc_a / "outer.h").write_text(
            '#pragma once\n#include "nested.h"\nstatic inline int outer_val(void) { return nested_val(); }\n',
            encoding="utf-8",
        )
        (inc_b / "nested.h").write_text(
            "#pragma once\nstatic inline int nested_val(void) { return 42; }\n", encoding="utf-8"
        )
        # ソース側と objdir 側に囮の nested.h を置く。
        nest.write("nested.h", "#pragma once\nstatic inline int nested_val(void) { return 999; }\n")
        (nest.obj / "outer.h").write_text(
            "#pragma once\nstatic inline int outer_val(void) { return 888; }\n", encoding="utf-8"
        )
        (nest.obj / "nested.h").write_text(
            "#pragma once\nstatic inline int nested_val(void) { return 777; }\n", encoding="utf-8"
        )
        flags = ["-I", str(inc_a), "-I", str(inc_b), *FLAGS]
        na = nest.write(f"a{ext}", '#include "outer.h"\nint from_a(void) { return outer_val(); }\n')
        nb = nest.write(
            f"b{ext}",
            '#include "outer.h"\n#include <stdio.h>\nint from_a(void);\n'
            'int main(void) { printf("%d\\n", from_a() == outer_val() ? outer_val() : -1); return 0; }\n',
        )
        extra_na = nest.prepare(na, [na, nb], flags, compiler=compiler)
        extra_nb = nest.prepare(nb, [na, nb], flags, compiler=compiler)
        nest_gchs = nest.gchs()
        if len(nest_gchs) != 1:
            raise AssertionError(f"{lang}: 入れ子 include 検証で PCH 数が不正です: {nest_gchs}")
        nobj_a, _ndep_a, nerr_a = nest.compile(na, flags, extra_na, compiler=compiler)
        nobj_b, _ndep_b, nerr_b = nest.compile(nb, flags, extra_nb, compiler=compiler)
        assert_used(nerr_a, nest_gchs[0])
        assert_used(nerr_b, nest_gchs[0])
        nprog = nest.root / "prog"
        run([compiler, "-o", str(nprog), str(nobj_a), str(nobj_b)])
        nout = run([str(nprog)]).stdout.strip()
        if nout != "42":
            raise AssertionError(f"{lang}: 入れ子の引用符 include の優先順が変わりました: {nout}")
    print("PASS: C/C++ で objdir 同名ヘッダーと入れ子引用符 include の解決を維持")


def check_fallback_paths_and_cwd(root: Path) -> None:
    src = root / "src"
    obj = root / "obj"
    runner = root / "runner"
    qdir = runner / "qinc"
    idir = runner / "iinc"
    for directory in (src, obj, qdir, idir):
        directory.mkdir(parents=True)

    (src / "local.h").write_text("#pragma once\n#define V_LOCAL 1\n", encoding="utf-8")
    (runner / "local.h").write_text("#pragma once\n#define V_LOCAL 100\n", encoding="utf-8")
    (obj / "local.h").write_text("#pragma once\n#define V_LOCAL 200\n", encoding="utf-8")

    (qdir / "from_quote.h").write_text("#pragma once\n#define V_QUOTE 2\n", encoding="utf-8")
    (idir / "from_quote.h").write_text("#pragma once\n#define V_QUOTE 210\n", encoding="utf-8")
    (obj / "from_quote.h").write_text("#pragma once\n#define V_QUOTE 220\n", encoding="utf-8")

    (idir / "from_I.h").write_text("#pragma once\n#define V_I 3\n", encoding="utf-8")
    (obj / "from_I.h").write_text("#pragma once\n#define V_I 310\n", encoding="utf-8")

    (idir / "angle.h").write_text("#pragma once\n#define V_ANGLE 4\n", encoding="utf-8")
    (src / "angle.h").write_text("#pragma once\n#define V_ANGLE 410\n", encoding="utf-8")
    (obj / "angle.h").write_text("#pragma once\n#define V_ANGLE 420\n", encoding="utf-8")

    a_c = src / "a.c"
    b_c = src / "b.c"
    body = (
        '#include "local.h"\n'
        '#include "from_quote.h"\n'
        '#include "from_I.h"\n'
        '#include <angle.h>\n'
    )
    a_c.write_text(body + "int sum_a(void) { return V_LOCAL + V_QUOTE + V_I + V_ANGLE; }\n", encoding="utf-8")
    b_c.write_text(
        body + '#include <stdio.h>\nint sum_a(void);\n'
        'int main(void) { printf("%d\\n", sum_a()); return 0; }\n',
        encoding="utf-8",
    )

    # 1. 相対探索パスと異なる cwd で _resolve_includes の解決先が通常コンパイルと一致すること。
    rel_flags = ["-iquote", "qinc", "-I", "iinc", *FLAGS]
    previous_cwd = Path.cwd()
    os.chdir(runner)
    try:
        resolved = gcc_pch._resolve_includes(
            "gcc", rel_flags, "c",
            ['"local.h"', '"from_quote.h"', '"from_I.h"', "<angle.h>"],
            src, obj,
        )
    finally:
        os.chdir(previous_cwd)
    if resolved is None:
        raise AssertionError("異なる cwd での _resolve_includes が失敗しました")
    direct_gcc = run(
        ["gcc", *rel_flags, "-H", "-E", "-fsyntax-only", str(a_c)],
        cwd=runner,
    )

    def resolve_from_runner(path_text: str) -> Path:
        path = Path(path_text)
        return (path if path.is_absolute() else runner / path).resolve()

    resolved_paths = [resolve_from_runner(str(path)) for path in resolved]
    expected = [
        resolve_from_runner(path)
        for depth, path in gcc_pch._parse_include_trace(direct_gcc.stderr)
        if depth == 1 and not path.endswith("/stdc-predef.h")
    ]
    expected_concrete = [
        (src / "local.h").resolve(),
        (qdir / "from_quote.h").resolve(),
        (idir / "from_I.h").resolve(),
        (idir / "angle.h").resolve(),
    ]
    if resolved_paths != expected or resolved_paths != expected_concrete:
        raise AssertionError(
            "cwd 違いの探索結果が一致しません: "
            f"{resolved_paths} vs gcc={expected} vs concrete={expected_concrete}"
        )

    # 2. 絶対パス探索フラグで異なる cwd から prepare / compile しても現行と同じ解決で動くこと。
    abs_flags = ["-iquote", str(qdir), "-I", str(idir), *FLAGS]
    os.chdir(runner)
    try:
        arg_a = obj / "a.pchargs"
        dep_a = obj / "a.pchdeps"
        arg_b = obj / "b.pchargs"
        dep_b = obj / "b.pchdeps"
        for src_file, arg_file, dep_file in ((a_c, arg_a, dep_a), (b_c, arg_b, dep_b)):
            invoke([
                "prepare", "--compiler", "gcc", "--objdir", str(obj),
                "--pch-root", str(root), "--source", str(src_file),
                "--arg-file", str(arg_file), "--dep-list", str(dep_file),
                "--min-sources", "2", "--peer", str(a_c), "--peer", str(b_c),
                "--", *abs_flags,
            ])
        extra_a = arg_a.read_text(encoding="utf-8").splitlines()
        extra_b = arg_b.read_text(encoding="utf-8").splitlines()
        gchs = list(obj.glob("auto_*.h.gch"))
        if len(gchs) != 1:
            raise AssertionError(f"cwd 違いで PCH が作られませんでした: {gchs}")
        obj_a = obj / "a.o"
        obj_b = obj / "b.o"
        res_a = run(["gcc", *abs_flags, *extra_a, "-H", "-c", "-o", str(obj_a), str(a_c)], cwd=runner)
        res_b = run(["gcc", *abs_flags, *extra_b, "-H", "-c", "-o", str(obj_b), str(b_c)], cwd=runner)
        assert_used(res_a.stderr, gchs[0])
        assert_used(res_b.stderr, gchs[0])
        prog = root / "prog"
        run(["gcc", "-o", str(prog), str(obj_a), str(obj_b)], cwd=runner)
        out = run([str(prog)], cwd=runner).stdout.strip()
        if out != "10":
            raise AssertionError(f"フォールバック探索先の結果が不正です: {out}")
    finally:
        os.chdir(previous_cwd)
    print("PASS: 既存 -iquote / -I、山括弧、および異なる cwd でのフォールバック探索")


def check_symlink_parent(root: Path) -> None:
    tree = Tree(root / "proj")
    other = root / "other"
    other.mkdir()
    (other / "real.h").write_text(
        '#pragma once\n#include "sibling.h"\nstatic inline int sym_value(void) { return sibling_value(); }\n',
        encoding="utf-8",
    )
    (other / "sibling.h").write_text(
        "#pragma once\nstatic inline int sibling_value(void) { return 999; }\n", encoding="utf-8"
    )
    tree.write("sibling.h", "#pragma once\nstatic inline int sibling_value(void) { return 77; }\n")
    link = tree.root / "link.h"
    link.symlink_to(other / "real.h")
    a_c = tree.write("a.c", '#include "link.h"\nint from_a(void) { return sym_value(); }\n')
    b_c = tree.write(
        "b.c",
        '#include "link.h"\n#include <stdio.h>\nint from_a(void);\n'
        'int main(void) { printf("%d\\n", from_a() == sym_value() ? sym_value() : -1); return 0; }\n',
    )
    extra_a = tree.prepare(a_c, [a_c, b_c], FLAGS)
    extra_b = tree.prepare(b_c, [a_c, b_c], FLAGS)
    gchs = tree.gchs()
    if len(gchs) != 1:
        raise AssertionError(f"symlink 検証で PCH が作られませんでした: {gchs}")
    synthetic_text = Path(extra_a[1]).read_text(encoding="utf-8")
    if str(link) not in synthetic_text or str(other / "real.h") in synthetic_text:
        raise AssertionError(f"symlink が実体側へ resolve されました:\n{synthetic_text}")
    obj_a, _dep_a, err_a = tree.compile(a_c, FLAGS, extra_a)
    obj_b, _dep_b, err_b = tree.compile(b_c, FLAGS, extra_b)
    assert_used(err_a, gchs[0])
    assert_used(err_b, gchs[0])
    prog = root / "prog"
    run(["gcc", "-o", str(prog), str(obj_a), str(obj_b)])
    out = run([str(prog)]).stdout.strip()
    if out != "77":
        raise AssertionError(f"symlink の親ディレクトリが維持されませんでした: {out}")
    print("PASS: symlink の親ディレクトリを維持して解決する")


def check_incompatible_flags(root: Path) -> None:
    if gcc_pch._normalize_flags(["-I-", "-O2"], root) != ["-I-", "-O2"]:
        raise AssertionError("フラグ正規化が -I- を誤解釈しました")
    flag_cases = (
        ("i-dash", ["-I-"]),
        ("i-space-dash", ["-I", "-"]),
        ("include-barrier", ["--include-barrier"]),
        ("wp-i-dash", ["-Wp,-I-"]),
    )
    for name, barrier in flag_cases:
        tree = Tree(root / name)
        qdir = tree.root / "qdir"
        qdir.mkdir()
        (qdir / "common.h").write_text(
            "#pragma once\nstatic inline int barrier_val(void) { return 5; }\n", encoding="utf-8"
        )
        # -I- はソース側ディレクトリ探索を抑止し、直前の -I を引用符専用にする。
        tree.write("common.h", "#pragma once\nstatic inline int barrier_val(void) { return 999; }\n")
        a_c = tree.write("a.c", '#include "common.h"\nint from_a(void) { return barrier_val(); }\n')
        b_c = tree.write(
            "b.c",
            '#include "common.h"\nint from_a(void);\n'
            "int main(void) { return from_a() == 5 ? 0 : 1; }\n",
        )
        flags = ["-I", str(qdir), *barrier, *FLAGS]
        extra = tree.prepare(a_c, [a_c, b_c], flags)
        if extra or tree.gchs():
            raise AssertionError(f"{name} で自動 PCH を無効化できませんでした: {extra}")
        run(["gcc", *flags, "-c", "-o", str(tree.obj / "a.o"), str(a_c)])
        run(["gcc", *flags, "-c", "-o", str(tree.obj / "b.o"), str(b_c)])
        prog = tree.root / "prog"
        run(["gcc", "-o", str(prog), str(tree.obj / "a.o"), str(tree.obj / "b.o")])
        run([str(prog)])
    print("PASS: -I- 等の探索前提が成立しない指定で通常コンパイルへ戻る")


def check_probe_ignored_and_excluded(root: Path) -> None:
    # 1. resolve_app_deps.sh の署名走査で obj/ 配下のプローブが除外されること。
    ws = root / "ws"
    for directory in ("makefiles", "bin_internal"):
        shutil.copytree(MAKEFW / directory, ws / "framework/makefw" / directory)
    (ws / ".workspaceRoot").write_text("", encoding="utf-8")
    (ws / "app/sample/makefile").parent.mkdir(parents=True, exist_ok=True)
    (ws / "app/sample/makefile").write_text("", encoding="utf-8")
    src_dir = ws / "app/sample/prod/libsrc"
    src_dir.mkdir(parents=True, exist_ok=True)
    (src_dir / "sample.c").write_text("int sample_fn(void) { return 1; }\n", encoding="utf-8")

    env = {
        key: value for key, value in os.environ.items()
        if not key.startswith("MAKEFW_")
        and key not in ("WORKSPACE_DIR", "CONFIG", "CFLAGS", "CXXFLAGS", "LDFLAGS", "DEFINES", "LIBS")
    }
    env["MAKEFW_ASSURED_ACTIVE"] = "0"
    resolver = ws / "framework/makefw/bin_internal/resolve_app_deps.sh"

    def read_signature() -> tuple[str, list[str]]:
        res = run(["bash", str(resolver), "--signature", (ws / "app/sample").as_posix(), "build"], env=env)
        lines = res.stdout.splitlines()
        sig = next(line for line in lines if line.startswith("BUILD_SIGNATURE="))
        entries = [line.split("\t")[0] for line in lines if "\t" in line]
        return sig, entries

    base_sig, base_entries = read_signature()
    for rel in (
        "obj/.makefw-pch-resolve-test/probe.c",
        "obj/debug/.makefw-pch-resolve-test/probe.c",
    ):
        probe_file = src_dir / rel
        probe_file.parent.mkdir(parents=True, exist_ok=True)
        probe_file.write_text('#include "common.h"\n', encoding="utf-8")
    obj_sig, obj_entries = read_signature()
    if obj_sig != base_sig or obj_entries != base_entries:
        raise AssertionError(f"obj 配下のプローブがビルド署名へ混入しました: {obj_entries}")

    # 比較のため、ソース直下に .c を置いた場合は署名対象に入ることを確認する。
    (src_dir / ".makefw-pch-resolve-leak.c").write_text('#include "common.h"\n', encoding="utf-8")
    leak_sig, leak_entries = read_signature()
    if leak_sig == base_sig or not any(entry.endswith(".makefw-pch-resolve-leak.c") for entry in leak_entries):
        raise AssertionError("ソース直下の .c が署名比較の対照として検出されませんでした")
    print("PASS: 標準 obj/ 配下のプローブはビルド署名から除外される")

    # 2. Git 書き込み操作を行わずに標準 obj/ 配下のプローブが .gitignore に一致することを確認する。
    ws_root = MAKEFW.parents[1]
    gitignore = ws_root / ".gitignore"
    if not gitignore.is_file():
        print(f"SKIP: 標準 obj/ 配下のプローブの Git 無視確認 (.gitignore がありません: {gitignore})")
        return
    if not shutil.which("git"):
        print("SKIP: 標準 obj/ 配下のプローブの Git 無視確認 (git コマンドが見つかりません)")
        return
    for ignored_rel in (
        "obj/.makefw-pch-resolve-test/probe.c",
        "obj/debug/.makefw-pch-resolve-test/probe.c",
    ):
        chk = subprocess.run(
            ["git", "-C", str(ws_root), "check-ignore", "-q", ignored_rel],
            capture_output=True, text=True, encoding="utf-8", check=False,
        )
        if chk.returncode != 0:
            raise AssertionError(
                f"標準 obj/ のプローブが Git 無視規則に一致しません (rc={chk.returncode}): "
                f"{ignored_rel} {chk.stderr.strip()}"
            )
    unignored = subprocess.run(
        ["git", "-C", str(ws_root), "check-ignore", "-q", ".makefw-pch-resolve-test.c"],
        capture_output=True, text=True, encoding="utf-8", check=False,
    )
    if unignored.returncode != 1:
        raise AssertionError(
            f"ソース直下のプローブが未無視 (exit=1) ではありません (rc={unignored.returncode}): "
            f"{unignored.stderr.strip()}"
        )
    print("PASS: 標準 obj/ 配下のプローブは Git 無視規則に一致する")


def main() -> None:
    os.environ.pop("MAKEFW_GCC_PCH", None)
    os.environ.pop("MAKEFW_GCC_PCH_DEBUG", None)
    os.environ.pop("MAKEFW_GCC_PCH_MIN_SOURCES", None)
    with tempfile.TemporaryDirectory(prefix="makefw-gcc-pch-") as temporary:
        root = Path(temporary)
        check_normalize(root / "norm")
        check_prefix(root / "prefix")
        check_language_key()
        check_basic(root / "basic")
        check_threshold(root / "threshold")
        check_disabled(root / "disabled")
        check_configurations(root / "config")
        check_directories(root / "dirs")
        check_quoted(root / "quoted")
        check_guards(root / "guards")
        check_guard_boundaries(root / "guard-boundaries")
        check_system_header_update(root / "system-update")
        check_conditional(root / "cond")
        check_forced(root / "forced")
        check_test_split(root / "split")
        check_warning(root / "warn")
        check_wrapper(root / "wrapper")
        check_concurrent(root / "concurrent")
        check_special_flags(root / "coverage", ["--coverage", "-O0", "-g"], ["--coverage"], "coverage")
        check_special_flags(root / "flto", ["-flto", "-O2", "-g"], ["-flto"], "flto")
        check_coverity(root / "coverity")
        check_probe_location_and_cleanup(root / "probe-loc")
        check_objdir_same_name_and_nesting(root / "same-and-nest")
        check_fallback_paths_and_cwd(root / "fallback-cwd")
        check_symlink_parent(root / "symlink-parent")
        check_incompatible_flags(root / "incompatible-flags")
        check_probe_ignored_and_excluded(root / "ignore-and-sig")
    print("GCC の自動 PCH 検証に成功しました。")


if __name__ == "__main__":
    main()
