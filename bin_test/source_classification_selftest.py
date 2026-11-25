#!/usr/bin/env python3
"""多数の外部ソースの分類・反復ビルド・元ソース更新・clean を実テンプレートで確認する。"""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

MAKEFW = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash") or "bash"


def run(directory, args, env):
    result = subprocess.run(["make", "--no-print-directory", "-j2", "IDENT=0", *args],
                            cwd=directory, env=env, capture_output=True, encoding="utf-8", timeout=240)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "unexpected EOF" not in result.stderr, result.stderr
    return result.stdout


def write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8", newline="\n")



def check_directory_aliases(root, home, external, env):
    # 単体の共通関数を通して、存在しない入力と現在ディレクトリの別名を確認する。
    probe = root / "probe"
    probe.mkdir()
    write(probe / "local.c", "")
    write(external / "external.c", "")
    alias = "../probe/./local.c"
    write(probe / "makefile", f"SHELL := {BASH.replace(chr(92), '/')}\n"
          f"include {home.as_posix().replace(chr(32), chr(92) + chr(32))}/makefiles/_path_functions.mk\n"
          ".PHONY: check\ncheck:\n"
          "\t@printf '%s\\n' '$(call _makefw_source_directory_kind,missing/no.c)' "
          f"'$(call _makefw_source_directory_kind,{alias})' "
          "'$(call _makefw_source_directory_kind,../external_sources_with_a_long_directory_name/external.c)'\n")
    assert run(probe, ["check"], env).splitlines() == ["missing", "local", "external"]
    if os.name != "nt":
        (root / "alias").symlink_to(probe, target_is_directory=True)
        text = (probe / "makefile").read_text(encoding="utf-8").replace(alias, "../alias/local.c")
        write(probe / "makefile", text)
        assert run(probe, ["check"], env).splitlines() == ["missing", "local", "external"]
        (probe / ".hidden.c").symlink_to("local.c")
        with (probe / "makefile").open("a", encoding="utf-8", newline="\n") as output:
            output.write(".PHONY: links\nlinks:\n\t@printf '%s\\n' '$(call _makefw_source_link_names,$(_makefw_source_link_scan))'\n")
        assert "./.hidden.c" in run(probe, ["links"], env).split()
    else:
        text = (probe / "makefile").read_text(encoding="utf-8").replace(alias, probe.as_posix().upper() + "/local.c")
        write(probe / "makefile", text)
        assert run(probe, ["check"], env).splitlines() == ["missing", "local", "external"]
    print("PASS: missing directories and directory aliases")

def check_source_switch(root, home, env):
    """inject ファイルとフィルター ファイルの追加・削除による、リンクとコピーの切り替わりを確認する。"""
    if os.name == "nt":
        print("SKIP: 引き込み方の切り替わり (Windows は常にコピーで引き込みます)")
        return
    external = root / "external_switch"
    source_a, source_b = external / "a.c", external / "b.c"
    for kind, relative in (("library", "app/probe/prod/libsrc/switch"), ("executable", "app/probe/prod/src/switch")):
        directory = root / relative
        write(directory / "makefile", (home / "makefiles/__template.mk").read_text(encoding="utf-8"))
        if kind == "executable":
            write(directory / "main.c", "int main(void) { return 0; }\n")
        write(source_a, "int function_a(void) { return 1; }\n")
        write(source_b, "int function_b(void) { return 2; }\n")
        relative_sources = [Path(os.path.relpath(p, directory)).as_posix() for p in (source_a, source_b)]
        write(directory / "makepart.mk", "ADD_SRCS := " + " ".join(relative_sources) + "\n")
        local_a, local_b = directory / "a.c", directory / "b.c"
        inject, filter_file = directory / "a.inject.c", directory / "b.c.filter.sh"
        obj_a, obj_b = directory / "obj/a.o", directory / "obj/b.o"

        # 段階 1: リンクで引き込む
        run(directory, ["build"], env)
        assert local_a.is_symlink() and local_b.is_symlink(), f"{kind}: stage 1"

        # 段階 2: inject を追加してコピー元を編集し、ドライ ランがファイルを変えないことを確認する
        time.sleep(1.1)
        write(inject, "int inject_a(void) { return 3; }\n")
        write(source_a, "int function_a(void) { return 10; }\n")
        run(directory, ["-n", "build"], env)
        assert local_a.is_symlink(), f"{kind}: stage 2 (make -n changed the file)"

        # 段階 3: リンクからコピーへ置き換わる
        run(directory, ["build"], env)
        text = local_a.read_text(encoding="utf-8")
        assert not local_a.is_symlink() and "return 10" in text and text.rstrip().splitlines()[-2] == '#include "a.inject.c"', f"{kind}: stage 3\n{text}"

        # 段階 4: 再実行しても再コンパイルされない
        stamp = obj_a.stat().st_mtime_ns
        run(directory, ["build"], env)
        assert obj_a.stat().st_mtime_ns == stamp, f"{kind}: stage 4"

        # 段階 5: コピー元の編集がコピーへ反映される
        time.sleep(1.1)
        write(source_a, "int function_a(void) { return 11; }\n")
        run(directory, ["build"], env)
        text = local_a.read_text(encoding="utf-8")
        assert "return 11" in text and '#include "a.inject.c"' in text, f"{kind}: stage 5\n{text}"

        # 段階 6: フィルター ファイルを追加しても、コピー元が壊れない
        write(filter_file, "sed 's/return 2/return 20/'\n")
        run(directory, ["build"], env)
        assert source_b.read_text(encoding="utf-8") == "int function_b(void) { return 2; }\n", f"{kind}: stage 6 (source changed)"
        assert not local_b.is_symlink() and "return 20" in local_b.read_text(encoding="utf-8"), f"{kind}: stage 6"

        # 段階 7: inject とフィルターを削除すると、リンクへ戻る
        inject.unlink()
        filter_file.unlink()
        run(directory, ["build"], env)
        assert local_a.is_symlink() and local_b.is_symlink(), f"{kind}: stage 7"

        # 段階 8: コピー元の編集がリンク経由で反映され、再コンパイルされる
        stamp = obj_b.stat().st_mtime_ns
        time.sleep(1.1)
        write(source_b, "int function_b(void) { return 21; }\n")
        run(directory, ["build"], env)
        assert "return 21" in local_b.read_text(encoding="utf-8"), f"{kind}: stage 8"
        assert obj_b.stat().st_mtime_ns != stamp, f"{kind}: stage 8 (not recompiled)"
        print(f"PASS: switching between link and copy ({kind})")


