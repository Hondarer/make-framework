#!/usr/bin/env python3
"""
update_template_makefiles.py - テンプレート由来の makefile を最新版に同期する。

【対象】
  makefw ワークスペース配下の makefile で、先頭行が
  "# makefile テンプレート" で始まるファイル。

  手書き makefile や中間ディレクトリの SUBDIRS 形式 makefile は対象外。

【使い方】
  python framework/makefw/bin/update_template_makefiles.py [--dry-run]

  --dry-run  ファイルを変更せず、更新対象のリストのみ表示する。
"""

import argparse
import sys
from pathlib import Path


TEMPLATE_HEADER = "# makefile テンプレート"
TEMPLATE_REL_PATH = Path("framework/makefw/makefiles/__template.mk")


def find_workspace_root(start: Path) -> Path:
    """start から上方向に .workspaceRoot を探してワークスペースルートを返す。"""
    current = start.resolve()
    while True:
        if (current / ".workspaceRoot").exists():
            return current
        parent = current.parent
        if parent == current:
            raise RuntimeError(".workspaceRoot が見つかりません。")
        current = parent


def is_template_makefile(path: Path) -> bool:
    """makefile の先頭行がテンプレート識別子かを判定する。"""
    try:
        with path.open(encoding="utf-8") as file:
            first_line = file.readline()
        return first_line.startswith(TEMPLATE_HEADER)
    except (OSError, UnicodeDecodeError):
        return False


def iter_template_makefiles(workspace: Path):
    """ワークスペース配下のテンプレート由来 makefile を列挙する。"""
    for makefile in sorted(workspace.rglob("makefile")):
        if is_template_makefile(makefile):
            yield makefile


def main() -> int:
    parser = argparse.ArgumentParser(
        description="テンプレート由来の makefile を最新版に同期する。"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="ファイルを変更せず、更新対象のリストのみ表示する。",
    )
    args = parser.parse_args()

    workspace = find_workspace_root(Path(__file__).parent)
    template_path = workspace / TEMPLATE_REL_PATH

    if not template_path.exists():
        print(f"エラー: テンプレートファイルが見つかりません: {template_path}", file=sys.stderr)
        return 1

    template_content = template_path.read_text(encoding="utf-8")

    updated = 0
    skipped = 0

    for makefile in iter_template_makefiles(workspace):
        rel_path = makefile.relative_to(workspace)
        current_content = makefile.read_text(encoding="utf-8")

        if current_content == template_content:
            print(f"[スキップ] {rel_path} (既に最新)")
            skipped += 1
            continue

        if args.dry_run:
            print(f"[対象]     {rel_path}")
        else:
            makefile.write_text(template_content, encoding="utf-8")
            print(f"[更新]     {rel_path}")
        updated += 1

    if args.dry_run:
        print(f"\n合計: {updated} 件が更新対象, {skipped} 件はスキップ予定 (--dry-run モード)")
    else:
        print(f"\n完了: {updated} 件更新, {skipped} 件スキップ")

    return 0


if __name__ == "__main__":
    sys.exit(main())
