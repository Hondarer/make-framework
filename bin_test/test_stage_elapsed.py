"""app 直下の makefile が表示する段階ごとの経過時間を確認する。

テンプレート (__each_app_template.mk) を一時ディレクトリの app へ複製し、
依存の解決スクリプトは固定の値を返すものに差し替える。
prod と test の makefile は、ビルドとテストの実行の代わりに何もしないか、失敗するだけとする。
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

MAKEFW = Path(__file__).resolve().parents[1]
# PATH 上の bash を明示し、Windows の System32 にある WSL 用 bash を避ける。
# see: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw
BASH = shutil.which("bash") or "bash"

ELAPSED = r"elapsed=\d{2}:\d{2}$"


class StageElapsedTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="makefw stage elapsed ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "app" / "sample"
        shutil.copytree(MAKEFW / "makefiles", self.root / "framework" / "makefw" / "makefiles")
        self.app.mkdir(parents=True)
        shutil.copyfile(MAKEFW / "makefiles" / "__each_app_template.mk", self.app / "makefile")
        self.write("framework/makefw/bin_internal/resolve_app_deps.sh", """#!/bin/bash
case "$1" in
 --signature) printf 'CLEAN=1\\nSIGNATURE_MODE=%s\\n' "$3" ;;
 --paths-all) printf 'INCLUDE:%s/prod/include\\n' "$2" ;;
 *) exit 8 ;;
esac
""")
        self.write_child("prod")
        self.write_child("test")
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith("MAKEFW_")
            and key not in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL", "WORKSPACE_DIR")
        }

    def write(self, relative, content):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8", newline="\n")

    def write_child(self, directory, status=0):
        self.write(
            f"app/sample/{directory}/makefile",
            "SHELL := /bin/bash\n.PHONY: default _test_run clean\n"
            f"default _test_run clean:\n\t@exit {status}\n",
        )

    def make(self, goal="default", success=True):
        result = subprocess.run(
            ["make", "--no-print-directory", "SHELL=" + BASH,
             "MAKEFW_HOME=" + (self.root / "framework" / "makefw").as_posix(),
             "WORKSPACE_DIR=" + self.root.as_posix(), goal],
            cwd=self.app, env=self.env, capture_output=True,
            encoding="utf-8", errors="replace", timeout=120,
        )
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode == 0, success, output)
        return [line for line in output.splitlines() if "elapsed=" in line]

    def assert_stages(self, lines, stages):
        self.assertEqual(len(lines), len(stages), lines)
        for line, stage in zip(lines, stages):
            self.assertRegex(line, "^INFO: sample " + re.escape(stage) + " " + ELAPSED)

    def test_build_and_test_show_each_stage(self):
        self.assert_stages(self.make(), ["prod", "test"])
        # 署名が一致してビルドを省いた場合は、子 make を実行しないため表示しない。
        self.assert_stages(self.make(), [])
        self.assert_stages(self.make("test"), ["test _test_run"])
        self.assert_stages(self.make("test"), [])

    def test_failed_stage_is_shown_and_stops_build(self):
        self.write_child("prod", status=3)
        self.assert_stages(self.make(success=False), ["prod"])
        self.assertFalse((self.app / "make_build.stamp").exists())

    def test_other_goals_do_not_show_elapsed(self):
        self.assert_stages(self.make("clean"), [])


if __name__ == "__main__":
    unittest.main()
