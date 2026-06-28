#!/usr/bin/env python3

import argparse
import ctypes
import sys
from pathlib import Path

CP_UTF8 = 65001
STD_OUTPUT_HANDLE = -11
CHUNK_BYTES = 1024 * 1024
CHUNK_CHARS = 64 * 1024
INVALID_HANDLE_VALUE = -1


def emit_bytes(path: Path) -> int:
    with path.open("rb") as file:
        while True:
            data = file.read(CHUNK_BYTES)
            if not data:
                break
            sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()
    return 0


def _kernel32():
    from ctypes import wintypes

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.GetStdHandle.argtypes = [wintypes.DWORD]
    kernel32.GetStdHandle.restype = wintypes.HANDLE
    kernel32.GetConsoleMode.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    kernel32.GetConsoleMode.restype = wintypes.BOOL
    kernel32.WriteConsoleW.argtypes = [
        wintypes.HANDLE,
        wintypes.LPCWSTR,
        wintypes.DWORD,
        ctypes.POINTER(wintypes.DWORD),
        wintypes.LPVOID,
    ]
    kernel32.WriteConsoleW.restype = wintypes.BOOL
    kernel32.GetConsoleOutputCP.argtypes = []
    kernel32.GetConsoleOutputCP.restype = wintypes.UINT
    kernel32.SetConsoleOutputCP.argtypes = [wintypes.UINT]
    kernel32.SetConsoleOutputCP.restype = wintypes.BOOL
    return kernel32, wintypes


def _is_invalid_handle(handle) -> bool:
    return not handle or int(handle) == INVALID_HANDLE_VALUE


def emit_with_write_console(path: Path) -> bool:
    kernel32, wintypes = _kernel32()
    handle = kernel32.GetStdHandle(STD_OUTPUT_HANDLE)
    mode = wintypes.DWORD()
    if _is_invalid_handle(handle) or not kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
        return False

    written = wintypes.DWORD()
    with path.open("r", encoding="utf-8", errors="strict", newline="") as file:
        while True:
            text = file.read(CHUNK_CHARS)
            if not text:
                break
            offset = 0
            while offset < len(text):
                chunk = text[offset : offset + CHUNK_CHARS]
                if not kernel32.WriteConsoleW(handle, chunk, len(chunk), ctypes.byref(written), None):
                    raise OSError(ctypes.get_last_error(), "WriteConsoleW failed")
                if written.value == 0:
                    raise OSError(ctypes.get_last_error(), "WriteConsoleW wrote no characters")
                offset += written.value
    return True


def emit_bytes_with_utf8_codepage(path: Path) -> int:
    kernel32, _ = _kernel32()
    original_cp = kernel32.GetConsoleOutputCP()
    changed = False

    try:
        if original_cp and original_cp != CP_UTF8:
            changed = bool(kernel32.SetConsoleOutputCP(CP_UTF8))
        return emit_bytes(path)
    finally:
        if changed:
            kernel32.SetConsoleOutputCP(original_cp)


def emit_windows(path: Path) -> int:
    try:
        if emit_with_write_console(path):
            return 0
    except OSError:
        pass
    return emit_bytes_with_utf8_codepage(path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path)
    args = parser.parse_args()

    if sys.platform == "win32":
        return emit_windows(args.path)
    return emit_bytes(args.path)


if __name__ == "__main__":
    raise SystemExit(main())