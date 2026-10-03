#!/usr/bin/env python3
"""空白を含む一時ワークスペースで make の読み込みと増分ビルドを確認する。"""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

# Windows の subprocess は System32 を PATH より先に探すため、名前だけで起動すると
# WSL の bash.exe を選ぶことがある。PATH 上の bash (Git Bash など) を明示して使う。
# see: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw
BASH = shutil.which("bash") or "bash"

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

MAKEFW = Path(__file__).resolve().parents[1]


class PathSpacesTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="makefw space ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "workspace space"
        self.home = self.root / "framework/makefw"
        for directory in ("makefiles", "bin_internal"):
            shutil.copytree(MAKEFW / directory, self.home / directory)
        self.write(".workspaceRoot", "")
        (self.root / "framework/testfw").mkdir()
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith("MAKEFW_")
            and key not in ("WORKSPACE_DIR", "MYAPP_DIR", "APP_DIR", "MAKEFLAGS", "MFLAGS")
        }
        self.env["MAKEFW_HOME"] = self.home.as_posix()
        self.env["TESTFW_HOME"] = (self.root / "framework/testfw").as_posix()

    def write(self, path, content):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        with open(target, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)
        return target

    def template(self, directory):
        self.write(
            directory + "/makefile",
            (self.home / "makefiles/__template.mk").read_text(encoding="utf-8"),
        )

    def make(self, directory, *args):
        result = subprocess.run(
            ["make", "--no-print-directory", "-C", str(self.root / directory), *args],
            env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            encoding="utf-8", errors="replace", timeout=120,
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        return result.stdout

    def test_config_order_and_recursive_cache(self):
        self.write("makepart.mk", "TRACE += root-part\n")
        self.write("makechild.mk", "TRACE += root-child\n")
        self.template("framework/fixture")
        self.template("framework/fixture/child")
        self.write("framework/fixture/makepart.mk", "TRACE += parent-part\n")
        self.write("framework/fixture/makechild.mk", "TRACE += parent-child\n")
        self.write("framework/fixture/child/makepart.mk", "TRACE += child-part\n")
        self.write("framework/fixture/child/makechild.mk", "TRACE += forbidden-child\n")
        self.write("framework/fixture/makelocal.mk", """TRACE += parent-local
.PHONY: inspect reparse descend
inspect:
	@printf '%s\\n' "$(TRACE)" "$(WORKSPACE_DIR)"
reparse:
	@$(MAKE) inspect
descend:
	@$(MAKE) -C child inspect
""")
        self.write("framework/fixture/child/makelocal.mk", """TRACE += child-local
.PHONY: inspect
inspect:
	@printf '%s\\n' "$(TRACE)" "$(WORKSPACE_DIR)"
""")
        expected_parent = "root-part root-child parent-part parent-local\n"
        expected_child = "root-part root-child parent-part parent-child child-part child-local\n"
        for target in ("inspect", "reparse"):
            self.assertEqual(
                self.make("framework/fixture", target),
                expected_parent + self.root.as_posix() + "\n",
            )
        direct = self.make("framework/fixture/child", "inspect")
        self.assertEqual(direct, expected_child + self.root.as_posix() + "\n")
        self.assertEqual(self.make("framework/fixture", "descend"), direct)

    def test_header_change_recompiles(self):
        leaf = "framework/fixture/prod/libsrc/example"
        self.template(leaf)
        self.write("framework/fixture/prod/makepart.mk", """INCDIR += $(WORKSPACE_DIR)/framework/fixture/prod/include
OUTPUT_DIR := $(WORKSPACE_DIR)/framework/fixture/prod/lib
LIB_TYPE := static
""")
        header = self.write("framework/fixture/prod/include/value.h", "#define VALUE 1\n")
        self.write(leaf + "/example.c", '#include "value.h"\nint example(void) { return VALUE; }\n')
        self.make(leaf, "build", "IDENT=1")
        extension = "obj" if os.name == "nt" else "o"
        objects = list((self.root / leaf / "obj").rglob("example." + extension))
        self.assertEqual(len(objects), 1)
        obj = objects[0]
        initial = obj.stat().st_mtime_ns
        dep = obj.with_suffix(".d").read_text(encoding="utf-8")
        self.assertIn("value.h", dep)
        self.make(leaf, "build", "IDENT=1")
        self.assertEqual(obj.stat().st_mtime_ns, initial)
        header.write_text("#define VALUE 2\n", encoding="utf-8")
        later = max(time.time(), initial / 1_000_000_000) + 2
        os.utime(header, (later, later))
        self.make(leaf, "build", "IDENT=1")
        self.assertGreater(obj.stat().st_mtime_ns, initial)
        for warning in (self.root / "framework/fixture").rglob("*.warn"):
            self.assertEqual(warning.stat().st_size, 0, warning.read_text(errors="replace"))
        self.make(leaf, "clean")
        self.assertFalse(obj.exists())
        self.assertTrue(header.is_file())
        self.assertTrue((self.root / leaf / "example.c").is_file())
        library_dir = self.root / "framework/fixture/prod/lib"
        # IDENT のソース一覧は補助情報として残るため、リンク成果物の削除を確認する。
        self.assertEqual(list(library_dir.glob("*.lib")) + list(library_dir.glob("*.a")), [])

    @unittest.skipUnless(os.name == "nt", "[Windows] MSVC is only available on Windows")
    def test_msvc_absolute_output_and_quoted_include(self):
        source = self.write("compiler fixture/example.c", '#include "value.h"\nint example(void) { return VALUE; }\n')
        header = self.write("include space/value.h", "#define VALUE 7\n")
        output = self.root / "object space"
        result = subprocess.run(
            ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
             str(self.home / "bin_internal/msvc_compile.ps1"),
             "-Compiler", shutil.which("cl"),
             "-Flags", '/nologo /W4 /I"' + header.parent.as_posix() + '"',
             "-ObjDir", str(output), "-Sources", '"' + source.as_posix() + '"',
             "-WorkspaceDir", str(self.root)],
            cwd=source.parent, env=self.env, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, encoding="utf-8", errors="replace", timeout=120,
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertTrue((output / "example.obj").is_file(), result.stdout)
        self.assertIn('/I"' + header.parent.as_posix() + '"', result.stdout)
        dep = (output / "example.d").read_text(encoding="utf-8")
        self.assertIn((output / "example.obj").as_posix().replace(" ", "\\ ") + ":", dep)
        self.assertIn(source.as_posix().replace(" ", "\\ "), dep)
        self.assertIn(header.as_posix().replace(" ", "\\ ").lower(), dep.lower())
        self.assertEqual(list(output.glob("*.rsp")), [])
        for warning in self.root.rglob("*.warn"):
            self.assertEqual(warning.stat().st_size, 0, warning.read_text(errors="replace"))

    @unittest.skipIf(os.name == "nt", "[Linux] ELF version scripts are only used on Linux")
    def test_shared_library_version_script_with_spaces(self):
        leaf = "framework/fixture/prod/libsrc/example"
        self.template(leaf)
        self.write("framework/fixture/prod/makepart.mk", """LIB_TYPE := shared
OUTPUT_DIR := $(WORKSPACE_DIR)/framework/fixture/prod/lib
""")
        self.write(leaf + "/makepart.mk", 'LDFLAGS += -Wl,--version-script="$(CURDIR)/exports.map"\n')
        self.write(leaf + "/exports.map", "EXAMPLE_1 { global: example; local: *; };\n")
        self.write(leaf + "/example.c", '__attribute__((visibility("default"))) int example(void) { return 7; }\n')
        self.make(leaf, "build")
        libraries = list((self.root / "framework/fixture/prod/lib").glob("*.so"))
        self.assertEqual(len(libraries), 1)
        symbols = subprocess.check_output(["readelf", "--dyn-syms", "--wide", str(libraries[0])], encoding="utf-8")
        self.assertIn("example@@EXAMPLE_1", symbols)
        for warning in self.root.rglob("*.warn"):
            self.assertEqual(warning.stat().st_size, 0, warning.read_text(errors="replace"))

    def test_app_dependencies_and_source_paths(self):
        leaf = "app/sample/test/src/example"
        self.template(leaf)
        self.write("app/sample/appdeps.mk", "APP_DEPS := $(strip dependency)\n")
        self.write(
            "app/dependency/appdeps.mk", "APP_PROD_INCLUDE_CLASS := $(strip system)\n"
        )
        for path in ("app/sample/prod/include", "app/dependency/prod/include"):
            (self.root / path).mkdir(parents=True)
        self.write("app/sample/prod/libsrc/example.c", "int example(void) { return 1; }\n")
        self.write("app/sample/test/makepart.mk", """TEST_SRCS := $(MYAPP_DIR)/prod/libsrc/example.c
OUTPUT_DIR := $(MYAPP_DIR)/test/cbin
""")
        self.write(leaf + "/makelocal.mk", """MAKEFW_BUILD := 0
.PHONY: inspect
inspect:
	@printf '%s\\n' "$(MYAPP_DIR)" "$(INCDIR)" "$(SYSTEM_INCDIR)" "$(OUTPUT_DIR)" "$(TEST_SRCS)"
""")
        lines = self.make(leaf, "inspect").splitlines()
        self.assertEqual(lines[0], (self.root / "app/sample").as_posix())
        self.assertIn("../../../prod/include", lines[1].split())
        self.assertIn("../../../../dependency/prod/include", lines[2].split())
        self.assertEqual(lines[3], "../../cbin")
        self.assertEqual(lines[4], "../../../prod/libsrc/example.c")

    def test_paths_outside_workspace(self):
        leaf = "app/sample/prod/src/example"
        self.template(leaf)
        self.write("app/sample/appdeps.mk", "APP_DEPS :=\n")
        # ワークスペース外のパスは、同じドライブでも絶対パスのまま残る。
        plain = (Path(self.root.anchor) / "makefw_outside_plain").as_posix()
        spaced = Path(self.temp.name) / "outside dir/include"
        spaced.mkdir(parents=True)
        self.write(leaf + "/makelocal.mk", """MAKEFW_BUILD := 0
.PHONY: inspect
inspect:
	@printf '%s\\n' "$(INCDIR)"
""")
        self.write("app/sample/prod/makepart.mk", "INCDIR += " + plain + "\n")
        self.assertIn(plain, self.make(leaf, "inspect").split())

        # \\ で保護した空白は 1 つのパスとして扱い、Windows では短い名前へ変換する。
        escaped = spaced.as_posix().replace(" ", "\\ ")
        self.write("app/sample/prod/makepart.mk", "INCDIR += " + plain + " " + escaped + "\n")
        result = subprocess.run(
            ["make", "--no-print-directory", "-C", str(self.root / leaf), "inspect"],
            env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            encoding="utf-8", errors="replace", timeout=120,
        )
        short = ""
        if os.name == "nt":
            short = subprocess.run(
                ["cygpath", "-s", "-m", str(spaced)], stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, encoding="utf-8",
            ).stdout.strip()
        if short and " " not in short:
            self.assertEqual(result.returncode, 0, result.stdout)
            items = result.stdout.split()
            self.assertIn(plain, items)
            self.assertIn(short, items)
            # 空白の位置で分割された断片が残っていないことを確かめる。
            # 残りはワークスペース内の既定のパスで、相対パスになる。
            others = [item for item in items if item not in (plain, short)]
            self.assertTrue(all(item.startswith("../") for item in others), others)
        else:
            # 短い名前を得られない場合は、分割された誤ったパスで続行せずに停止する。
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn("INCDIR: path contains spaces", result.stdout)

    def test_environment_sync_preserves_paths(self):
        workspace = MAKEFW.parents[1]
        shutil.copytree(MAKEFW / "bin", self.home / "bin")
        script = "app/general/bin/sync-app-env.sh"
        self.write(script, (workspace / script).read_text(encoding="utf-8"))
        for name in ("c_cpp_properties.json", ".env.linux", ".env.windows", "settings.json", "pub_markdown.config.yaml"):
            self.write(".vscode/" + name, (workspace / ".vscode" / name).read_text(encoding="utf-8"))
        self.write("app/sample/appdeps.mk", "APP_DEPS := dependency\n")
        self.write("app/dependency/appdeps.mk", "APP_DEPS :=\n")
        for name in ("sample", "dependency"):
            (self.root / "app" / name / "prod/include").mkdir(parents=True)
        self.write("app/sample/prod/libsrc/makepart.mk", "OUTPUT_DIR := $(MYAPP_DIR)/prod/lib\n")
        self.write("app/sample/prod/src/makepart.mk", "OUTPUT_DIR := $(MYAPP_DIR)/prod/cbin\n")
        scripts = ("framework/makefw/bin/sync_c_cpp_properties.sh", script)
        for mode in ("--write", "--check"):
            for relative in scripts:
                result = subprocess.run(
                    [BASH, str(self.root / relative), mode], cwd=self.root, env=self.env,
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    encoding="utf-8", errors="replace", timeout=120,
                )
                self.assertEqual(result.returncode, 0, result.stdout)
        properties = (self.root / ".vscode/c_cpp_properties.json").read_text(encoding="utf-8")
        self.assertIn('"${workspaceFolder}/app/dependency/prod/include"', properties)
        for platform in ("linux", "windows"):
            value = (self.root / ".vscode" / (".env." + platform)).read_text(encoding="utf-8")
            slash = "/" if platform == "linux" else "\\"
            self.assertIn(slash.join(("app", "sample", "prod", "cbin")), value)

    def test_makechild_uses_its_own_directory(self):
        parent = "framework/fixture/test/libsrc/mock_example"
        child = parent + "/module"
        self.template(child)
        self.write(parent + "/makechild.mk", """THIS_MAKEFILE_DIR := $(call _makefw_path_dir,$(call _makefw_path_abspath,$(call _makefw_decode_path,$(lastword $(call _makefw_pack_path_roots,$(MAKEFILE_LIST))))))
TARGET := $(call _makefw_path_notdir,$(patsubst %/,%,$(THIS_MAKEFILE_DIR)))
""")
        self.write(child + "/makelocal.mk", """.PHONY: inspect
inspect:
	@printf '%s\\n' "$(TARGET)" "$(THIS_MAKEFILE_DIR)"
""")
        output = self.make(child, "inspect").splitlines()
        self.assertEqual(output, ["mock_example", (self.root / parent).as_posix() + "/"])


if __name__ == "__main__":
    unittest.main()
