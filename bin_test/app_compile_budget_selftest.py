#!/usr/bin/env python3
"""Linux で偽のコンパイラとリンカーを使い、app 間のコンパイル予算の共有を検証する。"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

# Linux 専用の自己完結テスト (run-bin-tests.py が参照する)。
BIN_TEST_PLATFORM = "linux"

MAKEFW = Path(__file__).resolve().parents[1]
APP_NAMES = ("app_base", "app_mid1", "app_mid2", "app_mid3", "app_leaf")
APP_DEPS = {
    "app_base": (),
    "app_mid1": ("app_base",),
    "app_mid2": ("app_base",),
    "app_mid3": ("app_base",),
    "app_leaf": ("app_mid1",),
}
SOURCES_PER_APP = 6


def clean_env(extra=None):
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("MAKEFW_")
        and key not in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL", "JOBS", "JOBS_EFFECTIVE")
    }
    if extra:
        env.update(extra)
    return env


def peak_concurrency(intervals):
    events = []
    for start, end in intervals:
        events.append((start, 1))
        events.append((end, -1))
    events.sort(key=lambda item: (item[0], item[1]))
    active = 0
    peak = 0
    for _, delta in events:
        active += delta
        peak = max(peak, active)
    return peak


def peak_budget(app_records):
    events = []
    for rec in app_records:
        budget = int(rec["budget"]) if rec["budget"] is not None else 0
        events.append((rec["start"], budget))
        events.append((rec["end"], -budget))
    events.sort(key=lambda item: (item[0], item[1]))
    active = 0
    peak = 0
    for _, delta in events:
        active += delta
        peak = max(peak, active)
    return peak


class BudgetSelftestFixture:
    def __init__(self, root):
        self.root = root
        self.makefw_dir = root / "framework" / "makefw"
        shutil.copytree(MAKEFW / "makefiles", self.makefw_dir / "makefiles")
        shutil.copytree(MAKEFW / "bin_internal", self.makefw_dir / "bin_internal")
        (self.root / ".workspaceRoot").touch()
        (self.makefw_dir / ".git").touch()

        # APP_POST_BUILD_CHECKS が呼ぶ補助スクリプトの最小スタブ。
        bin_dir = self.makefw_dir / "bin"
        bin_dir.mkdir(parents=True, exist_ok=True)
        self.write_executable(bin_dir / "sync_c_cpp_properties.sh", "#!/bin/bash\nexit 0\n")
        testfw_bin = self.root / "framework" / "testfw" / "bin_internal"
        testfw_bin.mkdir(parents=True, exist_ok=True)
        self.write_executable(testfw_bin / "banner.sh", "#!/bin/bash\nexit 0\n")

        # 固定値を返す偽の resolve_app_deps.sh に差し替える。
        self.write_executable(
            self.makefw_dir / "bin_internal" / "resolve_app_deps.sh",
            f"""#!/bin/bash
case "$1" in
    --app-order) printf '%s\\n' "{' '.join(APP_NAMES)}" ;;
    --assured) printf '0\\n' ;;
    --signature) printf 'CLEAN=1\\nSIGNATURE_MODE=%s\\n' "$3" ;;
    --paths-all) printf 'INCLUDE:%s/prod/include\\n' "$2" ;;
    --coverity-apps) ;;
    --gen-build-apps) ;;
    *) exit 8 ;;
esac
""",
        )

        # app/makefile と各 app の構築。
        app_root = self.root / "app"
        app_root.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(self.makefw_dir / "makefiles" / "__app_template.mk", app_root / "makefile")

        for name in APP_NAMES:
            app_dir = app_root / name
            lib_dir = app_dir / "prod" / "libsrc" / name
            lib_dir.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(self.makefw_dir / "makefiles" / "__each_app_template.mk", app_dir / "makefile")
            shutil.copyfile(self.makefw_dir / "makefiles" / "__template.mk", app_dir / "prod" / "makefile")
            shutil.copyfile(self.makefw_dir / "makefiles" / "__template.mk", app_dir / "prod" / "libsrc" / "makefile")
            shutil.copyfile(self.makefw_dir / "makefiles" / "__template.mk", lib_dir / "makefile")
            (lib_dir / "makepart.mk").write_text("LIB_TYPE := static\n", encoding="utf-8", newline="\n")
            if APP_DEPS[name]:
                (app_dir / "appdeps.mk").write_text(
                    "APP_DEPS := " + " ".join(APP_DEPS[name]) + "\n",
                    encoding="utf-8",
                    newline="\n",
                )
            for idx in range(SOURCES_PER_APP):
                (lib_dir / f"src_{idx}.c").write_text(
                    f"int {name}_{idx}(void) {{ return {idx}; }}\n",
                    encoding="utf-8",
                    newline="\n",
                )

        # 偽ツールと subdir make ラッパー。
        self.tools_dir = self.root / "tools"
        self.tools_dir.mkdir(parents=True, exist_ok=True)
        self.tool_script = self.tools_dir / "fake_tool.py"
        self.tool_script.write_text(
            """#!/usr/bin/env python3
