#!/usr/bin/env python3
"""GCC の自動 PCH と、Coverity 収集時の無効化を確認する。

Linux で実行する。一時ディレクトリのソースだけを使い、ワークスペースの成果物は変えない。
"""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from contextlib import redirect_stdout
from io import StringIO

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

    def compile(self, source: Path, flags: list[str], extra: list[str]) -> tuple[Path, Path, str]:
        out = self.obj / f"{source.stem}.o"
        dep = self.obj / f"{source.stem}.d"
        argv = [
            "gcc", "-MT", str(out), "-MMD", "-MP", "-MF", str(dep),
            *flags, *extra, "-H", "-c", "-o", str(out), str(source),
            "-fdiagnostics-color=always",
        ]
        result = run(argv)
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
        check_conditional(root / "cond")
        check_forced(root / "forced")
        check_test_split(root / "split")
        check_warning(root / "warn")
        check_wrapper(root / "wrapper")
        check_concurrent(root / "concurrent")
        check_special_flags(root / "coverage", ["--coverage", "-O0", "-g"], ["--coverage"], "coverage")
        check_special_flags(root / "flto", ["-flto", "-O2", "-g"], ["-flto"], "flto")
        check_coverity(root / "coverity")
    print("GCC の自動 PCH 検証に成功しました。")


if __name__ == "__main__":
    main()
