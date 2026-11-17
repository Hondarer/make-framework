#!/usr/bin/env python3
"""サブディレクトリを持つライブラリのビルドを、実際の C/C++ テンプレートで確認する。

確認する内容は次のとおり。

- 自動 PCH を使うオブジェクトが、変更なしの make の再実行で再コンパイルされないこと。
- 共通ヘッダーの更新と .d の削除では、必要なソースだけが再コンパイルされること。
- 1 回の make で、各サブディレクトリの make の起動が 1 回であること。
- オブジェクトが存在しない時間を広げても、親の make がサブディレクトリの make の完了を
  待ってからオブジェクトを確認し、失敗しないこと。
- サブディレクトリのソースの更新、削除、復元の後に、成果物が再リンクされること。
"""

import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

# 自動 PCH とサブディレクトリのオブジェクトの収集は Linux だけの処理なので、Linux だけで実行する
# (run-bin-tests.py が参照する)。
BIN_TEST_PLATFORM = "linux"

MAKEFW = Path(__file__).resolve().parents[1]
PCH_SOURCES = 6
COMPILE = re.compile(r" -c -o (\S+) ")


def run(argv, **kwargs):
    result = subprocess.run(argv, capture_output=True, text=True, encoding="utf-8", **kwargs)
    if result.returncode:
        raise AssertionError(f"コマンド失敗: {argv}\n{result.stdout}\n{result.stderr}")
    return result.stdout


class Fixture:
    """test/libsrc/probe に、NO_LINK のサブディレクトリ sub_a と sub_b を持つ静的ライブラリを作る。"""

    def __init__(self, root, name, pch=True):
        self.root = root / name
        self.root.mkdir()
        (self.root / ".workspaceRoot").touch()
        (self.root / "framework").mkdir()
        (self.root / "framework" / "makefw").symlink_to(MAKEFW, target_is_directory=True)
        self.directory = self.root / "test" / "libsrc" / "probe"
        self.sub_a = self.directory / "sub_a"
        self.sub_b = self.directory / "sub_b"
        for directory in (self.directory, self.sub_a, self.sub_b):
            directory.mkdir(parents=True)
            (directory / "makefile").write_text("include $(MAKEFW_HOME)/makefiles/__template.mk\n", encoding="utf-8")
        (self.directory / "makepart.mk").write_text("LIB_TYPE := static\n", encoding="utf-8")
        (self.directory / "makechild.mk").write_text("NO_LINK := 1\n", encoding="utf-8")
        (self.directory / "root.c").write_text("int root_symbol(void) { return 1; }\n", encoding="utf-8")
        self.header = self.sub_a / "common.h"
        self.header.write_text("#ifndef COMMON_H\n#define COMMON_H\n#include <stdio.h>\n#include <string.h>\n"
                               "static inline int common_value(void) { return 3; }\n#endif\n", encoding="utf-8")
        for index in range(PCH_SOURCES):
            (self.sub_a / f"gen_a_{index:02d}.c").write_text(
                f'#include "common.h"\nint gen_a_{index:02d}(void) {{ return common_value() + {index}; }}\n',
                encoding="utf-8")
        self.b_source = self.sub_b / "b.c"
        self.b_text = "int b_symbol(void) { return 2; }\n"
        self.b_source.write_text(self.b_text, encoding="utf-8")
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("MAKEFW_") and key not in
                    ("MAKEFLAGS", "MFLAGS", "MAKELEVEL", "IDENT_ENABLED", "PLATFORM_LINUX", "PLATFORM_WINDOWS")}
        # make の Entering directory の行を数えるため、メッセージを英語に固定する。
        self.env.update(LC_ALL="C.UTF-8", LANGUAGE="C",
                        MAKEFW_HOME=str(self.root / "framework" / "makefw"), MAKEFW_FILES_LANG="C.UTF-8",
                        MAKEFW_CPU_BUDGET="4", PLATFORM="Linux", MAKEFW_TARGET_ARCH="linux_el8_x64",
                        MAKEFW_GCC_PCH="1" if pch else "0", MAKEFW_GCC_PCH_MIN_SOURCES="2")
        self.args = ["CONFIG=Debug", "IDENT=0"]
        self.output = self.directory / "lib" / "libprobe.a"

    def make(self, *goals, directory=None, extra=(), jobs=4):
        argv = ["make", "-w", *([f"-j{jobs}"] if jobs else []), *self.args, *extra, *goals]
        result = subprocess.run(argv, cwd=directory or self.directory, env=self.env,
                                capture_output=True, text=True, encoding="utf-8")
        output = result.stdout + result.stderr
        assert result.returncode == 0, output
        return output

    @staticmethod
    def compiled(output):
        return sorted(Path(match).name for match in COMPILE.findall(output + "\n"))

    def entered(self, output, directory):
        return output.count(f"Entering directory '{directory}'")

    def symbols(self):
        return run(["nm", "--defined-only", str(self.output)])

    def stamp(self):
        return self.output.stat().st_mtime_ns


