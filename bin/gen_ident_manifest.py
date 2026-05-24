#!/usr/bin/env python3
"""IDENT manifest generator.

Modes:
  source-info : read a .d file, hash source + headers, write per-source .ident JSON
  combine     : collect .ident files from dirs, generate manifest C source
"""

import sys
import os
import re
import json
import hashlib
import argparse

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")


def sha256_file(path):
    h = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            while True:
                chunk = f.read(65536)
                if not chunk:
                    break
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return None


def parse_dep_file(dep_file_path):
    """Parse a Makefile .d dependency file.

    Returns (source_path_str, [header_path_str, ...]).
    Paths are as they appear in the file (may be relative or absolute, forward slashes).
    """
    try:
        with open(dep_file_path, encoding="utf-8", errors="replace") as f:
            content = f.read()
    except FileNotFoundError:
        return None, []

    # Join continuation lines (backslash-newline)
    content = re.sub(r"\\\r?\n", " ", content)

    source = None
    headers = []
    _SOURCE_EXTS = (".c", ".cc", ".cpp", ".cxx")
    _HEADER_EXTS = (".h", ".hpp", ".hh", ".hxx")

    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        colon_idx = find_make_rule_colon(line)
        if colon_idx < 0:
            continue

        deps_str = line[colon_idx + 1 :].strip()

        # Skip empty rules (e.g., "header.h:")
        if not deps_str:
            continue

        tokens = split_make_words(deps_str)
        if not tokens:
            continue

        # First token is the source file
        first = tokens[0].replace("\\", "/")
        if source is None and any(first.endswith(ext) for ext in _SOURCE_EXTS):
            source = first

        # Remaining tokens are headers
        for tok in tokens[1:]:
            tok = tok.replace("\\", "/")
            if any(tok.endswith(ext) for ext in _HEADER_EXTS):
                headers.append(tok)

    return source, headers


def split_make_words(value):
    """Split Makefile dependency words while honoring backslash escapes."""
    words = []
    current = []
    escaped = False

    for ch in value:
        if escaped:
            current.append(ch)
            escaped = False
        elif ch == "\\":
            escaped = True
        elif ch.isspace():
            if current:
                words.append("".join(current))
                current = []
        else:
            current.append(ch)

    if escaped:
        current.append("\\")
    if current:
        words.append("".join(current))

    return words


def find_make_rule_colon(line):
    """Return the rule separator colon, ignoring Windows drive-letter colons."""
    escaped = False
    for i, ch in enumerate(line):
        if escaped:
            escaped = False
            continue
        if ch == "\\":
            escaped = True
            continue
        if ch == ":" and (i == len(line) - 1 or line[i + 1].isspace()):
            return i
    return -1


def normalize_workspace(ws):
    return ws.rstrip("/\\").replace("\\", "/")


def resolve_abs(path_str, base_dir):
    """Resolve path_str to absolute path, using base_dir for relative paths."""
    p = path_str.replace("\\", "/")
    if os.path.isabs(p):
        return p
    return os.path.join(base_dir, p).replace("\\", "/")


