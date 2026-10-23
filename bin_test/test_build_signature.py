#!/usr/bin/env python3
"""ビルド署名に testfw の入力が含まれることを、空白を含む一時ワークスペースで確認する。"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

# Windows の subprocess は System32 を PATH より先に探すため、名前だけで起動すると
# WSL の bash.exe を選ぶことがある。PATH 上の bash (Git Bash など) を明示して使う。
# see: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw
BASH = shutil.which("bash") or "bash"

MAKEFW = Path(__file__).resolve().parents[1]

# testfw の list_signature_scripts.sh の代わりに、bin_internal/ 直下のスクリプトを出力する。
LIST_SIGNATURE_SCRIPTS = """#!/bin/bash
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit
for path in "$script_dir"/*.py "$script_dir"/*.sh; do
    [ -f "$path" ] && printf '%s\\n' "$path"
done | LC_ALL=C sort
"""


class BuildSignatureTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="makefw signature ")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve() / "workspace space"
        shutil.copytree(MAKEFW / "bin_internal", self.root / "framework/makefw/bin_internal")
        self.write(".workspaceRoot", "")
        self.write("app/tested/makefile", "")
        self.write("app/tested/prod/libsrc/tested.c", "int tested(void) { return 1; }\n")
        self.write("app/tested/test/makefile", "")
        self.write("app/untested/makefile", "")
        self.write("app/untested/prod/libsrc/untested.c", "int untested(void) { return 1; }\n")
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith("MAKEFW_")
            and key not in ("WORKSPACE_DIR", "CONFIG", "CFLAGS", "CXXFLAGS", "LDFLAGS", "DEFINES", "LIBS")
        }
        self.env["MAKEFW_ASSURED_ACTIVE"] = "0"

    def write(self, path, content):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        with open(target, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)
        return target

    def write_testfw(self):
        self.write("framework/testfw/makefile", "")
        self.write("framework/testfw/bin_internal/list_signature_scripts.sh", LIST_SIGNATURE_SCRIPTS)
        self.write("framework/testfw/bin_internal/results.py", "print('result')\n")
        self.write("framework/testfw/libsrc/mock/mock.cc", "int mock() { return 0; }\n")
        self.write("framework/testfw/libsrc/mock/obj/mock.o", "object\n")
        self.write("framework/testfw/include/testfw.h", "#define TESTFW 1\n")
        self.write("framework/testfw/gtest/TARGET_GTEST_VERSION", "1.0.0\n")

    def signature(self, app, mode):
        result = subprocess.run(
            [BASH, str(self.root / "framework/makefw/bin_internal/resolve_app_deps.sh"),
             "--signature", (self.root / "app" / app).as_posix(), mode],
            env=self.env, capture_output=True, encoding="utf-8", errors="replace", timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        signature = next(line for line in lines if line.startswith("BUILD_SIGNATURE="))
        entries = [line.split("\t")[0] for line in lines if "\t" in line]
        return signature, entries

    def test_testfw_inputs_change_both_signatures(self):
        self.write_testfw()
        for mode in ("build", "test"):
            with self.subTest(mode=mode):
                _, entries = self.signature("tested", mode)
                self.assertIn("framework/testfw/makefile", entries)
                self.assertIn("framework/testfw/bin_internal/results.py", entries)
                self.assertIn("framework/testfw/libsrc/mock/mock.cc", entries)
                self.assertIn("framework/testfw/include/testfw.h", entries)
                self.assertIn("framework/testfw/gtest/TARGET_GTEST_VERSION", entries)
                self.assertNotIn("framework/testfw/libsrc/mock/obj/mock.o", entries)

        for path in ("framework/testfw/bin_internal/results.py", "framework/testfw/libsrc/mock/mock.cc",
                     "framework/testfw/include/testfw.h", "framework/testfw/gtest/TARGET_GTEST_VERSION"):
            for mode in ("build", "test"):
                with self.subTest(path=path, mode=mode):
                    before, _ = self.signature("tested", mode)
                    with open(self.root / path, "a", encoding="utf-8", newline="\n") as handle:
                        handle.write("// changed\n")
                    after, _ = self.signature("tested", mode)
                    self.assertNotEqual(before, after)

    def test_generated_files_do_not_change_signature(self):
        self.write_testfw()
        before, _ = self.signature("tested", "test")
        self.write("framework/testfw/libsrc/mock/obj/mock.o", "rebuilt\n")
        self.assertEqual(before, self.signature("tested", "test")[0])

    def test_app_without_tests_ignores_testfw(self):
        self.write_testfw()
        before, entries = self.signature("untested", "build")
        self.assertFalse([entry for entry in entries if entry.startswith("framework/testfw/")])
        self.write("framework/testfw/libsrc/mock/mock.cc", "int mock() { return 1; }\n")
        self.assertEqual(before, self.signature("untested", "build")[0])

    def test_signature_without_testfw(self):
        _, entries = self.signature("tested", "test")
        self.assertIn("app/tested/prod/libsrc/tested.c", entries)
        self.assertFalse([entry for entry in entries if entry.startswith("framework/testfw/")])


if __name__ == "__main__":
    unittest.main()
