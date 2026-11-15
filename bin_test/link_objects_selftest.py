#!/usr/bin/env python3
"""ソース削除後の再リンクを、実際の C/C++ テンプレートで確認する。

Linux で実行する。Windows 分岐は MSVC / PowerShell の呼び出しを GCC / ar で
代行し、.obj 配置、応答ファイル、再リンク条件を確認する。Windows 実機の試験は別途必要。
"""

import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

# Windows の分岐も GCC と ar で代行するため、Linux だけで実行する (run-bin-tests.py が参照する)。
BIN_TEST_PLATFORM = "linux"

MAKEFW = Path(__file__).resolve().parents[1]
KEPT = "int kept_symbol(void) { return 13; }\n"
REMOVED = "int removed_symbol(void) { return 81; }\n"


def run(argv, **kwargs):
    result = subprocess.run(argv, capture_output=True, text=True, encoding="utf-8", **kwargs)
    if result.returncode:
        raise AssertionError(f"コマンド失敗: {argv}\n{result.stdout}\n{result.stderr}")
    return result.stdout


def fake_msvc(args):
    """Windows 専用ツールの起動部分だけを代行する。"""
    if "/fo" in args:
        output = args[args.index("/fo") + 1]
        result = subprocess.run(["gcc", "-fPIC", "-x", "c", "-c", "-o", output, "-"],
                                input="int resource_symbol(void) { return 7; }\n", text=True, encoding="utf-8")
        sys.exit(result.returncode)
    if any(arg.startswith("/MACHINE:") for arg in args):
        output = next(arg[5:] for arg in args if arg.startswith("/OUT:"))
        shutil.copyfile(args[-1], output)
        return
    if "-File" in args:
        script = Path(args[args.index("-File") + 1]).name
        if script == "msvc_compile.ps1":
            objdir = Path(args[args.index("-ObjDir") + 1])
            sources = args[args.index("-Sources") + 1].split()
            flags = args[args.index("-Flags") + 1].split()
            for source in sources:
                stem = Path(source).stem
                run(["gcc", "-fPIC", "-MMD", "-MF", str(objdir / (stem + ".d")),
                     "-c", source, "-o", str(objdir / (stem + ".obj"))])
            for flag in flags:
                if flag.startswith("/Fd:"):
                    Path(flag[4:]).touch()
        else:
            sys.stdout.write(sys.stdin.read())
        return
    output = Path(next(arg[5:] for arg in args if arg.startswith("/OUT:")))
    if os.environ.get("MAKEFW_SELFTEST_FAIL_LINK") == "1":
        output.write_bytes(b"partial output")
        sys.exit(1)
    objects = []
    for arg in args:
        if arg.startswith("@"):
            objects.extend(Path(arg[1:]).read_text(encoding="utf-8").split())
        elif arg.endswith(".res"):
            objects.append(arg)
    if output.suffix == ".lib":
        # lib.exe creates a library from its supplied inputs.
        output.unlink(missing_ok=True)
        run(["ar", "rcs", str(output), *objects])
    else:
        run(["gcc", *(["-shared"] if "/DLL" in args else []),
             "-o", str(output), *objects])
        if "/DLL" in args:
            output.with_suffix(".lib").touch()
            output.with_suffix(".exp").touch()
        output.with_suffix(".pdb").touch()


