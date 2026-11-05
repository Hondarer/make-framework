"""Exercise Linux IDENT batching through the actual make rules."""
import json
import pathlib
import subprocess
import tempfile
import unittest


class IdentBatchTest(unittest.TestCase):
    def test_parallel_incremental_and_missing(self):
        home = pathlib.Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(prefix='ident-batch-') as directory:
            root = pathlib.Path(directory)
            (root / 'obj').mkdir()
            for name in ('a', 'b'):
                (root / f'{name}.c').write_text(f'int {name};\n', encoding='utf-8')
            (root / 'makefile').write_text(f'''MAKEFW_HOME := {home}
WORKSPACE_DIR := {root}
PLATFORM_LINUX := 1
NO_LINK := 1
OBJDIR := obj
DEPS := obj/a.d obj/b.d
.DEFAULT_GOAL := result
include {home}/makefiles/_ident.mk
obj/%.o: %.c
\tcc -MMD -c $< -o $@
result: obj/a.ident obj/b.ident
\t@echo linked >> links
''', encoding='utf-8')
            def build():
                subprocess.run(['make', '-j4'], cwd=root, check=True, capture_output=True)
            build()
            outputs = [root / f'obj/{name}.ident' for name in ('a', 'b')]
            initial = [p.stat().st_mtime_ns for p in outputs]
            first_hash = json.loads(outputs[0].read_text(encoding='utf-8'))['source_sha256']
            (root / 'result').touch()
            build()
            self.assertEqual(initial, [p.stat().st_mtime_ns for p in outputs])
            self.assertEqual('linked\n', (root / 'links').read_text(encoding='utf-8'))
            (root / 'a.c').write_text('int a = 42;\n', encoding='utf-8')
            build()
            self.assertNotEqual(first_hash, json.loads(outputs[0].read_text(encoding='utf-8'))['source_sha256'])
            self.assertEqual(initial[1], outputs[1].stat().st_mtime_ns)
            outputs[1].unlink()
            build()
            self.assertTrue(outputs[1].is_file())


if __name__ == '__main__':
    unittest.main()
