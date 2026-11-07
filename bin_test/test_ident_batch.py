"""Exercise IDENT batching through the actual make rules."""
import json
import os
import shlex
import sys
import pathlib
import subprocess
import tempfile
import unittest


class IdentBatchTest(unittest.TestCase):
    def test_linux(self):
        self.check_platform("LINUX", "o")

    def test_windows_rules(self):
        self.check_platform("WINDOWS", "obj")

    @staticmethod
    def rewrite_source(path, text):
        # Windows のタイムスタンプ分解能では、直前の生成物と同時刻になり再生成が省かれることがある。
        # 更新時刻を明示的に進めて、内容変更の検知だけを検証する。
        path.write_text(text, encoding='utf-8')
        stat = path.stat()
        os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns + 5_000_000_000))

    def check_platform(self, platform, extension):
        home = pathlib.Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(prefix='ident-batch-') as directory:
            root = pathlib.Path(directory)
            (root / 'obj').mkdir()
            wrapper = root / 'python3'
            wrapper.write_text(
                '#!/bin/sh\necho called >> python-calls\nexec '
                + shlex.quote(sys.executable) + ' "$@"\n', encoding='utf-8')
            wrapper.chmod(0o755)
            environment = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'])
            for name in ('a', 'b'):
                (root / f'{name}.c').write_text(f'int {name};\n', encoding='utf-8')
            (root / 'makefile').write_text(f'''MAKEFW_HOME := {home}
WORKSPACE_DIR := {root}
PLATFORM_{platform} := 1
NO_LINK := 1
OBJDIR := obj
DEPS := obj/a.d obj/b.d
.DEFAULT_GOAL := result
include {home}/makefiles/_ident.mk
obj/%.{extension}: %.c
\tcc -MMD -c $< -o $@
.PHONY: _msvc_compile
_msvc_compile: obj/a.{extension} obj/b.{extension}
result: obj/a.ident obj/b.ident
\t@echo linked >> links
''', encoding='utf-8')
            def build():
                subprocess.run(['make', '-j4'], cwd=root, check=True, capture_output=True, env=environment)
            build()
            self.assertEqual('called\n', (root / 'python-calls').read_text(encoding='utf-8'))
            outputs = [root / f'obj/{name}.ident' for name in ('a', 'b')]
            initial = [p.stat().st_mtime_ns for p in outputs]
            first_hash = json.loads(outputs[0].read_text(encoding='utf-8'))['source_sha256']
            (root / 'result').touch()
            build()
            self.assertEqual('called\n', (root / 'python-calls').read_text(encoding='utf-8'))
            self.assertEqual(initial, [p.stat().st_mtime_ns for p in outputs])
            self.assertEqual('linked\n', (root / 'links').read_text(encoding='utf-8'))
            self.rewrite_source(root / 'a.c', 'int a = 42;\n')
            build()
            self.assertNotEqual(first_hash, json.loads(outputs[0].read_text(encoding='utf-8'))['source_sha256'])
            self.assertEqual(initial[1], outputs[1].stat().st_mtime_ns)
            outputs[1].unlink()
            build()
            self.assertTrue(outputs[1].is_file())
            links_before_failure = (root / 'links').read_bytes()
            wrapper.write_text('#!/bin/sh\nexit 9\n', encoding='utf-8')
            self.rewrite_source(root / 'a.c', 'int a = 99;\n')
            failed = subprocess.run(['make', '-j4'], cwd=root, env=environment,
                                    capture_output=True)
            self.assertNotEqual(0, failed.returncode)
            self.assertEqual(links_before_failure, (root / 'links').read_bytes())


if __name__ == '__main__':
    unittest.main()