def main():
    with tempfile.TemporaryDirectory(prefix="makefw-classification-") as temporary:
        root = Path(temporary)
        home = root / "framework/makefw"
        for name in ("makefiles", "bin_internal"):
            shutil.copytree(MAKEFW / name, home / name)
        write(root / ".workspaceRoot", "")
        directory = root / "app/probe/prod/libsrc/probe"
        write(directory / "makefile", (home / "makefiles/__template.mk").read_text(encoding="utf-8") + "\n"
              ".PHONY: classify\nclassify:\n"
              "\t@printf 'DIRECT=%s COPY=%s LINK=%s\\n' '$(words $(DIRECT_SRCS))' '$(words $(CP_SRCS))' '$(words $(LINK_SRCS))'\n")
        external = root / "external_sources_with_a_long_directory_name"
        sources = []
        for i in range(80):
            path = external / f"source_{i:03d}_with_a_long_name_for_source_classification.c"
            write(path, f"int function_{i}(void) {{ return {i}; }}\n")
            sources.append(path)
        relative = [Path(os.path.relpath(p, directory)).as_posix() for p in sources]
        write(directory / "makepart.mk", "ADD_SRCS := " + " ".join(relative) + "\n")
        env = {key: value for key, value in os.environ.items()
               if not key.startswith("MAKEFW_") and key not in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL", "WORKSPACE_DIR", "MYAPP_DIR", "APP_DIR")}
        env["MAKEFW_HOME"] = home.as_posix()
        env["MAKEFW_CL_MP_JOBS"] = "2"
        env["MAKEFW_FILES_LANG"] = "C.UTF-8"
        run(directory, ["-n", "build"], env)
        assert not list(directory.rglob("*.expected")), "dry run wrote link configuration"
        run(directory, ["build"], env)
        expected = "DIRECT=0 COPY=80 LINK=0" if os.name == "nt" else "DIRECT=0 COPY=0 LINK=80"
        assert expected in run(directory, ["classify"], env)
        objects = list((directory / "obj").rglob("*.obj" if os.name == "nt" else "*.o"))
        assert len(objects) == 80, len(objects)
        stamps = {p: p.stat().st_mtime_ns for p in objects}
        run(directory, ["build"], env)
        assert expected in run(directory, ["classify"], env)
        assert stamps == {p: p.stat().st_mtime_ns for p in objects}, "unchanged build recompiled objects"
        time.sleep(1.1)
        write(sources[-1], "int function_79(void) { return 100; }\n")
        run(directory, ["build"], env)
        changed = [p for p in objects if p.stat().st_mtime_ns != stamps[p]]
        assert any(p.stem == sources[-1].stem for p in changed), changed
        if os.name == "nt":
            assert len(changed) == 1, changed
        assert "return 100" in (directory / sources[-1].name).read_text(encoding="utf-8")
        run(directory, ["clean"], env)
        assert not any((directory / p.name).exists() for p in sources), "clean left imported sources"
        print("PASS: 80 external sources, repeat build, last-source update and clean")

        # 外部のソースと同名のローカル実体は、以前の引き込みの残骸として扱い、両 OS で引き込み直す。
        # Linux では次のビルドでリンクへ置き換わる。Windows ではコピーした実体と区別できないため、
        # 外部のソースが更新された次のビルドでコピーへ置き換わる。
        write(directory / sources[0].name, "int local_override(void) { return 1; }\n")
        result = run(directory, ["classify"], env)
        assert expected in result, result
        if os.name == "nt":
            time.sleep(1.1)
            os.utime(sources[0])
        run(directory, ["build"], env)
        if os.name != "nt":
            assert (directory / sources[0].name).is_symlink(), "local file was not replaced by a link"
        assert "return 0" in (directory / sources[0].name).read_text(encoding="utf-8")
        print("PASS: local file with an external source name is replaced")

        check_directory_aliases(root, home, external, env)
        check_source_switch(root, home, env)
        warnings = [p for p in root.rglob("*.warn") if p.stat().st_size]
        assert not warnings, warnings


if __name__ == "__main__":
    main()
