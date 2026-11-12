"""階層を持つテスト群の並行実行、共通スロット上限、失敗伝播を確認する。"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")
RUNNER = Path(__file__).resolve().parents[1] / "bin_internal/run_ordered_subdir_target.sh"
BASH = shutil.which("bash") or "bash"


class NestedParallelTest(unittest.TestCase):
    def run_groups(self, leaves=1, barrier=True, failure=False, failing_date=False):
        with tempfile.TemporaryDirectory(prefix="nested parallel ") as temporary:
            root = Path(temporary)
            worker = root / "worker.py"
            worker.write_text('''import json, pathlib, sys, time
root, name, barrier, fail = sys.argv[1:]
root = pathlib.Path(root)
start = time.monotonic()
(root / (name + ".start")).write_text(str(start), encoding="utf-8")
if barrier == "1":
    deadline = start + 45
    while len(list(root.glob("*.start"))) < 2:
        if time.monotonic() > deadline:
            raise RuntimeError("independent groups did not overlap")
        time.sleep(0.05)
time.sleep(1)
(root / (name + ".json")).write_text(json.dumps([start, time.monotonic()]), encoding="utf-8")
sys.exit(7 if fail == "1" else 0)
''', encoding="utf-8")
            for group in ("one", "two"):
                directory = root / group
                directory.mkdir()
                children = []
                for index in range(leaves):
                    name = f"{group}_{index}"
                    child = directory / name
                    child.mkdir()
                    children.append(name)
                    command = (
                        f'"{Path(sys.executable).as_posix()}" "{worker.as_posix()}" '
                        f'"{root.as_posix()}" {name} {int(barrier)} '
                        f'{int(failure and group == "one" and index == 0)}'
                    )
                    (child / "makefile").write_text(
                        "SHELL := /bin/bash\n.PHONY: _makefw_is_test_leaf _test_run\n"
                        "_makefw_is_test_leaf:\n\t@echo 1\n_test_run:\n\t@" + command + "\n",
                        encoding="utf-8",
                    )
                (directory / "makefile").write_text(
                    "SHELL := /bin/bash\n.PHONY: _makefw_is_test_leaf _test_run\n"
                    "_makefw_is_test_leaf:\n\t@echo 0\n_test_run:\n"
                    f'\t@bash "{RUNNER.as_posix()}" 2 _test_run ' + " ".join(children) + "\n",
                    encoding="utf-8",
                )
            env = dict(os.environ, MAKEFW_TEST_RUN_JOBS="2")
            for key in ("MAKEFLAGS", "MFLAGS", "MAKEFW_TEST_SLOT_DIR", "MAKEFW_FORCE_LEAF"):
                env.pop(key, None)
            if failing_date:
                # 時刻を出力したうえで 0 以外の終了コードを返す date に差し替える。
                fake_bin = root / "fake bin"
                fake_bin.mkdir()
                fake_date = fake_bin / "date"
                fake_date.write_text("#!/bin/bash\nprintf '1700000000\\n'\nexit 1\n", encoding="utf-8", newline="\n")
                fake_date.chmod(0o755)
                env["PATH"] = str(fake_bin) + os.pathsep + env.get("PATH", "")
            result = subprocess.run(
                [BASH, str(RUNNER), "2", "_test_run", "one", "two"], cwd=root, env=env,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                encoding="utf-8", errors="replace", timeout=240,
            )
            intervals = [json.loads(path.read_text(encoding="utf-8")) for path in root.glob("*.json")]
            return result, intervals

    def test_independent_groups_overlap(self):
        result, intervals = self.run_groups()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len(intervals), 2)
        self.assertLess(max(start for start, _ in intervals), min(end for _, end in intervals))

    def test_nested_groups_share_leaf_budget(self):
        result, intervals = self.run_groups(leaves=2, barrier=False)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len(intervals), 4)
        events = sorted([(start, 1) for start, _ in intervals] + [(end, -1) for _, end in intervals])
        active = peak = 0
        for _, change in events:
            active += change
            peak = max(peak, active)
        self.assertLessEqual(peak, 2)

    def test_failure_propagates_after_other_group_finishes(self):
        result, intervals = self.run_groups(failure=True)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len(intervals), 2)

    def test_failing_date_does_not_break_wait_loop(self):
        result, intervals = self.run_groups(failing_date=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("syntax error", result.stdout)
        self.assertEqual(len(intervals), 2)


if __name__ == "__main__":
    unittest.main()