class Fixture:
    def __init__(self, root, platform, kind):
        self.platform = platform
        self.kind = kind
        self.root = root / (platform + "-" + kind)
        self.root.mkdir()
        (self.root / ".workspaceRoot").touch()
        (self.root / "framework").mkdir()
        (self.root / "framework" / "makefw").symlink_to(MAKEFW, target_is_directory=True)
        self.directory = self.root / "test" / ("src" if kind == "exe" else "libsrc") / "probe"
        self.directory.mkdir(parents=True)
        self.write_makefile(self.directory)
        (self.directory / "kept.c").write_text(KEPT, encoding="utf-8")
        (self.directory / "removed.c").write_text(REMOVED, encoding="utf-8")
        if kind == "exe":
            (self.directory / "main.c").write_text("int main(void) { return 0; }\n", encoding="utf-8")
        else:
            (self.directory / "makepart.mk").write_text(f"LIB_TYPE := {kind}\n", encoding="utf-8")
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("MAKEFW_") and key not in
                    ("MAKEFLAGS", "MFLAGS", "MAKELEVEL", "IDENT_ENABLED", "PLATFORM_LINUX", "PLATFORM_WINDOWS")}
        # テンプレートの include は MAKEFW_HOME をそのまま使うため、空白を含む配置先でも
        # 分割されないよう、作業ディレクトリ内のシンボリック リンクを指す。
        self.env.update(MAKEFW_HOME=str(self.root / "framework" / "makefw"), MAKEFW_FILES_LANG="C.UTF-8",
                        MAKEFW_CPU_BUDGET="2", PLATFORM=platform,
                        MAKEFW_TARGET_ARCH="windows_x64" if platform == "Windows" else "linux_el8_x64")
        self.args = ["CONFIG=Debug", "IDENT=0"]
        if platform == "Windows":
            tool = self.root / "fake-msvc.sh"
            tool.write_text("#!/bin/bash\nexec python3 " + shlex.quote(str(Path(__file__).resolve()))
                            + ' --fake-msvc "$@"\n', encoding="utf-8")
            tool.chmod(0o755)
            self.env.update(MAKEFW_BASH_PATH="/bin/bash", MAKEFW_CL_PATH=str(tool), MAKEFW_DOTNET_PATH="unused")
            self.args += [f"{name}={tool}" for name in ("CC", "CXX", "LD", "AR", "MAKEFW_POWERSHELL")]
            (self.root / "rc.exe").symlink_to(tool)
            self.env["PATH"] = str(self.root) + os.pathsep + self.env["PATH"]
            self.args += [f"CVTRES={tool}"]
            # Suppress automatic MSVC manifest objects; the test exercises source objects.
            if kind != "exe":
                self.args += ["LDFLAGS=/NOENTRY"]
        self.objdir = self.directory / ("obj/mdd" if platform == "Windows" else "obj")
        self.extension = ".obj" if platform == "Windows" else ".o"
        names = {"exe": ["probe.exe" if platform == "Windows" else "probe"],
                 "static": ["libprobe.lib" if platform == "Windows" else "libprobe.a"],
                 "shared": ["libprobe.dll" if platform == "Windows" else "libprobe.so"],
                 "both": ["libprobe_static.lib", "libprobe.dll"] if platform == "Windows"
                         else ["libprobe_static.a", "libprobe.so"]}[kind]
        self.outputs = [self.directory / ("bin" if kind == "exe" else "lib") / name for name in names]

    @staticmethod
    def write_makefile(directory):
        (directory / "makefile").write_text("include $(MAKEFW_HOME)/makefiles/__template.mk\n", encoding="utf-8")

    def build(self, directory=None, fail=False, extra=()):
        env = dict(self.env)
        if fail and self.platform == "Windows":
            env["MAKEFW_SELFTEST_FAIL_LINK"] = "1"
        argv = ["make", "--no-print-directory", "-j2", *self.args]
        if fail and self.platform == "Linux":
            argv += ["LD=false", "AR=false", "CC=false"]
        argv += extra
        result = subprocess.run(argv, cwd=directory or self.directory, env=env, capture_output=True, text=True, encoding="utf-8")
        assert bool(result.returncode) == fail, result.stdout + result.stderr
        return result.stdout

    def contains_removed(self):
        return ["removed_symbol" in run(["nm", "--defined-only", str(output)]) for output in self.outputs]

    def stamps(self):
        return [path.stat().st_mtime_ns for path in [*self.outputs, *sorted(self.objdir.glob("*.link.mk"))]]

    def check(self):
        self.build()
        assert all(self.contains_removed())
        stamps = self.stamps()
        if self.platform == "Linux":
            shell = self.root / "record-shell.sh"
            log = self.root / "shell.log"
            shell.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> '
                             + shlex.quote(str(log)) + '\nexec /bin/bash "$@"\n', encoding="utf-8")
            shell.chmod(0o755)
            self.build(extra=[f"SHELL={shell}"])
            assert "makefw_link_inputs=" not in log.read_text(encoding="utf-8"), "変更なしのビルドでリンク判定のシェルを起動"
        else:
            self.build()
        assert self.stamps() == stamps, "変更なしのビルドで成果物または保存一覧を更新"
        source = self.directory / "removed.c"
        source.unlink()
        states = {path: path.read_bytes() for path in self.objdir.glob("*.link.mk")}
        self.build(fail=True)
        assert all(path.read_bytes() == content for path, content in states.items()), "失敗時に保存一覧を更新"
        self.build()
        assert not any(self.contains_removed()), "削除したソースのシンボルが残存"
        assert (self.objdir / ("removed" + self.extension)).exists(), "古いオブジェクトを削除"
        stamps = self.stamps()
        self.build()
        assert self.stamps() == stamps, "削除後の変更なしビルドで再リンク"
        # Restore a source and a prebuilt object older than every output.
        source.write_text(REMOVED, encoding="utf-8")
        obj = self.objdir / ("removed" + self.extension)
        dep = self.objdir / "removed.d"
        run(["gcc", "-fPIC", "-MMD", "-MF", str(dep), "-c", str(source), "-o", str(obj)])
        old = min(path.stat().st_mtime for path in self.outputs) - 10
        for path in (source, obj, dep):
            os.utime(path, (old, old))
        self.build()
        assert all(self.contains_removed()), "古い日時のオブジェクト追加を検出できない"
        # Adoption into an already-built directory must refresh once.
        for path in self.objdir.glob("*.link.mk"):
            path.unlink()
        self.build()
        assert list(self.objdir.glob("*.link.mk")), "初回導入時に保存一覧を生成しない"
        for path in self.directory.glob("*.c"):
            path.unlink()
        self.build()
        assert not any(path.exists() for path in self.outputs), "全ソース削除後も成果物が残存"
        assert not list(self.objdir.glob("*.link.mk")), "全ソース削除後も保存一覧が残存"
        if self.platform == "Windows":
            assert not list(self.outputs[0].parent.glob("*.pdb")), "PDB が残存"
            assert not list(self.outputs[0].parent.glob("*.exp")), "EXP が残存"
        print(f"PASS: {self.platform}/{self.kind}")


