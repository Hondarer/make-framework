#!/usr/bin/env python3
"""
update_template_makefiles.py - テンプレート由来の makefile を最新版に同期する。

【対象】
  makefw ワークスペース配下の makefile で、先頭行が既知の
  テンプレート識別子で始まるファイル。

  手書き makefile は対象外。

【使い方】
  python framework/makefw/bin/update_template_makefiles.py [--dry-run]

  --dry-run  ファイルを変更せず、更新対象のリストのみ表示する。
"""

import argparse
import sys
from pathlib import Path


TEMPLATE_MAP = {
    "# app 配下 makefile テンプレート": Path(
        "framework/makefw/makefiles/__template.mk"
    ),
    "# app 直下 makefile テンプレート": Path(
        "framework/makefw/makefiles/__app_root_template.mk"
    ),
}


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


def get_template_header(path: Path) -> str | None:
    """makefile の先頭行を返す。読めない場合は None。"""
    try:
        with path.open(encoding="utf-8") as file:
            return file.readline().rstrip("\n")
    except (OSError, UnicodeDecodeError):
        return None


def is_app_root_makefile(workspace: Path, path: Path) -> bool:
    """path が app/<app_name>/makefile かを判定する。"""
    try:
        relative_parts = path.relative_to(workspace).parts
    except ValueError:
        return False

    return (
        len(relative_parts) == 3
        and relative_parts[0] == "app"
        and relative_parts[2] == "makefile"
    )


def validate_template_location(workspace: Path, makefile: Path, header: str) -> str | None:
    """テンプレート識別子と配置場所の整合性エラーを返す。問題なければ None。"""
    if header == "# app 直下 makefile テンプレート" and not is_app_root_makefile(
        workspace, makefile
    ):
        return (
            "app 直下テンプレートは app/<app_name>/makefile にのみ配置できます"
        )

    return None


def is_template_makefile(path: Path) -> bool:
    """makefile の先頭行が既知テンプレート識別子かを判定する。"""
    first_line = get_template_header(path)
    return first_line in TEMPLATE_MAP


def get_template_path_for_makefile(workspace: Path, makefile: Path) -> Path:
    """makefile の先頭行から同期元テンプレートを返す。"""
    first_line = get_template_header(makefile)
    if first_line is None or first_line not in TEMPLATE_MAP:
        raise RuntimeError(f"未知のテンプレート識別子です: {makefile}")

    location_error = validate_template_location(workspace, makefile, first_line)
    if location_error is not None:
        raise RuntimeError(f"{location_error}: {makefile}")

    return workspace / TEMPLATE_MAP[first_line]


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
    missing_templates = [
        workspace / rel_path
        for rel_path in TEMPLATE_MAP.values()
        if not (workspace / rel_path).exists()
    ]
    if missing_templates:
        for template_path in missing_templates:
            print(
                f"エラー: テンプレートファイルが見つかりません: {template_path}",
                file=sys.stderr,
            )
        return 1

    updated = 0
    skipped = 0
    errors = 0

    for makefile in iter_template_makefiles(workspace):
        rel_path = makefile.relative_to(workspace)
        try:
            template_path = get_template_path_for_makefile(workspace, makefile)
        except RuntimeError as exc:
            print(f"エラー: {exc}", file=sys.stderr)
            errors += 1
            continue
        template_content = template_path.read_text(encoding="utf-8")
        current_content = makefile.read_text(encoding="utf-8")

        if current_content == template_content:
            print(f"[スキップ] {rel_path} (すでに最新)")
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

    if errors:
        print(f"エラー: {errors} 件の makefile は配置が不正です。", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
