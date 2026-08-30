#!/usr/bin/env python3
"""framework/makefw/bin/apply_patches_selftest.py

apply_patches.py の自己テスト。命名は既存の
bin/msvc_compile_heap_retry_selftest.ps1 に倣う。

一時ディレクトリ上だけで完結し、リポジトリ内のファイルは一切書き換えない。
各検査の合否を日本語で標準出力へ出し、すべて成功すれば終了コード 0、
1 つでも失敗すれば非 0 で終了する。
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

sys.path.insert(0, str(Path(__file__).resolve().parent))

import apply_patches  # noqa: E402  (sys.path 設定後に import する)

_failures: list[str] = []


def check(condition: bool, message: str) -> None:
    if condition:
        print(f"PASS: {message}")
    else:
        print(f"FAIL: {message}")
        _failures.append(message)


def write(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)


def check_1_single_hunk_add(tmp: Path) -> None:
    """検査 1: 1 ファイル 1 ハンクの追加が正しく適用される。"""
    target_root = tmp / "case1" / "target"
    patches_dir = tmp / "case1" / "patches"
    write(target_root / "file1.txt", b"line1\nline2\nline3\n")
    write(
        patches_dir / "0001-add-middle.patch",
        b"--- a/file1.txt\n"
        b"+++ b/file1.txt\n"
        b"@@ -1,3 +1,4 @@\n"
        b" line1\n"
        b" line2\n"
        b"+line2.5\n"
        b" line3\n",
    )

    touched = apply_patches.apply_series(patches_dir, target_root)
    result = (target_root / "file1.txt").read_bytes()

    check(
        result == b"line1\nline2\nline2.5\nline3\n",
        "検査1: 1 ファイル 1 ハンクの行追加が正しく適用される",
    )
    check(touched == ["file1.txt"], "検査1: 書き換え対象一覧に file1.txt が含まれる")


def check_2_prepend_line(tmp: Path) -> None:
    """検査 2: ファイル先頭への行の前置が正しく適用される (既存 app の用途)。"""
    target_root = tmp / "case2" / "target"
    patches_dir = tmp / "case2" / "patches"
    write(target_root / "file2.txt", b"first\nsecond\n")
    write(
        patches_dir / "0001-prepend.patch",
        b"--- a/file2.txt\n"
        b"+++ b/file2.txt\n"
        b"@@ -1,2 +1,3 @@\n"
        b"+prefix line\n"
        b" first\n"
        b" second\n",
    )

    apply_patches.apply_series(patches_dir, target_root)
    result = (target_root / "file2.txt").read_bytes()

    check(
        result == b"prefix line\nfirst\nsecond\n",
        "検査2: ファイル先頭への行の前置が正しく適用される",
    )


def check_3_multi_file_single_patch(tmp: Path) -> None:
    """検査 3: 1 つの .patch に複数ファイル分の diff が適用される。"""
    target_root = tmp / "case3" / "target"
    patches_dir = tmp / "case3" / "patches"
    write(target_root / "fileA.txt", b"a1\na2\n")
    write(target_root / "fileB.txt", b"b1\nb2\n")
    write(
        patches_dir / "0001-multi.patch",
        b"--- a/fileA.txt\n"
        b"+++ b/fileA.txt\n"
        b"@@ -1,2 +1,2 @@\n"
        b" a1\n"
        b"-a2\n"
        b"+a2-mod\n"
        b"--- a/fileB.txt\n"
        b"+++ b/fileB.txt\n"
        b"@@ -1,2 +1,3 @@\n"
        b" b1\n"
        b" b2\n"
        b"+b3\n",
    )

    touched = apply_patches.apply_series(patches_dir, target_root)
    result_a = (target_root / "fileA.txt").read_bytes()
    result_b = (target_root / "fileB.txt").read_bytes()

    check(result_a == b"a1\na2-mod\n", "検査3: 1 patch 内の 1 つめのファイルが適用される")
    check(result_b == b"b1\nb2\nb3\n", "検査3: 1 patch 内の 2 つめのファイルが適用される")
    check(
        set(touched) == {"fileA.txt", "fileB.txt"},
        "検査3: 書き換え対象一覧に両方のファイルが含まれる",
    )


def check_4_multi_patch_ordering(tmp: Path) -> None:
    """検査 4: 複数の .patch がファイル名の昇順に適用される。"""
    target_root = tmp / "case4" / "target"
    patches_dir = tmp / "case4" / "patches"
    write(target_root / "fileC.txt", b"base\n")

    # 020 は 010 適用後にできる "step1" 行を文脈として要求するため、
    # ファイル名の昇順 (010 -> 020) でなければ適用に失敗する構造にしてある。
    # ディスクへの書き込み順序をあえてファイル名の逆順にし、
    # ディレクトリ列挙順ではなくファイル名で並べ替えていることを確認する。
    write(
        patches_dir / "020-second.patch",
        b"--- a/fileC.txt\n"
        b"+++ b/fileC.txt\n"
        b"@@ -1,2 +1,3 @@\n"
        b" base\n"
        b" step1\n"
        b"+step2\n",
    )
    write(
        patches_dir / "010-first.patch",
        b"--- a/fileC.txt\n"
        b"+++ b/fileC.txt\n"
        b"@@ -1,1 +1,2 @@\n"
        b" base\n"
        b"+step1\n",
    )

    apply_patches.apply_series(patches_dir, target_root)
    result = (target_root / "fileC.txt").read_bytes()

    check(
        result == b"base\nstep1\nstep2\n",
        "検査4: 複数の .patch がファイル名の昇順 (010 -> 020) に適用される",
    )


def check_5_context_mismatch(tmp: Path) -> None:
    """検査 5: 文脈行が一致しないと PatchError になり、対象ファイルは書き換えられない。"""
    target_root = tmp / "case5" / "target"
    patches_dir = tmp / "case5" / "patches"
    original = b"x1\nx2\nx3\n"
    write(target_root / "fileD.txt", original)
    write(
        patches_dir / "0001-mismatch.patch",
        b"--- a/fileD.txt\n"
        b"+++ b/fileD.txt\n"
        b"@@ -1,3 +1,3 @@\n"
        b" x1\n"
        b"-x2-wrong\n"
        b"+x2-changed\n"
        b" x3\n",
    )

    raised = False
    try:
        apply_patches.apply_series(patches_dir, target_root)
    except apply_patches.PatchError:
        raised = True

    check(raised, "検査5: 文脈行不一致で PatchError が送出される")
    check(
        (target_root / "fileD.txt").read_bytes() == original,
        "検査5: 文脈行不一致時に対象ファイルが書き換えられていない",
    )


def check_6_offset_mismatch(tmp: Path) -> None:
    """検査 6: @@ の行番号がずれていると PatchError になる (探索して救済しない)。"""
    target_root = tmp / "case6" / "target"
    patches_dir = tmp / "case6" / "patches"
    original = b"y1\ny2\ny3\n"
    write(target_root / "fileE.txt", original)
    write(
        patches_dir / "0001-offset.patch",
        # ファイルは 3 行しかないのに、10 行目から始まるハンクを指定する。
        b"--- a/fileE.txt\n"
        b"+++ b/fileE.txt\n"
        b"@@ -10,1 +10,1 @@\n"
        b" y1\n",
    )

    raised = False
    try:
        apply_patches.apply_series(patches_dir, target_root)
    except apply_patches.PatchError:
        raised = True

    check(raised, "検査6: ハンクの行番号がファイル範囲を超えると PatchError が送出される")
    check(
        (target_root / "fileE.txt").read_bytes() == original,
        "検査6: 行番号ずれ時に対象ファイルが書き換えられていない",
    )


def check_7_no_trailing_newline(tmp: Path) -> None:
    """検査 7: 末尾に改行が無いファイルを正しく扱える。"""
    target_root = tmp / "case7" / "target"
    patches_dir = tmp / "case7" / "patches"
    write(target_root / "fileF.txt", b"a\nb")  # 末尾に改行なし
    write(
        patches_dir / "0001-no-newline.patch",
        b"--- a/fileF.txt\n"
        b"+++ b/fileF.txt\n"
        b"@@ -1,2 +1,3 @@\n"
        b" a\n"
        b"+middle\n"
        b" b\n"
        b"\\ No newline at end of file\n",
    )

    apply_patches.apply_series(patches_dir, target_root)
    result = (target_root / "fileF.txt").read_bytes()

    check(
        result == b"a\nmiddle\nb",
        "検査7: 末尾に改行の無いファイルへの適用後も末尾改行なしが保たれる",
    )


def check_8_series_digest(tmp: Path) -> None:
    """検査 8: series_digest が、内容が同じなら同じ値、1 文字変えると別の値を返す。"""
    dir_a = tmp / "case8" / "a"
    dir_b = tmp / "case8" / "b"
    dir_c = tmp / "case8" / "c"

    patch_content = b"--- a/f.txt\n+++ b/f.txt\n@@ -1,1 +1,1 @@\n-old\n+new\n"
    write(dir_a / "0001-x.patch", patch_content)
    write(dir_b / "0001-x.patch", patch_content)
    # 1 文字だけ変えた内容 (new -> nfw)。
    write(dir_c / "0001-x.patch", patch_content.replace(b"new", b"nfw"))

    digest_a = apply_patches.series_digest(dir_a)
    digest_b = apply_patches.series_digest(dir_b)
    digest_c = apply_patches.series_digest(dir_c)

    check(digest_a == digest_b, "検査8: 内容が同じパッチ系列は同じ digest を返す")
    check(digest_a != digest_c, "検査8: パッチを 1 文字変えると digest が変わる")

    empty_dir = tmp / "case8" / "empty"
    empty_dir.mkdir(parents=True, exist_ok=True)
    missing_dir = tmp / "case8" / "does-not-exist"
    try:
        digest_empty = apply_patches.series_digest(empty_dir)
        digest_missing = apply_patches.series_digest(missing_dir)
        check(
            digest_empty == digest_missing,
            "検査8: 空ディレクトリと存在しないディレクトリで同じ digest (空系列) を返す",
        )
    except Exception as exc:  # noqa: BLE001  (例外を出さないことそのものが検査対象)
        check(False, f"検査8: 空/未存在ディレクトリで例外を送出しない ({exc})")


def main() -> int:
    checks = [
        check_1_single_hunk_add,
        check_2_prepend_line,
        check_3_multi_file_single_patch,
        check_4_multi_patch_ordering,
        check_5_context_mismatch,
        check_6_offset_mismatch,
        check_7_no_trailing_newline,
        check_8_series_digest,
    ]

    with tempfile.TemporaryDirectory(prefix="apply_patches_selftest_") as tmp_name:
        tmp = Path(tmp_name)
        for fn in checks:
            fn(tmp)

    print("")
    if _failures:
        print(f"{len(_failures)} 件の自己テストが失敗しました。")
        return 1

    print("すべての自己テストが成功しました。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