def check_nested(root):
    fixture = Fixture(root, "Linux", "exe")
    child = fixture.directory / "child"
    child.mkdir()
    fixture.write_makefile(child)
    (fixture.directory / "makechild.mk").write_text("NO_LINK := 1\n", encoding="utf-8")
    (fixture.directory / "removed.c").rename(child / "removed.c")
    fixture.build()
    assert all(fixture.contains_removed())
    (child / "removed.c").unlink()
    fixture.build(directory=child)
    assert not any(fixture.contains_removed()), "子ディレクトリからの直接ビルドで親成果物が更新されない"
    stamps = fixture.stamps()
    fixture.build()
    assert fixture.stamps() == stamps, "子ディレクトリ削除後に不要な再リンク"
    print("PASS: サブディレクトリのソース削除と親成果物の更新")


def check_resources(root):
    for kind in ("exe", "static", "shared", "both"):
        fixture = Fixture(root, "Windows", kind)
        source = fixture.directory / "messages.rc"
        source.touch()
        fixture.build()
        assert all("resource_symbol" in run(["nm", "--defined-only", str(output)]) for output in fixture.outputs)
        source.unlink()
        fixture.build()
        assert not any("resource_symbol" in run(["nm", "--defined-only", str(output)]) for output in fixture.outputs)
        stamps = fixture.stamps()
        fixture.build()
        assert fixture.stamps() == stamps, "リソース削除後に不要な再リンク"
        print(f"PASS: Windows/{kind} のリソース削除")


def check_extra_objects(root):
    fixture = Fixture(root, "Linux", "static")
    for source in fixture.directory.glob("*.c"):
        source.unlink()
    generated = fixture.directory / "gen" / "generated.c"
    generated.parent.mkdir()
    generated.write_text(REMOVED, encoding="utf-8")
    fixture.objdir.mkdir()
    obj = fixture.objdir / "generated.o"
    run(["gcc", "-c", str(generated), "-o", str(obj)])
    config = fixture.directory / "makepart.mk"
    config.write_text("LIB_TYPE := static\nMAKEFW_BUILD := 1\nMAKEFW_EXTRA_OBJS += obj/generated.o\n", encoding="utf-8")
    fixture.build()
    assert all(fixture.contains_removed()), "追加オブジェクトだけのライブラリを生成しない"
    stamps = fixture.stamps()
    fixture.build()
    assert fixture.stamps() == stamps, "追加オブジェクトだけの構成で不要な再リンク"
    config.write_text("LIB_TYPE := static\nMAKEFW_BUILD := 1\n", encoding="utf-8")
    fixture.build()
    assert not any(output.exists() for output in fixture.outputs), "追加オブジェクト除去後も成果物が残存"
    assert obj.exists(), "追加オブジェクト自体を削除"
    print("PASS: 追加オブジェクトだけの構成と入力除去")