import json, os, pathlib, sys, time, uuid

kind = sys.argv[1]
args = sys.argv[2:]
log_dir = pathlib.Path(os.environ["FAKE_TOOL_LOG_DIR"])
log_dir.mkdir(parents=True, exist_ok=True)

if "-dumpversion" in args or "--version" in args:
    print("12.0.0")
    sys.exit(0)

out_path = None
dep_path = None
i = 0
while i < len(args):
    if args[i] == "-o" and i + 1 < len(args):
        out_path = args[i + 1]
        i += 2
    elif args[i] == "-MF" and i + 1 < len(args):
        dep_path = args[i + 1]
        i += 2
    else:
        i += 1

if kind == "ar" and out_path is None and len(args) >= 2:
    out_path = args[1]

app_name = os.path.basename(os.environ.get("MYAPP_DIR", "")) or "unknown"
start = time.monotonic()
time.sleep(0.3)
end = time.monotonic()

if dep_path:
    p = pathlib.Path(dep_path)
    p.parent.mkdir(parents=True, exist_ok=True)
    target = out_path or ""
    p.write_text(f"{target}:\\n", encoding="utf-8")
if out_path:
    p = pathlib.Path(out_path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(b"fake")

rec = {
    "kind": kind,
    "app": app_name,
    "start": start,
    "end": end,
    "budget": os.environ.get("MAKEFW_APP_COMPILE_BUDGET"),
}
(log_dir / f"{uuid.uuid4().hex}.json").write_text(json.dumps(rec), encoding="utf-8")
""",
            encoding="utf-8",
            newline="\n",
        )
        self.tool_script.chmod(0o755)

        self.wrappers = {}
        for kind in ("cc", "cxx", "ld", "ar"):
            wrapper = self.tools_dir / f"fake_{kind}.sh"
            self.write_executable(
                wrapper,
                f'#!/bin/bash\nexec "{Path(sys.executable).as_posix()}" "{self.tool_script.as_posix()}" {kind} "$@"\n',
            )
            self.wrappers[kind] = wrapper

        self.subdir_make_wrapper = self.tools_dir / "subdir_make_wrapper.sh"
        self.write_executable(
            self.subdir_make_wrapper,
            f"""#!/bin/bash
exec "{Path(sys.executable).as_posix()}" - "$@" <<'PY'
import json, os, pathlib, subprocess, sys, time, uuid

args = sys.argv[1:]
log_dir = pathlib.Path(os.environ["FAKE_MAKE_LOG_DIR"])
log_dir.mkdir(parents=True, exist_ok=True)
target_dir = ""
for i, arg in enumerate(args):
    if arg == "-C" and i + 1 < len(args):
        target_dir = args[i + 1]
        break
start = time.monotonic()
proc = subprocess.run(["make", *args])
end = time.monotonic()
rec = {{
    "app": pathlib.Path(target_dir).name,
    "start": start,
    "end": end,
    "budget": os.environ.get("MAKEFW_APP_COMPILE_BUDGET"),
}}
(log_dir / f"{{uuid.uuid4().hex}}.json").write_text(json.dumps(rec), encoding="utf-8")
sys.exit(proc.returncode)
PY
""",
        )

    @staticmethod
    def write_executable(path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8", newline="\n")
        path.chmod(0o755)

    def run_build(self, label, extra_make_args=(), extra_env=None):
        # 毎回クリーン状態から実行するため、各 app の obj/lib/stamp を消す。
        for name in APP_NAMES:
            app_dir = self.root / "app" / name
            for rel in ("make_build.stamp", "prod/libsrc/" + name + "/obj", "prod/libsrc/" + name + "/lib"):
                target = app_dir / rel
                if target.is_dir():
                    shutil.rmtree(target)
                elif target.is_file():
                    target.unlink()

        tool_log = self.root / f"logs_tool_{label}"
        make_log = self.root / f"logs_make_{label}"
        for d in (tool_log, make_log):
            if d.exists():
                shutil.rmtree(d)
            d.mkdir(parents=True)

        env = clean_env(
            {
                "MAKEFW_HOME": self.makefw_dir.as_posix(),
                "WORKSPACE_DIR": self.root.as_posix(),
                "MAKEFW_GCC_PCH": "0",
                "CC": self.wrappers["cc"].as_posix(),
                "CXX": self.wrappers["cxx"].as_posix(),
                "LD": self.wrappers["ld"].as_posix(),
                "AR": self.wrappers["ar"].as_posix(),
                "FAKE_TOOL_LOG_DIR": tool_log.as_posix(),
                "FAKE_MAKE_LOG_DIR": make_log.as_posix(),
            }
        )
        if extra_env:
            env.update(extra_env)

        cmd = [
            "make",
            "--no-print-directory",
            f"MAKEFW_SUBDIR_MAKE_CMD={self.subdir_make_wrapper.as_posix()}",
            *extra_make_args,
        ]
        res = subprocess.run(
            cmd,
            cwd=self.root / "app",
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            encoding="utf-8",
            errors="replace",
            timeout=240,
        )
        assert res.returncode == 0, f"{label} 失敗:\n{res.stdout}"
        tool_recs = [
            json.loads(p.read_text(encoding="utf-8"))
            for p in sorted(tool_log.glob("*.json"))
        ]
        make_recs = [
            json.loads(p.read_text(encoding="utf-8"))
            for p in sorted(make_log.glob("*.json"))
        ]
        return tool_recs, make_recs


def main():
    with tempfile.TemporaryDirectory(prefix="makefw_budget_selftest_") as temporary:
        fixture = BudgetSelftestFixture(Path(temporary))

        # 1. 既定の設定 (MAKEFW_CPU_BUDGET=8, B=4)
        tools, makes = fixture.run_build("default_b4", extra_env={"MAKEFW_CPU_BUDGET": "8"})
        assert len(makes) == len(APP_NAMES), makes
        assert len(tools) >= len(APP_NAMES) * SOURCES_PER_APP, len(tools)
        max_budget = peak_budget(makes)
        max_tools = peak_concurrency([(r["start"], r["end"]) for r in tools])
        assert max_budget <= 4, f"渡した予算合計の最大が 4 を超えました: {max_budget}"
        assert max_tools <= 4, f"偽ツールの同時数が 4 を超えました: {max_tools}"

        by_app_budget = {r["app"]: int(r["budget"]) for r in makes}
        for app_name in APP_NAMES:
            app_tools = [(r["start"], r["end"]) for r in tools if r["app"] == app_name]
            app_peak = peak_concurrency(app_tools)
            assert app_peak <= by_app_budget[app_name], (
                f"{app_name}: ツール同時数 {app_peak} > 予算 {by_app_budget[app_name]}"
            )

        # 単独区間の app_base は予算 4 のすべてを受け、同時ツール数も 4 になる。
        assert by_app_budget["app_base"] == 4, by_app_budget
        base_peak = peak_concurrency(
            [(r["start"], r["end"]) for r in tools if r["app"] == "app_base"]
        )
        assert base_peak == 4, f"app_base の同時ツール数が 4 ではありません: {base_peak}"
        print("PASS: 既定設定 (B=4) で全体予算・同時ツール数が 4 以下、単独 app_base は 4")

        # 2. 明示の並列指定 (-j4) では割り振りを行わず、同時ツール数が 4 を超える。
        tools_j4, makes_j4 = fixture.run_build(
            "explicit_j4", extra_make_args=["-j4"], extra_env={"MAKEFW_CPU_BUDGET": "8"}
        )
        assert all(r["budget"] is None for r in makes_j4), makes_j4
        assert all(r["budget"] is None for r in tools_j4), tools_j4
        max_tools_j4 = peak_concurrency([(r["start"], r["end"]) for r in tools_j4])
        assert max_tools_j4 > 4, f"比較用の -j4 で同時ツール数が 4 を超えませんでした: {max_tools_j4}"
        print(f"PASS: 明示指定 -j4 では割り振りせず同時ツール数が {max_tools_j4} (> 4)")

        # 3. MAKEFW_APP_BUILD_JOBS=1 では 1 つずつ動き、各 app が予算 4 を受ける。
        tools_seq, makes_seq = fixture.run_build(
            "app_jobs_1", extra_env={"MAKEFW_CPU_BUDGET": "8", "MAKEFW_APP_BUILD_JOBS": "1"}
        )
        assert peak_concurrency([(r["start"], r["end"]) for r in makes_seq]) == 1, makes_seq
        assert all(int(r["budget"]) == 4 for r in makes_seq), makes_seq
        assert peak_concurrency([(r["start"], r["end"]) for r in tools_seq]) <= 4
        print("PASS: MAKEFW_APP_BUILD_JOBS=1 で app が直列実行され、全 app が予算 4")

        # 4. MAKEFW_CPU_BUDGET=16 (B=8) では 8 以下。
        tools_b8, makes_b8 = fixture.run_build("default_b8", extra_env={"MAKEFW_CPU_BUDGET": "16"})
        max_budget_b8 = peak_budget(makes_b8)
        max_tools_b8 = peak_concurrency([(r["start"], r["end"]) for r in tools_b8])
        assert max_budget_b8 <= 8, f"B=8 で渡した予算合計の最大が 8 を超えました: {max_budget_b8}"
        assert max_tools_b8 <= 8, f"B=8 で偽ツールの同時数が 8 を超えました: {max_tools_b8}"
        print("PASS: MAKEFW_CPU_BUDGET=16 (B=8) で全体予算・同時ツール数が 8 以下")

    print("app 間のコンパイル予算共有の自己検証に成功しました。")


if __name__ == "__main__":
    main()
