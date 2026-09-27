#!/usr/bin/env python3
"""Emit a stable signature for app Doxygen inputs under prod/."""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import shlex
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")


DOXYGEN_EXTENSIONS = {
    ".c",
    ".cc",
    ".cxx",
    ".cpp",
    ".c++",
    ".java",
    ".ii",
    ".ixx",
    ".ipp",
    ".i++",
    ".inl",
    ".idl",
    ".ddl",
    ".odl",
    ".h",
    ".hh",
    ".hxx",
    ".hpp",
    ".h++",
    ".cs",
    ".d",
    ".php",
    ".php4",
    ".php5",
    ".phtml",
    ".inc",
    ".m",
    ".markdown",
    ".md",
    ".mm",
    ".dox",
    ".py",
    ".pyw",
    ".f90",
    ".f95",
    ".f03",
    ".f08",
    ".f",
    ".for",
    ".tcl",
    ".vhd",
    ".vhdl",
    ".ucf",
    ".qsf",
}

IMAGE_EXTENSIONS = {
    ".bmp",
    ".gif",
    ".jpeg",
    ".jpg",
    ".pbm",
    ".pgm",
    ".png",
    ".ppm",
    ".svg",
    ".webp",
    ".xpm",
}

EXCLUDED_DIRS = {
    "bin",
    "lib",
    "obj",
}

ASSIGNMENT_RE = re.compile(r"^[ \t]*([A-Za-z0-9_]+)[ \t]*(\+?=)[ \t]*(.*)$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Emit a stable Doxygen input signature for app/prod."
    )
    parser.add_argument("app_dir", help="app/<name> directory")
    return parser.parse_args()


def is_special_doxyfile(path: Path) -> bool:
    name = path.name
    return name == "Doxyfile.part" or name.startswith("Doxyfile.part.")


def is_doxygen_source(path: Path) -> bool:
    suffix = path.suffix.lower()
    return suffix in DOXYGEN_EXTENSIONS


def is_image_file(path: Path) -> bool:
    suffix = path.suffix.lower()
    return suffix in IMAGE_EXTENSIONS


def split_config_values(value: str) -> list[str]:
    try:
        return shlex.split(value, comments=False, posix=True)
    except ValueError:
        return value.split()


def read_config_values(path: Path, key: str) -> list[str]:
    values: list[str] = []
    pending_key = ""
    pending_operator = ""
    pending_value = ""

    for raw_line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.rstrip()
        if pending_key:
            continued = line.endswith("\\")
            if continued:
                line = line[:-1]
            pending_value = f"{pending_value} {line.strip()}"
            if continued:
                continue
            if pending_key == key:
                if pending_operator == "=":
                    values = split_config_values(pending_value)
                else:
                    values.extend(split_config_values(pending_value))
            pending_key = ""
            pending_operator = ""
            pending_value = ""
            continue

        match = ASSIGNMENT_RE.match(line)
        if match is None:
            continue

        current_key, operator, current_value = match.groups()
        continued = current_value.endswith("\\")
        if continued:
            current_value = current_value[:-1]

        if continued:
            pending_key = current_key
            pending_operator = operator
            pending_value = current_value.strip()
            continue

        if current_key == key:
            if operator == "=":
                values = split_config_values(current_value)
            else:
                values.extend(split_config_values(current_value))

    return values


def iter_files_under(root_dir: Path, include_images: bool):
    for root, dirs, files in os.walk(root_dir):
        root_path = Path(root)
        rel_root = root_path.relative_to(root_dir)

        dirs[:] = sorted(
            directory
            for directory in dirs
            if directory not in EXCLUDED_DIRS
            and not any(part in EXCLUDED_DIRS for part in (rel_root / directory).parts)
        )

        for filename in sorted(files):
            path = root_path / filename
            if is_doxygen_source(path) or (include_images and is_image_file(path)):
                yield path


def resolve_prod_path(prod_dir: Path, value: str) -> Path | None:
    path = Path(value)
    if not path.is_absolute():
        path = prod_dir / path
    try:
        resolved = path.resolve()
        resolved.relative_to(prod_dir)
    except (OSError, ValueError):
        return None
    return resolved


def iter_input_files(prod_dir: Path):
    candidates: dict[str, Path] = {}
    doxyfile_parts = sorted(
        path for path in prod_dir.iterdir() if path.is_file() and is_special_doxyfile(path)
    )

    for part in doxyfile_parts:
        candidates[part.relative_to(prod_dir).as_posix()] = part

        input_values = read_config_values(part, "INPUT")
        if not input_values:
            input_values = ["."]

        image_values = read_config_values(part, "IMAGE_PATH")

        for value in input_values:
            path = resolve_prod_path(prod_dir, value)
            if path is None or not path.exists():
                continue
            if path.is_file():
                if is_doxygen_source(path):
                    candidates[path.relative_to(prod_dir).as_posix()] = path
            elif path.is_dir():
                for input_file in iter_files_under(path, include_images=False):
                    candidates[input_file.relative_to(prod_dir).as_posix()] = input_file

        for value in image_values:
            path = resolve_prod_path(prod_dir, value)
            if path is None or not path.exists():
                continue
            if path.is_file():
                if is_image_file(path):
                    candidates[path.relative_to(prod_dir).as_posix()] = path
            elif path.is_dir():
                for input_file in iter_files_under(path, include_images=True):
                    if is_image_file(input_file):
                        candidates[input_file.relative_to(prod_dir).as_posix()] = input_file

    for relative_path in sorted(candidates):
        yield candidates[relative_path]


def hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def emit_signature(app_dir: Path) -> int:
    prod_dir = (app_dir / "prod").resolve()
    if not prod_dir.is_dir():
        print(f"ERROR: prod directory not found: {prod_dir}", file=sys.stderr)
        return 1

    entries = []
    for path in iter_input_files(prod_dir):
        relative_path = path.relative_to(prod_dir).as_posix()
        entries.append((relative_path, hash_file(path)))

    digest = hashlib.sha256()
    digest.update(b"doxy-signature-v1\n")
    for relative_path, file_hash in entries:
        digest.update(relative_path.encode("utf-8"))
        digest.update(b"\0")
        digest.update(file_hash.encode("ascii"))
        digest.update(b"\n")

    print(f"DOXY_SIGNATURE=v1:{digest.hexdigest()}")
    for relative_path, file_hash in entries:
        print(f"{relative_path}\t{file_hash}")

    return 0


def main() -> int:
    args = parse_args()
    try:
        return emit_signature(Path(args.app_dir).resolve())
    except OSError as exc:
        print(f"ERROR: failed to read Doxygen inputs: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