def check_partial_link(root):
    fixture = Fixture(root, "Linux", "exe")
    fixture.build()
    states = {path: path.read_bytes() for path in fixture.objdir.glob("*.link.mk")}
    (fixture.directory / "kept.c").write_text(KEPT.replace("13", "14"), encoding="utf-8")
    linker = fixture.root / "partial-link.sh"
    linker.write_text('#!/bin/bash\nwhile [ "$1" != "-o" ]; do shift; done\n'
                      'printf partial > "$2"\nexit 1\n', encoding="utf-8")
    linker.chmod(0o755)
    fixture.build(fail=True, extra=[f"LD={linker}", "CC=gcc"])
    assert not fixture.outputs[0].exists(), "失敗したリンクの途中の成果物が残存"
    assert all(path.read_bytes() == content for path, content in states.items())
    fixture.build()
    assert all(fixture.contains_removed()), "入力一覧が同じ場合に再試行できない"
    print("PASS: 入力一覧が同じリンクの失敗と再試行")


def check_crt_switch(root):
    fixture = Fixture(root, "Windows", "exe")
    fixture.build()
    first = fixture.stamps()
    fixture.build(extra=["MSVC_CRT=static"])
    assert list((fixture.directory / "obj/mtd").glob("*.link.mk")), "別 CRT の保存一覧がない"
    assert first[0] != fixture.outputs[0].stat().st_mtime_ns
    fixture.build()
    assert fixture.stamps() != first, "以前の CRT に戻したときに古い一覧でリンクを省略"
    stamps = fixture.stamps()
    fixture.build()
    assert fixture.stamps() == stamps, "CRT 切り替え後に不要な再リンク"
    print("PASS: Windows の CRT 切り替えと復帰")


def check_empty_crt_switch(root):
    for kind in ("exe", "static", "shared", "both"):
        fixture = Fixture(root, "Windows", kind)
        fixture.build()
        for source in fixture.directory.glob("*.c"):
            source.unlink()
        fixture.build(extra=["MSVC_CRT=static"])
        assert not any(output.exists() for output in fixture.outputs), "全ソース削除と CRT 切り替え後も成果物が残存"
        assert (fixture.objdir / "removed.obj").exists(), "切り替え前のオブジェクトを削除"
        print(f"PASS: Windows/{kind} の全ソース削除後の CRT 切り替え")