def write_if_changed(path, content):
    """Write content to path only if it differs from existing content."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            if f.read() == content:
                return
    except FileNotFoundError:
        pass

    tmp_path = path + ".tmp"
    try:
        with open(tmp_path, "w", encoding="utf-8") as f:
            f.write(content)
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except Exception:
            pass
        raise


def mode_source_info(args):
    """Generate per-source .ident file from a .d dependency file."""
    dep_file = args.dep_file
    src_dir = (args.src_dir or "").replace("\\", "/")
    workspace = normalize_workspace(args.workspace)
    out_path = args.out

    source_str, header_paths = parse_dep_file(dep_file)

    # Resolve source to absolute path
    source_abs = None
    source_ws_rel = None
    source_sha256 = None

    # Windows: .d paths from MSVC are lowercase; workspace may be mixed case.
    # Use case-insensitive prefix check (len is identical so slicing still works).
    workspace_ci = workspace.lower()

    if source_str:
        source_abs = resolve_abs(source_str, src_dir)
        if source_abs.lower().startswith(workspace_ci + "/"):
            source_ws_rel = source_abs[len(workspace) + 1 :]
        source_sha256 = sha256_file(source_abs)

    # Filter headers within workspace and compute SHA-256
    headers = []
    seen = set()
    for h in header_paths:
        h_abs = resolve_abs(h, src_dir)
        if not h_abs.lower().startswith(workspace_ci + "/"):
            continue
        h_ws_rel = h_abs[len(workspace) + 1 :]
        if h_ws_rel in seen:
            continue
        seen.add(h_ws_rel)

        h_sha256 = sha256_file(h_abs)
        if h_sha256 is not None:
            headers.append({"path": h_ws_rel, "sha256": h_sha256})

    # Sort for determinism
    headers.sort(key=lambda x: x["path"])

    data = {
        "source": source_ws_rel or "",
        "source_sha256": source_sha256 or "",
        "headers": headers,
    }

    content = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    out_dir = os.path.dirname(out_path)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    write_if_changed(out_path, content)


def find_ident_files(ident_dir):
    """Recursively find all .ident files under ident_dir."""
    result = []
    for root, _dirs, files in os.walk(ident_dir):
        for f in files:
            if f.endswith(".ident"):
                result.append(os.path.join(root, f))
    return result


def read_ident_srcs(srcs_file):
    """Read .ident_srcs file and return list of ident_dirs."""
    dirs = []
    try:
        with open(srcs_file, encoding="utf-8") as f:
            in_section = False
            for line in f:
                line = line.strip()
                if line == "[ident_dir]":
                    in_section = True
                elif line.startswith("["):
                    in_section = False
                elif in_section and line:
                    dirs.append(line)
    except FileNotFoundError:
        pass
    return dirs


def sanitize_symbol(name):
    """Convert a filename to a valid C identifier."""
    sym = re.sub(r"[^A-Za-z0-9_]", "_", name)
    if sym and sym[0].isdigit():
        sym = "_" + sym
    return sym


def mode_combine(args):
    """Generate manifest C source from collected .ident files."""
    workspace = normalize_workspace(args.workspace)
    target = args.target or "unknown"
    target_arch = args.target_arch or ""
    out_path = args.out

    # Read git rev
    rev = "unknown"
    if args.rev_file:
        try:
            with open(args.rev_file, encoding="utf-8") as f:
                rev = f.read().strip()
        except FileNotFoundError:
            pass

    # Collect ident dirs from command line and from .ident_srcs files
    ident_dirs = list(args.ident_dirs) if args.ident_dirs else []

    if args.ident_srcs_files:
        for srcs_file in args.ident_srcs_files:
            if srcs_file:
                ident_dirs.extend(read_ident_srcs(srcs_file))

    # Collect all .ident files
    all_ident_files = []
    for d in ident_dirs:
        if d and os.path.isdir(d):
            all_ident_files.extend(find_ident_files(d))

    # Read and parse all .ident files
    sources = []
    for ident_file in sorted(all_ident_files):
        try:
            with open(ident_file, encoding="utf-8") as f:
                data = json.load(f)
            if data.get("source"):
                sources.append(data)
        except Exception:
            pass

    # Sort by source path for determinism
    sources.sort(key=lambda x: x.get("source", ""))

    # Generate C source
    sym = "_ident_manifest_" + sanitize_symbol(target)

    lines = []
    lines.append("/* Auto-generated by gen_ident_manifest.py. Do not edit. */")
    lines.append("#if defined(_MSC_VER)")
    lines.append("#  if defined(_M_IX86)")
    # MSVC x86: C symbol _foo gets linker symbol __foo (extra underscore)
    lines.append(f'#    pragma comment(linker, "/INCLUDE:_{sym}")')
    lines.append("#  else")
    lines.append(f'#    pragma comment(linker, "/INCLUDE:{sym}")')
    lines.append("#  endif")
    lines.append("#  define IDENT_USED")
    lines.append("#else")
    lines.append('#  define IDENT_USED static __attribute__((used, section(".ident")))')
    lines.append("#endif")
    lines.append("")
    lines.append(f"IDENT_USED const char {sym}[] =")

    begin_line = f"@(#)IDENT-BEGIN target={target} rev={rev} arch={target_arch}"
    lines.append(f'    "{begin_line}\\n"')

    for src_data in sources:
        src_path = src_data.get("source", "")
        src_sha256 = src_data.get("source_sha256", "")
        hdrs = src_data.get("headers", [])

        c_line = f"@(#)IDENT-C {src_path} sha256={src_sha256}"
        lines.append(f'    "{c_line}\\n"')

        for h in hdrs:
            h_path = h.get("path", "")
            h_sha256 = h.get("sha256", "")
            ch_line = f"@(#)IDENT-CH  {h_path} sha256={h_sha256}"
            lines.append(f'    "{ch_line}\\n"')

    lines.append('    "@(#)IDENT-END\\n";')
    lines.append("")

    content = "\n".join(lines) + "\n"
    out_dir = os.path.dirname(out_path)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    write_if_changed(out_path, content)


def main():
    parser = argparse.ArgumentParser(description="IDENT manifest generator")
    parser.add_argument(
        "--mode", choices=["source-info", "combine"], required=True
    )

    # source-info mode
    parser.add_argument("--dep-file", help="Path to .d dependency file")
    parser.add_argument(
        "--src-dir",
        help="Directory containing source file (for resolving relative paths in .d)",
    )

    # combine mode
    parser.add_argument(
        "--ident-dirs", nargs="*", help="Directories to search for .ident files"
    )
    parser.add_argument(
        "--ident-srcs-files", nargs="*", help="Paths to .ident_srcs files"
    )
    parser.add_argument("--target", help="Target artifact name (e.g., libcalc.so)")
    parser.add_argument("--target-arch", help="Target architecture string")
    parser.add_argument(
        "--rev-file", help="Path to file containing git short hash"
    )

    # common
    parser.add_argument(
        "--workspace", required=True, help="Workspace root directory"
    )
    parser.add_argument("--out", required=True, help="Output file path")

    args = parser.parse_args()

    if args.mode == "source-info":
        mode_source_info(args)
    elif args.mode == "combine":
        mode_combine(args)


if __name__ == "__main__":
    main()
