# update_template_makefiles.py — makefw 保守コマンド

## 概要

`update_template_makefiles.py` は、makefw のテンプレートから生成・配置した `makefile` を、
最新テンプレート内容へ一括同期する保守コマンドです。

対象は `.workspaceRoot` を持つ makefw ワークスペース全体です。  
手書きの `makefile` は変更しません。

## 何を同期するか

同期元は先頭行の識別子に応じて切り替わります。

| 先頭行 | 同期元 |
|-------|--------|
| `# app 配下 makefile テンプレート` | `framework/makefw/makefiles/__template.mk` |
| `# app 直下 makefile テンプレート` | `framework/makefw/makefiles/__app_root_template.mk` |

この先頭行は「この `makefile` はテンプレートの実体コピーであり、内容差分を持たせない」という識別子として扱います。

## 背景

makefw では、`app/<app_name>/makefile` 用の app 直下テンプレート (`__app_root_template.mk`) と、配下のビルド層・走査層用の統一テンプレート (`__template.mk`) を使い分けます。  
この方針により保守性は上がりますが、テンプレートを更新したあと、すでに配置済みの `makefile` は自動では追従しません。

Linux ではシンボリックリンクで吸収できる場合がありますが、Windows を含むワークスペースでは実体ファイル運用が必要です。  
そのため、テンプレートの実体コピーを一括で再同期するコマンドが必要になります。

## 動作

1. スクリプト自身の配置場所から上方向に `.workspaceRoot` を探し、ワークスペースルートを特定する。
2. 利用可能なテンプレート一覧を確認する。
3. ワークスペース配下の `makefile` を再帰的に列挙する。
4. 先頭行が既知のテンプレート識別子を持つファイルだけを同期候補として扱う。
5. 識別子と配置場所の組み合わせを検証し、整合する同期元テンプレートを選ぶ。
6. 内容が同一なら `[スキップ]`、差分があれば `--dry-run` 時は `[対象]`、通常実行時は上書きして `[更新]` を表示する。
7. 識別子に対して配置場所が不正な `makefile` はエラーとして報告し、更新しない。

## 使い方

```bash
# 更新対象の確認のみ
python framework/makefw/bin/update_template_makefiles.py --dry-run

# 実際に同期
python framework/makefw/bin/update_template_makefiles.py
```

## 適用対象と対象外

### 対象

- 対応する同期元テンプレートと常に同一であるべきテンプレート由来 `makefile`
- `app/<app_name>/makefile`
- `app/<app_name>/<subdir>/.../makefile`

### 対象外

- 先頭行にテンプレート識別子を持たない `makefile`
- `app/makefile`
- `makepart.mk` / `makechild.mk` / `makelocal.mk`

## 運用上の注意

- テンプレート由来 `makefile` に固有設定を直接書かないでください。差分は次回同期で失われます。
- 配下のビルド層・走査層の固有設定は `makepart.mk` / `makechild.mk` / `makelocal.mk` に移してください。
- app 直下テンプレートは `app/<app_name>/makefile` にのみ配置できます。
- まず `--dry-run` で対象を確認し、その後に通常実行する運用を推奨します。
