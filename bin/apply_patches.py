#!/usr/bin/env python3
"""framework/makefw/bin/apply_patches.py

app/cjson, app/sqlite, app/lua などが、packages/ から展開した上流ソースへ
バイト列の前置・置換で改変する代わりに、unified diff 形式のパッチ ファイル
(*.patch) を順に適用するための共通モジュール。各 app の extract_package.py
系スクリプトから import して使うほか、単体の CLI としても実行できる。

外部コマンド (patch、git apply 等) には依存せず、標準ライブラリのみで
unified diff を解析・適用する。上流は固定バージョンのアーカイブから展開され
内容がバイト一致する前提のため、探索や fuzz 適用は行わない。@@ ハンク見出し
が示す行番号にそのまま厳密適用し、文脈行・削除行が対象ファイルの内容と
バイト単位で一致しない場合は PatchError を送出する。
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")


class PatchError(Exception):
    """パッチの解析または適用に失敗したことを表す。"""


_HUNK_HEADER_RE = re.compile(
    rb"^@@ -(?P<old_start>\d+)(?:,(?P<old_count>\d+))? "
    rb"\+(?P<new_start>\d+)(?:,(?P<new_count>\d+))? @@"
)


@dataclass
class _HunkLine:
    """ハンク本体の 1 行。kind は 'context' / 'remove' / 'add' のいずれか。"""

    kind: str
    content: bytes
    no_newline: bool = False


@dataclass
class _Hunk:
    old_start: int
    old_count: int
    new_start: int
    new_count: int
    body: list[_HunkLine] = field(default_factory=list)


@dataclass
class _FilePatch:
    """1 つの '--- a/…' / '+++ b/…' ブロックに対応するパッチ。"""

    target_path: str  # target_root からの相対パス (posix 形式のスラッシュ区切り)
    hunks: list[_Hunk] = field(default_factory=list)


def _split_lines(raw: bytes) -> tuple[list[bytes], bool]:
    """raw を改行区切りの行リストへ分解する。

    戻り値は (各行 (改行を含まない) のリスト, 末尾が改行で終わっていたか)。
    空バイト列は行 0 個・末尾改行なしとして扱う。
    """
    if raw == b"":
        return [], False
    had_trailing_newline = raw.endswith(b"\n")
    body = raw[:-1] if had_trailing_newline else raw
    return body.split(b"\n"), had_trailing_newline


def _join_lines(lines: list[bytes], had_trailing_newline: bool) -> bytes:
    """_split_lines の逆変換。行が 0 個なら常に空バイト列を返す。"""
    if not lines:
        return b""
    return b"\n".join(lines) + (b"\n" if had_trailing_newline else b"")


def _parse_target_path(header: bytes, patch_name: str) -> str:
    """'+++ b/<path>' 見出しから、先頭 1 階層を除去した相対パスを取り出す。

    git apply -p1 相当。タブ区切りで続くタイムスタンプ等は無視する。
    """
    if not header.startswith(b"+++ "):
        raise PatchError(
            f"{patch_name}: '+++' 見出しが見つかりません (実際の行: {header!r})"
        )
    rest = header[len(b"+++ ") :]
    path_bytes = rest.split(b"\t", 1)[0].strip()
    path_str = path_bytes.decode("utf-8", errors="replace")
    parts = path_str.split("/", 1)
    if len(parts) != 2 or not parts[1]:
        raise PatchError(
            f"{patch_name}: '+++' 見出しのパスから先頭階層を除去できません: "
            f"{path_str!r} (a/<path> または b/<path> 形式を想定)"
        )
    return parts[1]


def _parse_hunk(lines: list[bytes], i: int, patch_name: str) -> tuple[_Hunk, int]:
    """lines[i] のハンク見出しから本体行までを読み取り、(Hunk, 次の行 index) を返す。"""
    header = lines[i]
    m = _HUNK_HEADER_RE.match(header)
    if m is None:
        raise PatchError(f"{patch_name}: ハンク見出しを解釈できません: {header!r}")

    old_start = int(m.group("old_start"))
    old_count = int(m.group("old_count")) if m.group("old_count") is not None else 1
    new_start = int(m.group("new_start"))
    new_count = int(m.group("new_count")) if m.group("new_count") is not None else 1

    i += 1
    body: list[_HunkLine] = []
    old_remaining = old_count
    new_remaining = new_count

    while (
        old_remaining > 0
        or new_remaining > 0
        or (i < len(lines) and lines[i].startswith(b"\\"))
    ):
        if i >= len(lines):
            raise PatchError(
                f"{patch_name}: ハンク (@@ -{old_start},{old_count} "
                f"+{new_start},{new_count} @@) の本体行がファイル末尾で不足しています"
            )
        line = lines[i]

        if line.startswith(b"\\"):
            # "\ No newline at end of file" は直前の本体行に付随する注記。
            if not body:
                raise PatchError(
                    f"{patch_name}: ハンク (@@ -{old_start},{old_count} "
                    f"+{new_start},{new_count} @@) の先頭に "
                    "'\\ No newline at end of file' が現れました"
                )
            body[-1].no_newline = True
            i += 1
            continue

        if line.startswith(b" "):
            kind, content = "context", line[1:]
        elif line.startswith(b"-"):
            kind, content = "remove", line[1:]
        elif line.startswith(b"+"):
            kind, content = "add", line[1:]
        elif line == b"":
            # 先頭空白の無い長さ 0 の行を、空行の文脈行として受け付ける。
            kind, content = "context", b""
        else:
            raise PatchError(
                f"{patch_name}: ハンク本体に解釈できない行があります: {line!r}"
            )

        if kind in ("context", "remove"):
            old_remaining -= 1
        if kind in ("context", "add"):
            new_remaining -= 1
        if old_remaining < 0 or new_remaining < 0:
            raise PatchError(
                f"{patch_name}: ハンク (@@ -{old_start},{old_count} "
                f"+{new_start},{new_count} @@) の行数が見出しの宣言と一致しません"
            )

        body.append(_HunkLine(kind, content))
        i += 1

    return _Hunk(old_start, old_count, new_start, new_count, body), i


def _parse_patch_file(raw: bytes, patch_name: str) -> list[_FilePatch]:
    """1 つの .patch ファイル (複数ファイル分の diff を含んでよい) を解析する。"""
    lines, _ = _split_lines(raw)
    i = 0
    n = len(lines)
    file_patches: list[_FilePatch] = []

    while i < n:
        line = lines[i]
        if not line.startswith(b"--- "):
            # 'diff --git ...' や 'index ...' などの前置行は読み飛ばす。
            i += 1
            continue

        i += 1
        if i >= n or not lines[i].startswith(b"+++ "):
            raise PatchError(
                f"{patch_name}: '---' 見出しの直後に '+++' 見出しがありません"
            )
        target_path = _parse_target_path(lines[i], patch_name)
        i += 1

        hunks: list[_Hunk] = []
        while i < n and lines[i].startswith(b"@@ "):
            hunk, i = _parse_hunk(lines, i, patch_name)
            hunks.append(hunk)

        if not hunks:
            raise PatchError(f"{patch_name}: {target_path} にハンクが 1 つもありません")

        file_patches.append(_FilePatch(target_path, hunks))

    return file_patches


def _apply_hunks(
    lines: list[bytes],
    had_trailing_newline: bool,
    hunks: list[_Hunk],
    target_path: str,
    patch_name: str,
) -> tuple[list[bytes], bool]:
    """1 ファイル分のハンク一覧を、対象ファイルの行リストへ厳密適用する。"""
    cursor = 0
    new_lines: list[bytes] = []
    last_touch_no_newline: bool | None = None

    for hunk_index, hunk in enumerate(hunks, start=1):
        # old_count == 0 (純粋な追加) は、old_start が「この行の直後に挿入する」
        # 旧ファイル側の行番号を表す (unified diff の慣例)。それ以外は
        # old_start が旧ファイル側でハンクが始まる 1 始まりの行番号を表す。
        start_idx = hunk.old_start if hunk.old_count == 0 else hunk.old_start - 1

        if start_idx < cursor:
            raise PatchError(
                f"{patch_name}: {target_path} のハンク {hunk_index} の開始行 "
                f"{hunk.old_start} が、直前のハンクまでに処理済みの範囲と重なっています"
            )
        if start_idx > len(lines):
            raise PatchError(
                f"{patch_name}: {target_path} のハンク {hunk_index} の開始行 "
                f"{hunk.old_start} が、ファイルの行数 {len(lines)} を超えています"
            )

        new_lines.extend(lines[cursor:start_idx])
        cursor = start_idx

        for line_no, hline in enumerate(hunk.body, start=1):
            if hline.kind in ("context", "remove"):
                if cursor >= len(lines):
                    raise PatchError(
                        f"{patch_name}: {target_path} のハンク {hunk_index} の "
                        f"{line_no} 行目で、対象ファイルが末尾に達しました。"
                        f"期待した行: {hline.content!r}"
                    )
                actual = lines[cursor]
                if actual != hline.content:
                    raise PatchError(
                        f"{patch_name}: {target_path} のハンク {hunk_index} の "
                        f"{line_no} 行目が一致しません "
                        f"(対象ファイルの {cursor + 1} 行目)。"
                        f"期待した行: {hline.content!r} / 実際の行: {actual!r}"
                    )
                cursor += 1

            if hline.kind in ("context", "add"):
                new_lines.append(hline.content)
                last_touch_no_newline = hline.no_newline

    reached_tail = cursor == len(lines)
    new_lines.extend(lines[cursor:])

    if reached_tail and last_touch_no_newline is not None:
        new_had_trailing_newline = not last_touch_no_newline
    else:
        # ハンクが触れなかった末尾は元ファイルのまま複製されるため、
        # 元ファイルの末尾改行の有無をそのまま引き継ぐ。
        new_had_trailing_newline = had_trailing_newline

    return new_lines, new_had_trailing_newline


def apply_series(patches_dir: Path, target_root: Path) -> list[str]:
    """patches_dir 配下の *.patch をファイル名の昇順に適用する。

    書き換えた対象ファイルの target_root からの相対パス一覧を、最初に
    書き換えられた順で返す (重複なし)。全パッチの適用結果をメモリ上で
    組み立ててから一括で書き出すため、途中で PatchError が送出された場合、
    target_root 配下のファイルは 1 つも変更されない。
    """
    patch_paths = sorted(patches_dir.glob("*.patch")) if patches_dir.is_dir() else []

    # target_path (posix 形式の相対パス文字列) -> (行リスト, 末尾改行の有無)
    state: dict[str, tuple[list[bytes], bool]] = {}
    touched_order: list[str] = []

    for patch_path in patch_paths:
        raw = patch_path.read_bytes()
        file_patches = _parse_patch_file(raw, patch_path.name)

        for file_patch in file_patches:
            target_path = file_patch.target_path
            if target_path in state:
                lines, had_trailing_newline = state[target_path]
            else:
                dest = target_root.joinpath(*target_path.split("/"))
                if not dest.is_file():
                    raise PatchError(
                        f"{patch_path.name}: 対象ファイルが見つかりません: {dest}"
                    )
                lines, had_trailing_newline = _split_lines(dest.read_bytes())

            new_lines, new_had_trailing_newline = _apply_hunks(
                lines,
                had_trailing_newline,
                file_patch.hunks,
                target_path,
                patch_path.name,
            )

            if target_path not in state:
                touched_order.append(target_path)
            state[target_path] = (new_lines, new_had_trailing_newline)

    for target_path, (lines, had_trailing_newline) in state.items():
        dest = target_root.joinpath(*target_path.split("/"))
        dest.write_bytes(_join_lines(lines, had_trailing_newline))

    return touched_order


def series_digest(patches_dir: Path) -> str:
    """patches_dir 配下の *.patch を名前順に読み、内容の SHA-256 を 16 進文字列で返す。

    ディレクトリが無い、または *.patch が 1 つも無い場合は、空系列としての
    digest を返す (呼び出し側がスタンプ比較に使うため、例外にしない)。
    """
    digest = hashlib.sha256()
    digest.update(b"apply-patches-series-v1\n")

    patch_paths = sorted(patches_dir.glob("*.patch")) if patches_dir.is_dir() else []
    for patch_path in patch_paths:
        digest.update(patch_path.name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(hashlib.sha256(patch_path.read_bytes()).hexdigest().encode("ascii"))
        digest.update(b"\n")

    return digest.hexdigest()


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "packages/ から展開した上流ソースへ、patches_dir 配下の *.patch "
            "(unified diff) をファイル名の昇順に厳密適用する。"
        )
    )
    parser.add_argument(
        "--patches-dir",
        required=True,
        type=Path,
        help="*.patch を置くディレクトリ",
    )
    parser.add_argument(
        "--target-root",
        type=Path,
        help="パッチの適用先ルート ディレクトリ (--digest 指定時は不要)",
    )
    parser.add_argument(
        "--digest",
        action="store_true",
        help="適用は行わず、パッチ系列の digest を標準出力へ 1 行だけ出す",
    )
    args = parser.parse_args(argv)
    if not args.digest and args.target_root is None:
        parser.error("--target-root は --digest 指定時を除き必須です")
    return args


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)

    if args.digest:
        print(series_digest(args.patches_dir))
        return 0

    try:
        touched = apply_series(args.patches_dir, args.target_root)
    except PatchError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    for path in touched:
        print(f"INFO: パッチを適用しました: {path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