def check_pch_and_traversal(root):
    fixture = Fixture(root, "pch")
    output = fixture.make()
    compiled = fixture.compiled(output)
    assert len(compiled) == PCH_SOURCES + 2, f"初回のコンパイル回数が不正です: {compiled}\n{output}"
    assert "-include" in output, f"自動 PCH が使われていません:\n{output}"
    for directory in (fixture.sub_a, fixture.sub_b):
        count = fixture.entered(output, directory)
        assert count == 1, f"{directory.name} の make の起動が {count} 回です:\n{output}"
    print("PASS: 初回のビルドで各サブディレクトリを 1 回だけたどる")

    stamp = fixture.stamp()
    output = fixture.make()
    assert not fixture.compiled(output), f"変更なしの再実行で再コンパイルしました:\n{output}"
    assert fixture.stamp() == stamp, "変更なしの再実行で再リンクしました"
    print("PASS: 自動 PCH を使うオブジェクトを再実行で再コンパイルしない")

    time.sleep(0.01)
    text = fixture.header.read_text(encoding="utf-8").replace("return 3", "return 4")
    fixture.header.write_text(text, encoding="utf-8")
    output = fixture.make()
    compiled = fixture.compiled(output)
    assert compiled == [f"gen_a_{index:02d}.o" for index in range(PCH_SOURCES)], \
        f"共通ヘッダーの更新後の再コンパイルが不正です: {compiled}\n{output}"
    assert fixture.stamp() != stamp, "共通ヘッダーの更新後に再リンクしません"
    (fixture.sub_a / "obj" / "gen_a_03.d").unlink()
    stamp = fixture.stamp()
    output = fixture.make()
    compiled = fixture.compiled(output)
    assert compiled == ["gen_a_03.o"], f".d の削除後の再コンパイルが不正です: {compiled}\n{output}"
    output = fixture.make()
    assert not fixture.compiled(output), f".d の再作成後の再実行で再コンパイルしました:\n{output}"
    print("PASS: 共通ヘッダーの更新と .d の削除で必要なソースだけを再コンパイルする")


def check_artifact_updates(root):
    fixture = Fixture(root, "artifact", pch=False)
    fixture.make()
    assert "b_symbol" in fixture.symbols()
    stamp = fixture.stamp()
    time.sleep(0.01)
    fixture.b_source.write_text(fixture.b_text.replace("2", "5"), encoding="utf-8")
    output = fixture.make()
    assert fixture.compiled(output) == ["b.o"], output
    assert fixture.stamp() != stamp, "サブディレクトリのソースの更新後に再リンクしません"
    fixture.b_source.unlink()
    fixture.make()
    assert "b_symbol" not in fixture.symbols(), "削除したソースのシンボルが残っています"
    fixture.b_source.write_text(fixture.b_text, encoding="utf-8")
    fixture.make()
    assert "b_symbol" in fixture.symbols(), "復元したソースのシンボルがありません"
    stamp = fixture.stamp()
    time.sleep(0.01)
    fixture.b_source.write_text(fixture.b_text.replace("2", "6"), encoding="utf-8")
    # 並列 make でも、親の成果物の更新はサブディレクトリのコンパイルの完了を待つ。
    output = fixture.make(directory=fixture.sub_b)
    assert fixture.compiled(output) == ["b.o"], output
    assert fixture.stamp() != stamp, "サブディレクトリの中での make で親の成果物を再リンクしません"
    print("PASS: サブディレクトリのソースの更新、削除、復元、サブディレクトリの中での make")


def check_no_race(root):
    fixture = Fixture(root, "race", pch=False)
    # GCC (as) は既存のオブジェクトを削除してから作り直す。存在しない時間を広げるため、
    # コンパイルの前に出力先を削除して待つ。sub_b の b.o は長く待ち、ジョブの枠を占有する。
    wrapper = fixture.root / "slow-cc.sh"
    wrapper.write_text('#!/bin/bash\nout=""; prev=""\n'
                       'for arg in "$@"; do [ "$prev" = "-o" ] && out="$arg"; prev="$arg"; done\n'
                       'if [ -n "$out" ] && [ -f "$out" ]; then\n'
                       '    rm -f "$out"\n'
                       '    case "$out" in */b.o) sleep 2.5 ;; *) sleep 1.5 ;; esac\n'
                       'fi\n'
                       'exec gcc "$@"\n', encoding="utf-8")
    wrapper.chmod(0o755)
    # sub_a を直列にし、ジョブの枠を取り合わないようにする。取り合うと、待っている sub_a が
    # 解放された枠を先に取り、親は sub_a の最後のコンパイルまで枠を得られず、競合の時刻が定まらない。
    (fixture.sub_a / "makelocal.mk").write_text(".NOTPARALLEL:\n", encoding="utf-8")
    extra = [f"CC={shlex.quote(str(wrapper))}"]
    fixture.make("test", extra=extra, jobs=2)
    sources = [fixture.directory / "root.c", fixture.b_source,
               *sorted(fixture.sub_a.glob("gen_a_*.c"))[:3]]
    for attempt in range(2):
        # 親は root.o のコンパイルのため、sub_b が占有するジョブの枠の解放を待つ (CI で起きた経路)。
        # 枠を得た時点で sub_a は gen_a_01.o を作り直している。順序がないと、親の確認が
        # 存在しないオブジェクトに当たり「make するルールがありません」で止まる。
        for path in sources:
            path.write_text(path.read_text(encoding="utf-8") + "\n", encoding="utf-8")
        output = fixture.make("test", extra=extra, jobs=2)
        assert len(fixture.compiled(output)) == len(sources), output
    print("PASS: サブディレクトリのソースの更新後の make test が、再コンパイル中のオブジェクトと競合しない")


def main():
    with tempfile.TemporaryDirectory(prefix="makefw-subdir-selftest-") as temporary:
        root = Path(temporary)
        check_pch_and_traversal(root)
        check_artifact_updates(root)
        check_no_race(root)
        warnings = [str(path) for path in root.rglob("*.warn") if path.stat().st_size]
        assert not warnings, f"警告ファイル: {warnings}"
    print("サブディレクトリを持つライブラリのビルドの検証に成功しました。")


if __name__ == "__main__":
    main()
