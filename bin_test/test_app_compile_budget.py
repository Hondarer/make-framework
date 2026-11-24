"""app 間のコンパイル予算の共有 (run_ordered_subdir_target.sh と _parallel.mk) を確認する。"""

import json
import math
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
RUNNER = MAKEFW / "bin_internal" / "run_ordered_subdir_target.sh"
PARALLEL_MK = MAKEFW / "makefiles" / "_parallel.mk"
# PATH 上の bash を明示し、Windows の System32 にある WSL 用 bash を避ける。
# see: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw
BASH = shutil.which("bash") or "bash"


def clean_makefw_env(extra=None):
    """CI の MAKEFW_CPU_BUDGET などの影響を受けない環境を作る。"""
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("MAKEFW_")
        and key not in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL", "JOBS", "JOBS_EFFECTIVE")
    }
    if extra:
        env.update(extra)
    return env


def peak_usage(records):
    """各実行区間 [start, end] から、同時実行数と予算合計の最大値を返す。"""
    events = []
    for rec in records:
        budget = int(rec["budget"]) if rec["budget"] is not None else 0
        events.append((rec["start"], 1, budget))
        events.append((rec["end"], -1, -budget))
    events.sort(key=lambda item: (item[0], item[1]))
    active_count = 0
    active_budget = 0
    max_count = 0
    max_budget = 0
    for _, count_delta, budget_delta in events:
        active_count += count_delta
        active_budget += budget_delta
        max_count = max(max_count, active_count)
        max_budget = max(max_budget, active_budget)
    return max_count, max_budget


class RunnerBudgetTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="makefw_budget_")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.worker = self.root / "worker.py"
        self.worker.write_text(
            """import json, os, pathlib, sys, time
root, name, duration, fail = sys.argv[1:]
root = pathlib.Path(root)
start = time.monotonic()
(root / f"{name}.started").write_text(str(start), encoding="utf-8")
time.sleep(float(duration))
end = time.monotonic()
record = {
    "name": name,
    "start": start,
    "end": end,
    "budget": os.environ.get("MAKEFW_APP_COMPILE_BUDGET"),
}
(root / f"{name}.json").write_text(json.dumps(record), encoding="utf-8")
sys.exit(int(fail))
""",
            encoding="utf-8",
            newline="\n",
        )

    def create_app(self, name, deps=(), duration=0.35, fail_code=0):
        app_dir = self.root / name
        app_dir.mkdir(parents=True, exist_ok=True)
        if deps:
            (app_dir / "appdeps.mk").write_text(
                "APP_DEPS := " + " ".join(deps) + "\n",
                encoding="utf-8",
                newline="\n",
            )
        cmd = (
            f'"{Path(sys.executable).as_posix()}" "{self.worker.as_posix()}" '
            f'"{self.root.as_posix()}" {name} {duration} {fail_code}'
        )
        (app_dir / "makefile").write_text(
            "SHELL := /bin/bash\n.PHONY: default\ndefault:\n\t@" + cmd + "\n",
            encoding="utf-8",
            newline="\n",
        )

    def run_runner(self, args, extra_env=None, check=True):
        result = subprocess.run(
            [BASH, str(RUNNER), *args],
            cwd=self.root,
            env=clean_makefw_env(extra_env),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            encoding="utf-8",
            errors="replace",
            timeout=120,
        )
        if check:
            self.assertEqual(result.returncode, 0, result.stdout)
        return result

    def read_records(self, names):
        return {
            name: json.loads((self.root / f"{name}.json").read_text(encoding="utf-8"))
            for name in names
        }

    def test_single_app_gets_full_budget(self):
        self.create_app("solo")
        self.run_runner(["--app-deps", "--app-compile-budget", "4", "4", "default", "solo"])
        records = self.read_records(["solo"])
        self.assertEqual(records["solo"]["budget"], "4")
        _, max_budget = peak_usage(records.values())
        self.assertLessEqual(max_budget, 4)

    def test_three_ready_apps_split_budget_4(self):
        names = ["a", "b", "c"]
        for name in names:
            self.create_app(name)
        self.run_runner(["--app-deps", "--app-compile-budget", "4", "4", "default", *names])
        records = self.read_records(names)
        self.assertEqual([records[n]["budget"] for n in names], ["2", "1", "1"])
        _, max_budget = peak_usage(records.values())
        self.assertLessEqual(max_budget, 4)

    def test_three_ready_apps_split_budget_7(self):
        names = ["a", "b", "c"]
        for name in names:
            self.create_app(name)
        self.run_runner(["--app-deps", "--app-compile-budget", "7", "3", "default", *names])
        records = self.read_records(names)
        self.assertEqual([records[n]["budget"] for n in names], ["3", "2", "2"])
        _, max_budget = peak_usage(records.values())
        self.assertLessEqual(max_budget, 7)

    def test_eight_ready_apps_split_budget_36(self):
        names = [f"app{i}" for i in range(8)]
        for name in names:
            self.create_app(name)
        self.run_runner(["--app-deps", "--app-compile-budget", "36", "8", "default", *names])
        records = self.read_records(names)
        self.assertEqual(
            [records[n]["budget"] for n in names],
            ["5", "5", "5", "5", "4", "4", "4", "4"],
        )
        _, max_budget = peak_usage(records.values())
        self.assertLessEqual(max_budget, 36)

    def test_ready_apps_exceed_jobs(self):
        names = [f"p{i}" for i in range(5)]
        # p0 だけ先に終了し、p1..p3 が実行中の間に p4 が戻った予算 1 を受けて起動する。
        for i, name in enumerate(names):
            duration = 0.2 if i == 0 else 2.2
            self.create_app(name, duration=duration)
        self.run_runner(["--app-deps", "--app-compile-budget", "4", "4", "default", *names])
        records = self.read_records(names)
        for name in names[:4]:
            self.assertEqual(records[name]["budget"], "1")
        self.assertEqual(records["p4"]["budget"], "1")
        # 5 つ目は最初の 4 つのいずれかが終了した後に起動する。
        earliest_end = min(records[name]["end"] for name in names[:4])
        self.assertGreaterEqual(records["p4"]["start"], earliest_end)
        max_count, max_budget = peak_usage(records.values())
        self.assertLessEqual(max_count, 4)
        self.assertLessEqual(max_budget, 4)

    def test_ready_apps_exceed_budget(self):
        names = [f"q{i}" for i in range(4)]
        for name in names:
            self.create_app(name, duration=0.4)
        self.run_runner(["--app-deps", "--app-compile-budget", "2", "4", "default", *names])
        records = self.read_records(names)
        for name in names:
            self.assertEqual(records[name]["budget"], "1")
        max_count, max_budget = peak_usage(records.values())
        self.assertLessEqual(max_count, 2)
        self.assertLessEqual(max_budget, 2)

    def test_dependency_chain_and_parallel_mix(self):
        # 鎖 (a -> b -> c) では各 app が 4 を受ける。
        self.create_app("a")
        self.create_app("b", deps=("a",))
        self.create_app("c", deps=("b",))
        self.run_runner(["--app-deps", "--app-compile-budget", "4", "4", "default", "a", "b", "c"])
        chain = self.read_records(["a", "b", "c"])
        self.assertEqual([chain[n]["budget"] for n in ("a", "b", "c")], ["4", "4", "4"])
        self.assertGreaterEqual(chain["b"]["start"], chain["a"]["end"])
        self.assertGreaterEqual(chain["c"]["start"], chain["b"]["end"])
        _, max_budget = peak_usage(chain.values())
        self.assertLessEqual(max_budget, 4)

        # 鎖と並列の混在 (r -> x, r -> y, x -> z) でも依存順と上限 4 を保つ。
        self.create_app("r")
        self.create_app("x", deps=("r",))
        self.create_app("y", deps=("r",))
        self.create_app("z", deps=("x",))
        self.run_runner(
            ["--app-deps", "--app-compile-budget", "4", "4", "default", "r", "x", "y", "z"]
        )
        mixed = self.read_records(["r", "x", "y", "z"])
        self.assertEqual(mixed["r"]["budget"], "4")
        self.assertGreaterEqual(mixed["x"]["start"], mixed["r"]["end"])
        self.assertGreaterEqual(mixed["y"]["start"], mixed["r"]["end"])
        self.assertGreaterEqual(mixed["z"]["start"], mixed["x"]["end"])
        _, max_budget_mixed = peak_usage(mixed.values())
        self.assertLessEqual(max_budget_mixed, 4)

    def test_failed_app_returns_budget(self):
        # make ではなく終了コード 7 を直接返すラッパーで、runner が終了コード 7 を保つことも確認する。
        self.create_app("f0", duration=0.2, fail_code=7)
        self.create_app("f1", duration=2.2, fail_code=0)
        self.create_app("f2", duration=0.2, fail_code=0)
        fake_make = self.root / "fake_make.sh"
        fake_make.write_text(
            f"""#!/bin/bash
dir=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -C) dir="$2"; shift 2 ;;
        *) shift ;;
    esac
done
fail=0
if [ "$dir" = "f0" ]; then fail=7; fi
dur=0.2
if [ "$dir" = "f1" ]; then dur=2.2; fi
exec "{Path(sys.executable).as_posix()}" "{self.worker.as_posix()}" "{self.root.as_posix()}" "$dir" "$dur" "$fail"
""",
            encoding="utf-8",
            newline="\n",
        )
        fake_make.chmod(0o755)
        result = self.run_runner(
            ["--app-deps", "--app-compile-budget", "2", "2", "default", "f0", "f1", "f2"],
            extra_env={"MAKEFW_SUBDIR_MAKE": fake_make.as_posix()},
            check=False,
        )
        self.assertEqual(result.returncode, 7, result.stdout)
        records = self.read_records(["f0", "f1", "f2"])
        self.assertEqual(records["f2"]["budget"], "1")
        _, max_budget = peak_usage(records.values())
        self.assertLessEqual(max_budget, 2)

    def test_sigterm_stops_and_does_not_launch_new_apps(self):
        for i in range(4):
            duration = 30.0 if i < 2 else 0.5
            self.create_app(f"s{i}", duration=duration)
        script = (
            f'bash "{RUNNER.as_posix()}" --app-deps --progress --app-compile-budget 2 2 default s0 s1 s2 s3 &\n'
            'pid=$!\n'
            'deadline=$((SECONDS + 30))\n'
            'while [ ! -f s0.started ] && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.05; done\n'
            'sleep 0.2\n'
            'kill -TERM "$pid"\n'
            'wait "$pid"\n'
            'exit $?\n'
        )
        result = subprocess.run(
            [BASH, "-c", script],
            cwd=self.root,
            env=clean_makefw_env(),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            encoding="utf-8",
            errors="replace",
            timeout=60,
        )
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((self.root / "s2.started").exists(), result.stdout)
        self.assertFalse((self.root / "s3.started").exists(), result.stdout)
        self.assertIn("Interrupt received (TERM)", result.stdout)
        self.assertIn("blocked s2 (interrupt received)", result.stdout)
        self.assertIn("blocked s3 (interrupt received)", result.stdout)

    def test_without_option_preserves_environment(self):
        self.create_app("noopt")
        self.run_runner(["--app-deps", "2", "default", "noopt"])
        self.assertIsNone(self.read_records(["noopt"])["noopt"]["budget"])

        self.create_app("inherited")
        self.run_runner(
            ["--app-deps", "2", "default", "inherited"],
            extra_env={"MAKEFW_APP_COMPILE_BUDGET": "9"},
        )
        self.assertEqual(self.read_records(["inherited"])["inherited"]["budget"], "9")

    def test_invalid_options_exit_2(self):
        self.create_app("inv")
        cases = [
            ["--app-deps", "--app-compile-budget", "0", "2", "default", "inv"],
            ["--app-deps", "--app-compile-budget", "00", "2", "default", "inv"],
            ["--app-deps", "--app-compile-budget", "abc", "2", "default", "inv"],
            ["--app-deps", "--app-compile-budget"],
            ["--app-compile-budget", "4", "2", "default", "inv"],
        ]
        for args in cases:
            result = self.run_runner(args, check=False)
            self.assertEqual(result.returncode, 2, f"args={args}\n{result.stdout}")
            self.assertIn("ERROR:", result.stdout)

    def test_progress_dispatch_and_done_format(self):
        self.create_app("p0")
        self.create_app("p1")
        result = self.run_runner(
            ["--app-deps", "--progress", "--app-compile-budget", "3", "2", "default", "p0", "p1"]
        )
        self.assertRegex(result.stdout, r"(?m)^INFO: dispatch \[1/2\] p0 compile_budget=2$")
        self.assertRegex(result.stdout, r"(?m)^INFO: dispatch \[2/2\] p1 compile_budget=1$")
        self.assertRegex(result.stdout, r"(?m)^INFO: done \[\d/2\] p0 rc=0 elapsed=\d{2}:\d{2}$")
        self.assertRegex(result.stdout, r"(?m)^INFO: done \[\d/2\] p1 rc=0 elapsed=\d{2}:\d{2}$")


class ParallelResolutionTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="makefw_parallel_")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.makefile = self.root / "makefile"
        self.makefile.write_text(
            f"""SHELL := /bin/bash
include {PARALLEL_MK.as_posix()}

.PHONY: inspect inspect-budget
inspect:
	@$(call _MAKEFW_RESOLVE_PARALLEL_SHELL) \\
	$(call _MAKEFW_APP_BUDGET_SHELL) \\
	printf 'jobs=%s\\n' "$$jobs"; \\
	printf 'compile_budget=%s\\n' "$$compile_budget"; \\
	printf 'cl_jobs=%s\\n' "$$cl_jobs"; \\
	printf 'msbuild_jobs=%s\\n' "$$msbuild_jobs"; \\
	printf 'parallel_user_explicit=%s\\n' "$$parallel_user_explicit"; \\
	printf 'app_budget_args=%s\\n' "$$app_budget_args"; \\
	printf 'has_jobs_eff=%s\\n' "$${{JOBS_EFFECTIVE+x}}"; \\
	printf 'has_cl_mp=%s\\n' "$${{MAKEFW_CL_MP_JOBS+x}}"; \\
	printf 'has_msbuild=%s\\n' "$${{MAKEFW_MSBUILD_JOBS+x}}"; \\
	printf 'has_cpu_budget=%s\\n' "$${{MAKEFW_CPU_BUDGET+x}}"
""",
            encoding="utf-8",
            newline="\n",
        )

    def eval_make(self, args=(), extra_env=None, check=True):
        result = subprocess.run(
            ["make", "--no-print-directory", f"SHELL={BASH}", *args],
            cwd=self.root,
            env=clean_makefw_env(extra_env),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            encoding="utf-8",
            errors="replace",
            timeout=30,
        )
        if check:
            self.assertEqual(result.returncode, 0, result.stdout)
        parsed = {}
        for line in result.stdout.splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                parsed[key] = value
        return result, parsed

    def test_app_compile_budget_overrides_compile_budget(self):
        _, linux = self.eval_make(
            args=["OS=Linux"],
            extra_env={"MAKEFW_APP_COMPILE_BUDGET": "3", "MAKEFW_CPU_BUDGET": "8"},
        )
        self.assertEqual(linux["compile_budget"], "3")
        self.assertEqual(linux["jobs"], "3")

        _, windows = self.eval_make(
            args=["OS=Windows_NT"],
            extra_env={"MAKEFW_APP_COMPILE_BUDGET": "3", "MAKEFW_CPU_BUDGET": "8"},
        )
        self.assertEqual(windows["compile_budget"], "3")
        self.assertLessEqual(int(windows["jobs"]) * int(windows["cl_jobs"]), 3)
        self.assertLessEqual(int(windows["jobs"]) * int(windows["msbuild_jobs"]), 3)

    def test_invalid_app_compile_budget_exits_2(self):
        for bad in ("0", "abc"):
            res, _ = self.eval_make(
                args=["OS=Linux"],
                extra_env={"MAKEFW_APP_COMPILE_BUDGET": bad},
                check=False,
            )
            self.assertEqual(res.returncode, 2, res.stdout)
            self.assertIn("MAKEFW_APP_COMPILE_BUDGET must be a positive integer", res.stdout)

    def test_explicit_parallel_options_disable_budget_allocation(self):
        cases = [
            (["OS=Linux", "-j4"], {}),
            (["OS=Linux", "-j"], {}),
            (["OS=Linux", "JOBS=4"], {}),
            (["OS=Linux", "JOBS_EFFECTIVE=4"], {}),
            (["OS=Linux"], {"JOBS_EFFECTIVE": "4"}),
            (["OS=Linux"], {"MAKEFW_CL_MP_JOBS": "2"}),
            (["OS=Linux"], {"MAKEFW_MSBUILD_JOBS": "2"}),
        ]
        for args, env in cases:
            _, parsed = self.eval_make(args=args, extra_env={**env, "MAKEFW_CPU_BUDGET": "8"})
            self.assertEqual(parsed["parallel_user_explicit"], "1", f"args={args}, env={env}")
            self.assertEqual(parsed["app_budget_args"], "", f"args={args}, env={env}")

    def test_default_enables_budget_allocation_and_unsets_inherited_vars(self):
        _, parsed = self.eval_make(
            args=["OS=Linux"],
            extra_env={"MAKEFW_CPU_BUDGET": "8", "MAKEFW_APP_BUILD_JOBS": "2"},
        )
        self.assertEqual(parsed["parallel_user_explicit"], "")
        self.assertEqual(parsed["app_budget_args"], "--app-compile-budget 4")
        self.assertEqual(parsed["has_jobs_eff"], "")
        self.assertEqual(parsed["has_cl_mp"], "")
        self.assertEqual(parsed["has_msbuild"], "")
        self.assertEqual(parsed["has_cpu_budget"], "x")

    def test_property_all_cpus_and_budgets_stay_within_budget(self):
        # _parallel.mk の _MAKEFW_RESOLVE_PARALLEL_SHELL を各 (OS, CPU, b) で実際に make 評価する。
        prop_mk = self.root / "prop.makefile"
        prop_mk.write_text(
            f"""SHELL := /bin/bash
include {PARALLEL_MK.as_posix()}
MAKEFW_ALLOW_JOB_FALLBACK := 1

.PHONY: eval-one
eval-one:
	@$(call _MAKEFW_RESOLVE_PARALLEL_SHELL) \\
	printf '%s %s %s %s %s %s\\n' "$(OS)" "$(MAKEFW_CPU_BUDGET)" "$(MAKEFW_APP_COMPILE_BUDGET)" "$$jobs" "$$cl_jobs" "$$msbuild_jobs"
""",
            encoding="utf-8",
            newline="\n",
        )
        for target_os in ("Linux", "Windows_NT"):
            for cpu in (1, 2, 3, 4, 6, 8, 16, 72):
                max_b = math.ceil(cpu / 2)
                for b in range(1, max_b + 1):
                    res, _ = self.eval_make(
                        args=["-f", str(prop_mk), f"OS={target_os}", "eval-one"],
                        extra_env={
                            "MAKEFW_CPU_BUDGET": str(cpu),
                            "MAKEFW_APP_COMPILE_BUDGET": str(b),
                        },
                    )
                    fields = res.stdout.strip().split()
                    self.assertEqual(len(fields), 6, res.stdout)
                    _, _, _, jobs_s, cl_s, msbuild_s = fields
                    jobs = int(jobs_s)
                    cl_jobs = int(cl_s)
                    msbuild_jobs = int(msbuild_s)
                    self.assertGreaterEqual(jobs, 1, fields)
                    self.assertLessEqual(jobs, b, fields)
                    if target_os == "Linux":
                        self.assertEqual(jobs, min(b, 8), fields)
                    else:
                        self.assertGreaterEqual(cl_jobs, 1, fields)
                        self.assertLessEqual(cl_jobs, 16, fields)
                        self.assertGreaterEqual(msbuild_jobs, 1, fields)
                        self.assertLessEqual(msbuild_jobs, 16, fields)
                        self.assertLessEqual(jobs * cl_jobs, b, fields)
                        self.assertLessEqual(jobs * msbuild_jobs, b, fields)


if __name__ == "__main__":
    unittest.main()
