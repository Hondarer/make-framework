#!/usr/bin/env python3
"""Generate private symbol remapping headers for a third-party C library."""

import argparse
import os
import re
import sys
import tempfile
import time
from pathlib import Path


_IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
_RETRY_ATTEMPTS = 5


def _read_names(path: Path) -> list[str]:
    """Read one identifier per line, allowing blank and comment lines."""
    names = []
    seen = set()
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        name = raw_line.partition("#")[0].strip()
        if not name:
            continue
        if not _IDENTIFIER.fullmatch(name):
            raise ValueError(f"{path}:{line_number}: invalid C identifier: {name!r}")
        if name in seen:
            raise ValueError(f"{path}:{line_number}: duplicate identifier: {name}")
        seen.add(name)
        names.append(name)
    return names


def _read_api_macros(path: Path) -> list[tuple[str, str]]:
    """Read API-call macro mappings as `MACRO_NAME TARGET_API`."""
    result = []
    seen = set()
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.partition("#")[0].strip()
        if not line:
            continue
        fields = line.split()
        if len(fields) != 2 or any(not _IDENTIFIER.fullmatch(field) for field in fields):
            raise ValueError(f"{path}:{line_number}: expected two C identifiers: MACRO_NAME TARGET_API")
        macro, target = fields
        if macro in seen:
            raise ValueError(f"{path}:{line_number}: duplicate API macro: {macro}")
        seen.add(macro)
        result.append((macro, target))
    return result


def load_mapping(symbols_path: Path, macros_path: Path, prefix: str) -> dict[str, str]:
    if not _IDENTIFIER.fullmatch(prefix):
        raise ValueError(f"invalid C identifier prefix: {prefix!r}")
    symbols = _read_names(symbols_path)
    macros = _read_api_macros(macros_path)
    mapping = {name: prefix + name for name in symbols}
    for macro, target in macros:
        if target not in mapping and target != macro:
            raise ValueError(f"API macro {macro} targets unknown public symbol: {target}")
        if macro in mapping and macro != target:
            raise ValueError(f"API macro conflicts with public symbol: {macro}")
        mapping[macro] = prefix + macro
    if len(set(mapping.values())) != len(mapping):
        raise ValueError("namespace prefix creates duplicate output identifiers")
    overlaps = set(mapping).intersection(mapping.values())
    if overlaps:
        raise ValueError(f"namespace output overlaps source identifiers: {', '.join(sorted(overlaps))}")
    return mapping


def transform_public_header(text: str, mapping: dict[str, str]) -> str:
    """Rename C identifier tokens while leaving comments and literals untouched.

    Only exact identifier tokens present in `mapping` are changed. Record
    declarations, member accesses, comments, literals, and include paths are
    preserved so public names cannot alter data layout or unrelated paths.
    """
    out = []
    i = 0
    n = len(text)
    brace_is_record = []
    record_pending = False
    record_tag_expected = False
    previous_punctuation = None
    while i < n:
        if text.startswith("//", i):
            end = text.find("\n", i + 2)
            if end < 0:
                end = n
            out.append(text[i:end])
            i = end
            previous_punctuation = None
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = n if end < 0 else end + 2
            out.append(text[i:end])
            i = end
            previous_punctuation = None
        elif text[i] in "\"'":
            quote = text[i]
            start = i
            i += 1
            while i < n:
                if text[i] == "\\":
                    i = min(i + 2, n)
                elif text[i] == quote:
                    i += 1
                    break
                else:
                    i += 1
            out.append(text[start:i])
            previous_punctuation = None
        elif text[i] == "<":
            line_start = text.rfind("\n", 0, i) + 1
            directive = text[line_start:i]
            closing = text.find(">", i + 1)
            if closing >= 0 and re.fullmatch(r"\s*#\s*include(?:_next)?\s*", directive):
                out.append(text[i:closing + 1])
                i = closing + 1
            else:
                out.append(text[i])
                i += 1
        elif text[i].isalpha() or text[i] == "_":
            start = i
            i += 1
            while i < n and (text[i].isalnum() or text[i] == "_"):
                i += 1
            token = text[start:i]
            if token in ("struct", "union"):
                record_pending = True
                record_tag_expected = True
            elif record_tag_expected:
                record_tag_expected = False
                out.append(token)
                previous_punctuation = None
                continue
            elif token in mapping:
                in_record_declaration = any(brace_is_record)
                is_member_access = previous_punctuation in (".", "->")
                out.append(token if in_record_declaration or is_member_access else mapping[token])
                previous_punctuation = None
                continue
            out.append(token)
            previous_punctuation = None
        else:
            character = text[i]
            if character == "{":
                brace_is_record.append(record_pending)
                record_pending = False
                record_tag_expected = False
                previous_punctuation = character
            elif character == "}":
                if brace_is_record:
                    brace_is_record.pop()
                record_pending = False
                record_tag_expected = False
                previous_punctuation = character
            elif character in "();":
                if record_pending:
                    record_pending = False
                record_tag_expected = False
                previous_punctuation = character
            elif character == ".":
                previous_punctuation = character
            elif character == "-" and text.startswith("->", i):
                out.append("->")
                i += 2
                previous_punctuation = "->"
                continue
            elif not character.isspace():
                previous_punctuation = character
            out.append(character)
            i += 1
    return "".join(out)


