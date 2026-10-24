#!/usr/bin/env python3
"""省略判定の対象とする makefw の入力の範囲を検証する。"""

from pathlib import Path
import shutil
import subprocess
import unittest

# Windows の subprocess は System32 を PATH より先に探すため、名前だけで起動すると
# WSL の bash.exe を選ぶことがある。PATH 上の bash (Git Bash など) を明示して使う。
# see: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw
BASH = shutil.which("bash") or "bash"

MAKEFW = Path(__file__).resolve().parents[1]


class SignatureInputsTest(unittest.TestCase):
    def test_lists_all_make_files_and_scripts(self):
        result = subprocess.run([BASH, str(MAKEFW / "bin_internal/list_signature_inputs.sh")],
                                capture_output=True, encoding="utf-8", check=True)
        names = [tuple(Path(line).parts[-2:]) for line in result.stdout.splitlines()]
        expected = [("makefiles", path.name) for path in (MAKEFW / "makefiles").iterdir() if path.is_file()]
        expected += [("bin_internal", path.name) for path in (MAKEFW / "bin_internal").iterdir()
                     if path.is_file() and path.suffix in (".sh", ".py", ".ps1")]
        self.assertEqual(sorted(names), sorted(expected))
        self.assertIn(("bin_internal", "list_signature_inputs.sh"), names)
        self.assertIn(("bin_internal", "get_files_lang.sh"), names)


if __name__ == "__main__":
    unittest.main()
