#!/usr/bin/env python3
"""依存パスの解決時期、子 make への継承、一括出力を局所確認する。"""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

MAKEFW = Path(__file__).resolve().parents[1]


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")


def run(args, cwd, env, success=True):
    result = subprocess.run(args, cwd=cwd, env=env, capture_output=True,
                            text=True, encoding="utf-8", errors="replace")
    if (result.returncode == 0) != success:
        raise AssertionError(f"{args}\n{result.stdout}\n{result.stderr}")
    return result.stdout


def check_template(root):
    app = root / "app" / "sample"
    shutil.copyfile(MAKEFW / "makefiles" / "__each_app_template.mk", app / "makefile")
    write(root / "framework" / "makefw" / "bin_internal" / "resolve_app_deps.sh", '''#!/bin/bash
case "$1" in
 --signature) printf 'CLEAN=1\\nSIGNATURE_MODE=%s\\n' "$3" ;;
 --paths-all)
  printf 'paths\\n' >> "$PATHS_LOG"
  [ "${FAIL_PATHS:-0}" != 1 ] || exit 7
  printf 'INCLUDE:%s/prod/include\\nSYSTEM_INCLUDE:%s/vendor/include\\nTESTINC:%s/test/include\\n' "$2" "$2" "$2"
  ;;
 *) exit 8 ;;
esac
''')
    for directory in ("prod", "test"):
        write(app / directory / "makefile", '''SHELL := /bin/bash
.PHONY: default _test_run clean
default _test_run clean:
	@printf '%s\\n' "$$MAKEFW_APP_PATHS_CACHE_APP" >> "$$CHILD_LOG"
	@printf '%s\\n' "$$MAKEFW_APP_PATHS_CACHE" >> "$$CHILD_LOG"
''')
    env = os.environ.copy()
    env.pop("MAKEFW_APP_PATHS_CACHE_APP", None)
    env.pop("MAKEFW_APP_PATHS_CACHE", None)
    env["PATHS_LOG"] = (root / "paths.log").as_posix()
    env["CHILD_LOG"] = (root / "children.log").as_posix()
    args = ["make", "--no-print-directory", "SHELL=bash",
            "MAKEFW_HOME=" + (root / "framework" / "makefw").as_posix(),
            "WORKSPACE_DIR=" + root.as_posix()]

    def make(goal="default", count=0, success=True):
        write(root / "paths.log", "")
        write(root / "children.log", "")
        output = run([*args, goal], app, env, success)
        assert len((root / "paths.log").read_text().splitlines()) == count, output
        return (root / "children.log").read_text(), output

    children, _ = make(count=1)
    assert children.count("SYSTEM_INCLUDE:") == 2, children
    assert children.count("TESTINC:") == 2, children
    children, output = make()
    assert not children and "Skipping build" in output, output
    make("test", count=1)
    children, output = make("test")
    assert not children and "Skipping test" in output, output
    children, _ = make("doxy")
    assert not children
    make("_makefw_with_cov_prod", count=1)
    env["MAKEFW_APP_PATHS_CACHE_APP"] = app.as_posix()
    env["MAKEFW_APP_PATHS_CACHE"] = "INCLUDE:cached TESTINC:cached"
    children, _ = make("_makefw_with_cov_prod")
    assert "INCLUDE:cached TESTINC:cached" in children, children
    env["MAKEFW_APP_PATHS_CACHE_APP"] = "another-app"
    make("_makefw_with_cov_prod", count=1)
    env["FAIL_PATHS"] = "1"
    children, _ = make("_makefw_with_cov_prod", count=1, success=False)
    assert not children
    (app / "make_build.stamp").unlink()
    children, _ = make(count=1, success=False)
    assert not children and not (app / "make_build.stamp").exists()
    env.pop("FAIL_PATHS")
    make("clean", count=2)
    for directory in ("prod", "test"):
        (app / directory / "makefile").unlink()
    children, _ = make()
    assert not children
    print("PASS: 解決の遅延、prod/test 継承、省略、キャッシュの対象、失敗、clean")


def check_resolver(root):
    resolver = root / "framework" / "makefw" / "bin_internal" / "resolve_app_deps.sh"
    shutil.copyfile(MAKEFW / "bin_internal" / "resolve_app_deps.sh", resolver)
    write(root / "app" / "sample" / "appdeps.mk", "APP_DEPS := vendor\n")
    write(root / "app" / "vendor" / "appdeps.mk", "APP_PROD_INCLUDE_CLASS := system\n")
    for app_name in ("sample", "vendor"):
        for suffix in ("prod/include", "prod/lib", "test/include", "test/lib"):
            (root / "app" / app_name / suffix).mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    app = root / "app" / "sample"
    for test in (False, True):
        output = run(["bash", str(resolver), "--paths-all", str(app),
                      *(["test"] if test else [])], root, env)
        kinds = [line.split(":", 1)[0] for line in output.splitlines()]
        assert kinds == ["INCLUDE", "SYSTEM_INCLUDE", "INTERNAL", "LIB", "LIB"] + (
            ["TESTINC", "TESTINC", "TESTLIB", "TESTLIB"] if test else []), output
        for kind, suffix in (("INCLUDE", "include"), ("LIB", "lib"),
                             ("TESTINC", "test_include"), ("TESTLIB", "test_lib")):
            if not test and kind.startswith("TEST"):
                continue
            individual = run(["bash", str(resolver), "--paths", str(app), suffix], root, env)
            combined = [line.split(":", 1)[1] for line in output.splitlines()
                        if line.startswith(kind + ":") or
                        (kind == "INCLUDE" and line.startswith("SYSTEM_INCLUDE:"))]
            assert combined == individual.split(), (combined, individual)
    if os.name == "nt":
        env["CYGPATH_LOG"] = (root / "cygpath.log").as_posix()
        write(root / "cygpath.log", "")
        wrapper = '''cygpath() { printf 'call\\n' >> "$CYGPATH_LOG"; builtin command cygpath "$@"; }
export -f cygpath
exec bash "$@"
'''
        run(["bash", "-c", wrapper, "selftest", str(resolver), "--paths-all",
             str(app), "test"], root, env)
        assert (root / "cygpath.log").read_text().splitlines() == ["call"]
        for conversion in ("return 9", "printf 'one-path\\n'"):
            wrapper = f'cygpath() {{ {conversion}; }}; export -f cygpath; exec bash "$@"'
            run(["bash", "-c", wrapper, "selftest", str(resolver), "--paths-all",
                 str(app), "test"], root, env, success=False)
        print("PASS: cygpath の起動 1 回、変換失敗、出力件数の不一致")
    write(root / "app" / "vendor" / "appdeps.mk", "APP_PROD_INCLUDE_CLASS := invalid\n")
    run(["bash", str(resolver), "--paths-all", str(app)], root, env, success=False)
    write(root / "app" / "sample" / "appdeps.mk", "APP_DEPS := missing\n")
    run(["bash", str(resolver), "--paths-all", str(app)], root, env, success=False)
    print("PASS: 一括出力と個別出力の一致、system include、test の有無、無効な種別")


def main():
    with tempfile.TemporaryDirectory(prefix="makefw-paths-") as directory:
        root = Path(directory)
        (root / ".workspaceRoot").touch()
        (root / "app" / "sample").mkdir(parents=True)
        check_template(root)
        check_resolver(root)


if __name__ == "__main__":
    main()
