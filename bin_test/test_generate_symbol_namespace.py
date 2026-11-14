import os
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin_internal"))

import generate_symbol_namespace as namespace


class SymbolNamespaceTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.symbols = self.root / "public_symbols.txt"
        self.macros = self.root / "public_api_macros.txt"
        self.output = self.root / "include_internal"
        self.namespace_header = self.output / "demo_app_namespace.h"
        self.undef_header = self.output / "demo_app_undef.h"

    def tearDown(self):
        self.temp.cleanup()

    def write_inputs(self, symbols="demo_open\ndemo_close\n", macros="DEMO_INIT demo_open\nDEMO_VERSION demo_close\n"):
        self.symbols.write_text(symbols, encoding="utf-8")
        self.macros.write_text(macros, encoding="utf-8")

    def test_generates_matching_namespace_and_undef_headers(self):
        self.write_inputs()
        mapping = namespace.generate(self.symbols, self.macros, "demo_app_",
                                     self.namespace_header, self.undef_header)
        self.assertEqual(mapping, {
            "demo_open": "demo_app_demo_open",
            "demo_close": "demo_app_demo_close",
            "DEMO_INIT": "demo_app_DEMO_INIT",
            "DEMO_VERSION": "demo_app_DEMO_VERSION",
        })
        self.assertIn("#define demo_open demo_app_demo_open", self.namespace_header.read_text(encoding="utf-8"))
        self.assertIn("#ifndef GENERATED_DEMO_APP_NAMESPACE_H", self.namespace_header.read_text(encoding="utf-8"))
        self.assertIn("#define DEMO_INIT demo_app_DEMO_INIT", self.namespace_header.read_text(encoding="utf-8"))
        self.assertIn("#define DEMO_VERSION demo_app_DEMO_VERSION", self.namespace_header.read_text(encoding="utf-8"))
        self.assertIn("#undef demo_open", self.undef_header.read_text(encoding="utf-8"))
        self.assertIn("#undef DEMO_INIT", self.undef_header.read_text(encoding="utf-8"))
        self.assertIn("#undef DEMO_VERSION", self.undef_header.read_text(encoding="utf-8"))
        self.assertIn("#undef GENERATED_DEMO_APP_NAMESPACE_H", self.undef_header.read_text(encoding="utf-8"))

    def test_invalid_identifiers_and_duplicates_are_rejected(self):
        for symbols, macros in [
            ("valid_name\nbad-name\n", ""),
            ("valid_name\nvalid_name\n", ""),
            ("valid_name\n", "bad macro valid_name\n"),
            ("valid_name\n", "VALID_MACRO missing_api\n"),
            ("valid_name\nVALID_MACRO\n", "VALID_MACRO valid_name\n"),
            ("foo\ndemo_app_foo\n", ""),
        ]:
            with self.subTest(symbols=symbols, macros=macros):
                self.write_inputs(symbols, macros)
                with self.assertRaises(ValueError):
                    namespace.generate(self.symbols, self.macros, "demo_app_",
                                       self.namespace_header, self.undef_header)

    def test_empty_inputs_and_macro_targets_are_supported(self):
        self.write_inputs("", "")
        mapping = namespace.generate(self.symbols, self.macros, "demo_app_",
                                     self.namespace_header, self.undef_header)
        self.assertEqual(mapping, {})
        self.assertTrue(self.namespace_header.exists())

    def test_self_targeting_macro_without_exported_symbol_is_supported(self):
        self.write_inputs("demo_open\n", "SQLITE_EXTENSION_CALL SQLITE_EXTENSION_CALL\n")
        mapping = namespace.generate(self.symbols, self.macros, "demo_app_",
                                    self.namespace_header, self.undef_header)
        self.assertEqual(mapping["SQLITE_EXTENSION_CALL"], "demo_app_SQLITE_EXTENSION_CALL")

    def test_public_header_lexer_preserves_comments_literals_and_fields(self):
        source = '''
#include <demo_open.h>
/* demo_open("comment") */
const char *name = "demo_open";
const char *character = 'x';
int demo_open(int arg);
#define DEMO_INIT() demo_open(0)
#define DEMO_VERSION demo_close
struct sqlite3_api_routines { int open; };
int call(struct sqlite3_api_routines *api) { return api->open + demo_open(1); }
'''
        mapping = {
            "demo_open": "demo_app_demo_open",
            "demo_close": "demo_app_demo_close",
            "DEMO_INIT": "demo_app_DEMO_INIT",
            "DEMO_VERSION": "demo_app_DEMO_VERSION",
            "open": "demo_app_open",
            "sqlite3_api_routines": "demo_app_sqlite3_api_routines",
        }
        transformed = namespace.transform_public_header(source, mapping)
        self.assertIn("#include <demo_open.h>", transformed)
        self.assertIn('/* demo_open("comment") */', transformed)
        self.assertIn('"demo_open"', transformed)
        self.assertIn("int demo_app_demo_open(int arg);", transformed)
        self.assertIn("#define demo_app_DEMO_INIT() demo_app_demo_open(0)", transformed)
        self.assertIn("#define demo_app_DEMO_VERSION demo_app_demo_close", transformed)
        self.assertIn("struct sqlite3_api_routines { int open; }", transformed)
        self.assertIn("api->open", transformed)

    def test_unchanged_content_preserves_modification_time(self):
        self.write_inputs()
        namespace.generate(self.symbols, self.macros, "demo_app_",
                           self.namespace_header, self.undef_header)
        timestamp = 1_600_000_000_000_000_000
        os.utime(self.namespace_header, ns=(timestamp, timestamp))
        os.utime(self.undef_header, ns=(timestamp, timestamp))
        namespace.generate(self.symbols, self.macros, "demo_app_",
                           self.namespace_header, self.undef_header)
        self.assertEqual(self.namespace_header.stat().st_mtime_ns, timestamp)
        self.assertEqual(self.undef_header.stat().st_mtime_ns, timestamp)

    def test_parallel_generation_never_leaves_partial_headers(self):
        self.write_inputs()
        with ThreadPoolExecutor(max_workers=6) as executor:
            futures = [executor.submit(namespace.generate, self.symbols, self.macros, "demo_app_",
                                       self.namespace_header, self.undef_header) for _ in range(12)]
            for future in futures:
                self.assertEqual(future.result()["demo_open"], "demo_app_demo_open")
        self.assertIn("#define demo_open demo_app_demo_open", self.namespace_header.read_text(encoding="utf-8"))
        self.assertIn("#undef demo_open", self.undef_header.read_text(encoding="utf-8"))

    def test_read_retries_transient_windows_errors(self):
        self.output.mkdir()
        self.namespace_header.write_text("unchanged", encoding="utf-8")
        for winerror in (5, 32):
            with self.subTest(winerror=winerror):
                error = PermissionError("temporarily unavailable")
                error.winerror = winerror
                with patch.object(Path, "read_text", side_effect=[error, "unchanged"]) as read, \
                     patch.object(namespace.time, "sleep") as sleep, \
                     patch.object(namespace.os, "replace") as replace:
                    self.assertFalse(namespace._write_if_changed(self.namespace_header, "unchanged"))
                self.assertEqual(read.call_count, 2)
                sleep.assert_called_once_with(0.01)
                replace.assert_not_called()

    def test_read_retry_then_updates_changed_header(self):
        self.output.mkdir()
        self.namespace_header.write_text("old", encoding="utf-8")
        error = PermissionError("temporarily unavailable")
        error.winerror = 32
        with patch.object(Path, "read_text", side_effect=[error, "old"]), \
             patch.object(namespace.time, "sleep"):
            self.assertTrue(namespace._write_if_changed(self.namespace_header, "new"))
        self.assertEqual(self.namespace_header.read_text(encoding="utf-8"), "new")
        self.assertEqual(list(self.output.iterdir()), [self.namespace_header])

    def test_read_propagates_persistent_or_unrelated_errors(self):
        for winerror, expected_reads in ((5, 5), (32, 5), (3, 1), (None, 1)):
            with self.subTest(winerror=winerror):
                error = PermissionError("cannot read")
                if winerror is not None:
                    error.winerror = winerror
                with patch.object(Path, "read_text", side_effect=error) as read, \
                     patch.object(namespace.time, "sleep") as sleep:
                    with self.assertRaises(PermissionError):
                        namespace._write_if_changed(self.namespace_header, "content")
                self.assertEqual(read.call_count, expected_reads)
                self.assertEqual(sleep.call_count, expected_reads - 1)
                self.assertEqual(list(self.output.iterdir()), [])

    def test_missing_header_is_created(self):
        self.assertTrue(namespace._write_if_changed(self.namespace_header, "content"))
        self.assertEqual(self.namespace_header.read_text(encoding="utf-8"), "content")


if __name__ == "__main__":
    unittest.main()
