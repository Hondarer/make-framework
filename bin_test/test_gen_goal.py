"""生成だけの _gen と、生成器のビルドが必要な app の解決を確認する。

中間ディレクトリは最小の makefile から実物の makemain.mk を読み込む。
SUBDIRS への伝播、明示した順序の維持、空の末端を対象とし、
prepare.mk の環境設定と C/C++ テンプレートの自動選択は対象に含めない。
"""

import os
from pathlib import Path
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


class GenGoalTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="makefw gen goal ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith("MAKEFW_")
            and key not in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL", "WORKSPACE_DIR")
        }

    def require_tools(self, *tools):
        for tool in tools:
            self.assertIsNotNone(shutil.which(tool), f"必要なツールがありません: {tool}")

    def write(self, relative, content):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8", newline="\n")
        return path

    def run_command(self, args, directory="."):
        result = subprocess.run(
            args, cwd=self.root / directory, env=self.env,
            capture_output=True, encoding="utf-8", timeout=120,
        )
        self.assertEqual(result.returncode, 0, f"{args}\n{result.stdout}\n{result.stderr}")
        return result.stdout

    def make(self, directory, *goals):
        return self.run_command(
            ["make", "--no-print-directory", "SHELL=bash", *goals], directory,
        )

    def copy_fragment(self, name, directory="."):
        destination = self.root / directory / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(MAKEFW / "makefiles" / name, destination)

    def generation_makefile(self):
        platform = "WINDOWS" if sys.platform == "win32" else "LINUX"
        return (
            "SHELL := /bin/bash\n"
            f"PLATFORM_{platform} := 1\n"
            "GENDIR := gen\nOBJDIR := obj\nOUTPUT_DIR := output\n"
            "$(GENDIR) $(OBJDIR):\n\t@mkdir -p $@\n"
        )

    def assert_no_objects(self, directory="."):
        objects = [
            path for path in (self.root / directory / "obj").rglob("*")
            if path.suffix in (".o", ".obj")
        ]
        self.assertEqual(objects, [])

    def test_flex_bison_generation(self):
        bison = os.environ.get("BISON", "bison")
        flex = os.environ.get("FLEX", "flex")
        self.require_tools("make", BASH, bison, flex)
        self.write("parser.y", "%%\ninput: /* 空 */ ;\n%%\n")
        self.write("lexer.l", "%%\n. ;\n\\n ;\n%%\n")
        self.copy_fragment("_flex_bison_compile.mk")
        self.write(
            "makefile", self.generation_makefile()
            + f"BISON := {bison}\nFLEX := {flex}\n"
            + "SRCS_Y := parser.y\nSRCS_L := lexer.l\n"
            + "include _flex_bison_compile.mk\n",
        )
        self.make(".", "_gen")
        for name in ("parser.tab.c", "parser.tab.h", "lexer.lex.c"):
            self.assertTrue((self.root / "gen" / name).is_file(), name)
        self.assert_no_objects()

    @unittest.skipUnless(sys.platform == "win32", "[Windows] mc.exe と rc.exe の生成とコンパイルを確認する")
    def test_message_generation_and_resource_compilation(self):
        powershell = os.environ.get("MAKEFW_POWERSHELL", "powershell")
        self.require_tools("make", BASH, "mc.exe", "rc.exe", powershell)
        self.write(
            "messages.mc",
            "MessageIdTypedef=DWORD\nLanguageNames=(English=0x409:MSG00409)\n"
            "MessageId=1\nSymbolicName=MSG_HELLO\nLanguage=English\nHello.\n.\n",
        )
        self.copy_fragment("_resource_compile.mk")
        # prepare.mk と同じコマンド構成で、出力フィルターを指定する。
        filter_script = (MAKEFW / "bin_internal/msvc_output_filter.ps1").as_posix()
        self.write(
            "makefile", self.generation_makefile()
            + "SRCS_MC := messages.mc\nSRCS_RC :=\n"
            + f"MAKEFW_POWERSHELL := {powershell}\n"
            + "MAKEFW_POWERSHELL_COMMAND := $(MAKEFW_POWERSHELL) -NoProfile -ExecutionPolicy Bypass\n"
            + f"MSVC_OUTPUT_FILTER_SCRIPT := {filter_script}\n"
            + "include _resource_compile.mk\n",
        )
        self.make(".", "_gen")
        for name in ("messages.rc", "messages.h"):
            self.assertTrue((self.root / "gen" / name).is_file(), name)
        resource = self.root / "obj/messages.res"
        self.assertFalse(resource.exists())
        self.assert_no_objects()
        self.make(".", "obj/messages.res")
        self.assertTrue(resource.is_file())
        for warning in self.root.rglob("*.warn"):
            self.assertEqual(warning.read_text(encoding="utf-8"), "", str(warning))

    def test_intermediate_directory_propagation(self):
        self.require_tools("make", BASH)
        self.copy_fragment("makemain.mk")
        self.write(
            "makefile", "SHELL := /bin/bash\nMAKEFW_BUILD := 0\n"
            "SUBDIRS := first middle empty\ninclude makemain.mk\n",
        )
        self.write(
            "first/makefile",
            ".PHONY: _gen\n_gen: gen/first.c\ngen/first.c:\n"
            "\t@mkdir -p gen\n\t@printf 'first\\n' > $@\n",
        )
        self.copy_fragment("makemain.mk", "middle")
        self.write(
            "middle/makefile",
            "SHELL := /bin/bash\nMAKEFW_BUILD := 0\ninclude makemain.mk\n",
        )
        self.write(
            "middle/leaf/makefile",
            ".PHONY: _gen\n_gen: gen/leaf.c\ngen/leaf.c:\n"
            "\t@test -f ../../first/gen/first.c\n"
            "\t@mkdir -p gen\n\t@printf 'leaf\\n' > $@\n",
        )
        self.copy_fragment("makemain.mk", "empty")
        self.write("empty/makefile", "MAKEFW_BUILD := 0\ninclude makemain.mk\n")
        self.make(".", "-j4", "_gen")
        for name in ("first/gen/first.c", "middle/leaf/gen/leaf.c"):
            self.assertTrue((self.root / name).is_file(), name)

    def test_gen_build_app_resolution(self):
        self.require_tools(BASH)
        self.write(".workspaceRoot", "")
        resolver = self.root / "framework/makefw/bin_internal/resolve_app_deps.sh"
        resolver.parent.mkdir(parents=True)
        shutil.copyfile(MAKEFW / "bin_internal/resolve_app_deps.sh", resolver)
        declarations = {
            "z-generator": "APP_DEPS := middle alpha\nAPP_GEN_REQUIRES_BUILD := 1 # 有効\n",
            "middle": "APP_DEPS := alpha\n",
            "alpha": "APP_DEPS :=\n",
            "a-generator": "APP_DEPS := middle\nAPP_GEN_REQUIRES_BUILD := 1\n",
            "disabled": "APP_GEN_REQUIRES_BUILD := 0\n",
            "commented": "# APP_GEN_REQUIRES_BUILD := 1\n",
            "unrelated": "APP_DEPS :=\n",
        }
        for name, content in declarations.items():
            self.write(f"app/{name}/appdeps.mk", content)
        command = [BASH, str(resolver), "--gen-build-apps"]
        self.assertEqual(
            self.run_command(command), "a-generator\nalpha\nmiddle\nz-generator\n",
        )
        # 有効な宣言を除き、未宣言、0、コメントだけなら出力しない。
        for name in ("z-generator", "a-generator"):
            self.write(f"app/{name}/appdeps.mk", "APP_DEPS := middle alpha\n")
        self.assertEqual(self.run_command(command), "")


if __name__ == "__main__":
    unittest.main()
