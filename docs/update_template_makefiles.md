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
| `# makefile テンプレート` | `framework/makefw/makefiles/__template.mk` |
| `# makefile サブディレクトリ走査テンプレート` | `framework/makefw/makefiles/__subdir_template.mk` |

これらの先頭行は「この `makefile` はテンプレートの実体コピーであり、内容差分を持たせない」という識別子として扱います。

## 背景

makefw では、最終階層の `makefile` を統一テンプレートに寄せ、個別設定は `makepart.mk` へ分離します。  
また、`prod/test` 配下の中間階層走査 `makefile` も走査テンプレートに寄せ、ディレクトリ固有の `SUBDIRS` は `makelocal.mk` へ分離します。  
この方針により保守性は上がりますが、各テンプレートを更新したあと、既に配置済みの `makefile` は自動では追従しません。

Linux ではシンボリックリンクで吸収できる場合がありますが、Windows を含むワークスペースでは実体ファイル運用が必要です。  
そのため、テンプレートの実体コピーを一括で再同期するコマンドが必要になります。

## 動作

1. スクリプト自身の配置場所から上方向に `.workspaceRoot` を探し、ワークスペースルートを特定する。
2. 利用可能なテンプレート一覧を確認する。
3. ワークスペース配下の `makefile` を再帰的に列挙する。
4. 先頭行が既知のテンプレート識別子を持つファイルだけを同期候補として扱う。
5. 識別子に応じた同期元テンプレートを選ぶ。
6. 内容が同一なら `[スキップ]`、差分があれば `--dry-run` 時は `[対象]`、通常実行時は上書きして `[更新]` を表示する。

## 使い方

```bash
# 更新対象の確認のみ
python framework/makefw/bin/update_template_makefiles.py --dry-run

# 実際に同期
python framework/makefw/bin/update_template_makefiles.py
```

## 適用対象と対象外

### 対象

- 最終階層に置かれたテンプレート由来 `makefile`
- 中間階層に置かれた走査テンプレート由来 `makefile`
- 対応する同期元テンプレートと常に同一であるべき `makefile`

### 対象外

- 先頭行にテンプレート識別子を持たない `makefile`
- `makepart.mk` / `makechild.mk` / `makelocal.mk`

## 運用上の注意

- テンプレート由来 `makefile` に固有設定を直接書かないでください。差分は次回同期で失われます。
- 最終階層の固有設定は `makepart.mk` などに移してください。
- 走査 makefile の `SUBDIRS` 順序指定は `makelocal.mk` に移してください。
- まず `--dry-run` で対象を確認し、その後に通常実行する運用を推奨します。