def _render_header(mapping: dict[str, str], undef: bool = False,
                   guard: str = "GENERATED_SYMBOL_NAMESPACE_H") -> str:
    # The undef header clears this guard so a later phase can reapply the map.
    lines = [] if undef else [f"#ifndef {guard}", f"#define {guard}", ""]
    for original, replacement in mapping.items():
        lines.append(f"#undef {original}" if undef else f"#define {original} {replacement}")
    if not undef:
        lines.extend(["", "#endif", ""])
    if undef:
        lines.append(f"#undef {guard}")
    lines.append("")
    return "\n".join(lines)


def _write_if_changed(path: Path, content: str) -> bool:
    path.parent.mkdir(parents=True, exist_ok=True)
    for attempt in range(_RETRY_ATTEMPTS):
        try:
            if path.read_text(encoding="utf-8") == content:
                return False
            break
        except FileNotFoundError:
            break
        except OSError as error:
            # While another writer is in os.replace, Windows fails the read with a
            # PermissionError (errno 13) whose winerror is None, so winerror alone
            # (5, 32) does not detect it. Treat any PermissionError as transient.
            transient = isinstance(error, PermissionError) or getattr(error, "winerror", None) in (5, 32)
            if not transient or attempt == _RETRY_ATTEMPTS - 1:
                raise
            time.sleep(0.01 * (2 ** attempt))
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.chmod(temporary_name, 0o644)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as output:
            output.write(content)
        for attempt in range(_RETRY_ATTEMPTS):
            try:
                os.replace(temporary_name, path)
                break
            except OSError as error:
                try:
                    already_written = path.exists() and path.read_text(encoding="utf-8") == content
                except OSError:
                    already_written = False
                if already_written:
                    os.unlink(temporary_name)
                    return False
                if getattr(error, "winerror", None) not in (5, 32) or attempt == _RETRY_ATTEMPTS - 1:
                    raise
                time.sleep(0.01 * (2 ** attempt))
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise
    return True


def generate(symbols: Path, api_macros: Path, prefix: str,
             namespace_header: Path, undef_header: Path) -> dict[str, str]:
    mapping = load_mapping(symbols, api_macros, prefix)
    namespace_guard = "GENERATED_" + re.sub(r"\W", "_", namespace_header.name.upper())
    _write_if_changed(namespace_header, _render_header(mapping, guard=namespace_guard))
    _write_if_changed(undef_header, _render_header(mapping, undef=True, guard=namespace_guard))
    return mapping


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--symbols", required=True, type=Path)
    parser.add_argument("--api-macros", required=True, type=Path)
    parser.add_argument("--prefix", required=True)
    parser.add_argument("--namespace-header", required=True, type=Path)
    parser.add_argument("--undef-header", required=True, type=Path)
    args = parser.parse_args()
    try:
        generate(args.symbols, args.api_macros, args.prefix,
                 args.namespace_header, args.undef_header)
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
