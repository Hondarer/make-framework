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

        # Linux では同名ローカル実体を優先し、Windows では外部からのコピーを追跡する。
        write(directory / sources[0].name, "int local_override(void) { return 1; }\n")
        result = run(directory, ["classify"], env)
        assert ("DIRECT=0 COPY=80 LINK=0" if os.name == "nt" else "DIRECT=1 COPY=0 LINK=79") in result
        print("PASS: native platform local-file precedence")

        check_directory_aliases(root, home, external, env)
        warnings = [p for p in root.rglob("*.warn") if p.stat().st_size]
        assert not warnings, warnings


if __name__ == "__main__":
    main()
