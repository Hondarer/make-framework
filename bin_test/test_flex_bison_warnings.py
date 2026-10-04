"""外部生成コードの警告抑制が自作の生成コードへ広がらないことを確認する。"""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform.startswith("linux"), "[Linux] GCC の警告抑制を検証する")
class FlexBisonWarningsTest(unittest.TestCase):
    def test_switch_enum_suppression_is_limited_to_external_generated_sources(self):
        for tool in ("make", "gcc"):
            self.assertIsNotNone(shutil.which(tool), f"必要なツールがありません: {tool}")

        with tempfile.TemporaryDirectory(prefix="flex bison warnings ") as temporary:
            root = Path(temporary)
            (root / "gen").mkdir()
            (root / "obj").mkdir()
            source = (
                "enum kind { FIRST, SECOND };\n"
                "int inspect(enum kind value) {\n"
                "  switch (value) { case FIRST: return 1; default: return 0; }\n"
                "}\n"
            )
            for name in ("parser.tab.c", "lexer.lex.c", "custom.c"):
                (root / "gen" / name).write_text(source, encoding="utf-8")
            (root / "makefile").write_text(
                "PLATFORM_LINUX := 1\n"
                "CC := gcc\n"
                "CFLAGS := -Werror=switch-enum\n"
                "GENDIR := gen\n"
                "OBJDIR := obj\n"
                "GENDIR_EXTRA_C := gen/custom.c\n"
                f"include {ROOT}/makefiles/_flex_bison_compile.mk\n"
                "GEN_TAB_C := gen/parser.tab.c\n"
                "GEN_LEX_C := gen/lexer.lex.c\n",
                encoding="utf-8",
            )
            for name, succeeds in (
                ("parser.tab", True), ("lexer.lex", True), ("custom", False)
            ):
                with self.subTest(source=name):
                    result = subprocess.run(
                        ["make", f"obj/{name}.o"], cwd=root,
                        capture_output=True, text=True,
                    )
                    output = result.stdout + result.stderr
                    if succeeds:
                        self.assertEqual(result.returncode, 0, output)
                        self.assertTrue((root / "obj" / f"{name}.o").is_file())
                    else:
                        self.assertNotEqual(result.returncode, 0, output)
                        self.assertIn("switch-enum", output)


if __name__ == "__main__":
    unittest.main()