def check_long_command():
    """保存した入力一覧が長くても、シェルのコマンドへ展開しないことを確認する。"""
    with tempfile.TemporaryDirectory(prefix="makefw-long-link-") as temporary:
        root = Path(temporary)
        (root / "bin_internal").mkdir()
        (root / "obj").mkdir()
        (root / "bin_internal/filter_existing_source_objs.sh").write_text(
            '#!/bin/bash\ncat inputs.lst\n', encoding="utf-8")
        output = root / "probe.lib"
        output.touch()
        inputs = [f"nested/obj/md/mock_function_{i:04d}_with_a_long_name.obj" for i in range(1000)]
        (root / "inputs.lst").write_text("\n".join(inputs) + "\n", newline="\n", encoding="utf-8")
        state = root / "obj/probe.lib.link.mk"
        state.write_text(f"_MAKEFW_LINKED_OUTPUT_probe.lib := {output.as_posix()}\n"
                         + "_MAKEFW_LINKED_INPUTS_probe.lib := " + " ".join(inputs) + "\n", newline="\n", encoding="utf-8")
        (root / "makefile").write_text(
            f"SHELL := {shutil.which('bash').replace(chr(92), '/')}\n"
            f"MAKEFW_HOME := {root.as_posix()}\n"
            "OBJDIR := obj\nOUTPUT_DIR := .\nTARGET := probe.lib\nLIB_TYPE := static\n"
            "PLATFORM_WINDOWS := 1\nMSVC_CRT_SUBDIR := md\n"
            # 空白を含む配置先でも 1 つのパスとして読み込むため、空白を \ で保護する。
            f"include {MAKEFW.as_posix().replace(' ', chr(92) + ' ')}/makefiles/_link_objects.mk\n"
            ".PHONY: check\ncheck: probe.lib\nprobe.lib: FORCE\n"
            "\t@$(_MAKEFW_OBJLIST_WINDOWS); [ \"$$rebuild\" = \"$(EXPECTED)\" ] || exit 1; "
            "_rc=0; $(_MAKEFW_SAVE_LINK_OBJECTS)\n.PHONY: FORCE\nFORCE:\n", encoding="utf-8")
        env = {key: value for key, value in os.environ.items()
               if key not in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL")}
        argv = ["make", "--no-print-directory", "check"]
        env["AR"] = "tool " + " ".join(f"argument_{i:04d}" for i in range(1000))
        run([*argv, "EXPECTED=1"], cwd=root, env=env)
        (root / "inputs.lst").write_text("\n".join(inputs[:-1]) + "\n", newline="\n", encoding="utf-8")
        run([*argv, "EXPECTED=1"], cwd=root, env=env)
        run([*argv, "EXPECTED=0"], cwd=root, env=env)
        print("PASS: 長いリンク入力一覧の比較、削除検出、保存後の再比較")



def check_link_configuration(root, platforms=("Linux", "Windows"), kinds=("exe", "static", "shared", "both")):
    for platform in platforms:
        for kind in kinds:
            fixture = Fixture(root, platform, kind)
            fixture.build()
            object_times = {p: p.stat().st_mtime_ns for p in fixture.objdir.glob("*" + fixture.extension)}
            tool_name = "AR" if kind == "static" else ("CC" if platform == "Linux" and kind != "exe" else "LD")
            alternate = fixture.root / "alternate-tool"
            tool = fixture.root / "fake-msvc.sh" if platform == "Windows" else Path(shutil.which("ar" if kind == "static" else "gcc"))
            alternate.symlink_to(tool)
            changes = [[f"{tool_name}={alternate}"]]
            if kind != "static":
                flags = "/NOENTRY /DEBUG:NONE" if platform == "Windows" else "-Wl,--build-id=none"
                changes.append([f"LDFLAGS={flags}"])
                libraries = fixture.root / "prebuilt"
                libraries.mkdir()
                for name in ("first", "second"):
                    lib = libraries / (f"lib{name}.lib" if platform == "Windows" else f"lib{name}.a")
                    run(["ar", "rcs", str(lib)])
                    os.utime(lib, (1, 1))
                for names in ("first second", "second first", "first", ""):
                    changes.append([f"LIBSDIR={libraries}", f"LIBS={names}"])
            elif platform == "Windows":
                changes.append(["LIB_LTCG=/LTCG"])
            for extra in changes:
                if any(arg.startswith("LIBSDIR=") for arg in extra):
                    content = ("" if kind == "exe" else f"LIB_TYPE := {kind}\n")
                    content += "\n".join(arg.replace("=", " := ", 1) for arg in extra) + "\n"
                    (fixture.directory / "makepart.mk").write_text(content, encoding="utf-8")
                    extra = []
                before = fixture.stamps()
                static_stamp = fixture.outputs[0].stat().st_mtime_ns
                fixture.build(extra=extra)
                if kind == "both":
                    assert fixture.outputs[0].stat().st_mtime_ns == static_stamp, "共有リンク構成の変更で静的出力を再生成"
                assert before != fixture.stamps(), (platform, kind, extra, "構成変更を検出しない")
                after = fixture.stamps()
                fixture.build(extra=extra)
                assert after == fixture.stamps(), (platform, kind, "構成不変で再生成")
            assert object_times == {p: p.stat().st_mtime_ns for p in object_times}, "リンク変更で再コンパイル"
            # Old records migrate once without deleting the binary.
            fixture.build()
            for state in fixture.objdir.glob("*.link.mk"):
                text = state.read_text(encoding="utf-8")
                state.write_text("\n".join(line for line in text.splitlines() if not line.startswith("_MAKEFW_LINKED_CONFIG_")) + "\n", encoding="utf-8")
            before = [p.stat().st_mtime_ns for p in fixture.outputs]
            fixture.build()
            assert before != [p.stat().st_mtime_ns for p in fixture.outputs], "旧記録で再リンクしない"
            after = fixture.stamps()
            fixture.build()
            assert after == fixture.stamps(), "旧記録の移行後に再リンク"
            print(f"PASS: {platform}/{kind} のツール・フラグ・ライブラリ構成と旧記録の移行")


def check_configuration_encoding():
    with tempfile.TemporaryDirectory(prefix="makefw-encoding-") as temporary:
        root = Path(temporary)
        # Feed raw values through the environment, avoiding any test-side Make quoting.
        makefile = root / "makefile"
        makefile.write_text(
            "OBJDIR := obj\nOUTPUT_DIR := bin\nTARGET := probe\nMAKEFW_LINK_KIND := executable\n"
            f"include {MAKEFW.as_posix()}/makefiles/_link_objects.mk\n"
            ".PHONY: check\ncheck:\n\t@printf '%s\\n' '$(call _makefw_link_encode,$(value RAW))'\n", encoding="utf-8")
        samples = ['"a  b"', '"a b"', "'", "%27", "__MAKEFW_SQUOTE__", '$#\\', 'a|b', 'a\tb', 'a\nb', 'a`b']
        values = []
        for sample in samples:
            env = dict(os.environ, RAW=sample)
            values.append(run(["make", "--no-print-directory", "check"], cwd=root, env=env).strip())
        assert len(values) == len(set(values)), values
        assert "%20%20" in values[0]
        assert "%24%23%5C" == values[5], values[5]
        assert "%09" in values[7] and "%0A" in values[8]
        (root / "obj").mkdir()
        (root / "bin_internal").mkdir()
        (root / "bin_internal/filter_existing_source_objs.sh").write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        makefile.write_text(
            f"MAKEFW_HOME := {root.as_posix()}\nOBJDIR := obj\nOUTPUT_DIR := .\nTARGET := probe\n"
            "MAKEFW_LINK_KIND := executable\nLD = $(value RAW)\n"
            f"include {MAKEFW.as_posix()}/makefiles/_link_objects.mk\n"
            ".PHONY: statecheck FORCE\nstatecheck: probe\nprobe: FORCE\n"
            "\t@$(_MAKEFW_OBJLIST_LINUX); printf '%s\\n' \"$$rebuild\"; _rc=0; $(_MAKEFW_SAVE_LINK_OBJECTS)\nFORCE:\n", encoding="utf-8")
        (root / "probe").touch()
        for sample in samples:
            env = dict(os.environ, RAW=sample)
            assert run(["make", "--no-print-directory", "statecheck"], cwd=root, env=env).strip() == "1"
            assert run(["make", "--no-print-directory", "statecheck"], cwd=root, env=env).strip() == "0"
        print("PASS: 引用符・空白・記号の衝突防止と状態保存・再読取")


def main():
    if sys.argv[1:] and sys.argv[1] == "--fake-msvc":
        fake_msvc(sys.argv[2:])
        return
    if sys.argv[1:] == ["--long-command"]:
        check_long_command()
        return
    check_long_command()
    check_configuration_encoding()
    with tempfile.TemporaryDirectory(prefix="makefw-link-selftest-") as temporary:
        root = Path(temporary)
        for platform in ("Linux", "Windows"):
            for kind in ("exe", "static", "shared", "both"):
                Fixture(root, platform, kind).check()
        nested = root / "nested"
        nested.mkdir()
        check_nested(nested)
        resources = root / "resources"
        resources.mkdir()
        check_resources(resources)
        extra = root / "extra"
        extra.mkdir()
        check_extra_objects(extra)
        failure = root / "partial"
        failure.mkdir()
        check_partial_link(failure)
        crt = root / "crt"
        crt.mkdir()
        check_crt_switch(crt)
        empty_crt = root / "empty-crt"
        empty_crt.mkdir()
        check_empty_crt_switch(empty_crt)
        configuration = root / "configuration"
        configuration.mkdir()
        check_link_configuration(configuration)
        warnings = [str(path) for path in root.rglob("*.warn") if path.stat().st_size]
        assert not warnings, f"警告ファイル: {warnings}"
    print("ソース削除後の再リンク検証に成功しました。Windows 実機の検証は含みません。")


if __name__ == "__main__":
    main()
