#!/usr/bin/env python3

import argparse
import sys
from pathlib import Path


def emit_bytes(path: Path) -> int:
    with path.open("rb") as file:
        while True:
            data = file.read(1024 * 1024)
            if not data:
                break
            sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()
    return 0


def emit_text(path: Path) -> int:
    with path.open("r", encoding="utf-8", errors="replace", newline="") as file:
        while True:
            text = file.read(1024 * 1024)
            if not text:
                break
            sys.stdout.write(text)
    sys.stdout.flush()
    return 0


def should_use_text_console() -> bool:
    if sys.platform != "win32":
        return False
    if not sys.stdout.isatty():
        return False
    buffer = getattr(sys.stdout, "buffer", None)
    raw = getattr(buffer, "raw", None)
    return type(raw).__name__ == "_WindowsConsoleIO"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path)
    args = parser.parse_args()

    if should_use_text_console():
        return emit_text(args.path)
    return emit_bytes(args.path)


if __name__ == "__main__":
    raise SystemExit(main())