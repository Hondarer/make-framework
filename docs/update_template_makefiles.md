# update_template_makefiles.py — makefw 保守コマンド

## 概要

`update_template_makefiles.py` は、makefw の統一テンプレート `__template.mk` から生成・配置した
最終階層 `makefile` を、最新テンプレート内容へ一括同期する保守コマンドです。

対象は `.workspaceRoot` を持つ makefw ワークスペース全体です。  
手書きの `makefile` や `SUBDIRS` 形式の中間ディレクトリ `makefile` は変更しません。

## 何を同期するか

同期元は `framework/makefw/makefiles/__template.mk` です。

同期対象は、ワークスペース内の `makefile` のうち、**先頭行が `# makefile テンプレート` で始まるもの**です。

この先頭行は「この `makefile` はテンプレートの実体コピーであり、内容差分を持たせない」という識別子として扱います。

## 背景

makefw では、最終階層の `makefile` を統一テンプレートに寄せ、個別設定は `makepart.mk` へ分離します。
この方針により保守性は上がりますが、`__template.mk` を更新したあと、既に配置済みの各 `makefile` は自動では追従しません。

Linux ではシンボリックリンクで吸収できる場合がありますが、Windows を含むワークスペースでは実体ファイル運用が必要です。  
そのため、テンプレートの実体コピーを一括で再同期するコマンドが必要になります。

## 動作

1. スクリプト自身の配置場所から上方向に `.workspaceRoot` を探し、ワークスペースルートを特定する。
2. `framework/makefw/makefiles/__template.mk` を読み込む。
3. ワークスペース配下の `makefile` を再帰的に列挙する。
4. 先頭行が `# makefile テンプレート` のファイルだけを同期候補として扱う。
5. 内容が同一なら `[スキップ]`、差分があれば `--dry-run` 時は `[対象]`、通常実行時は上書きして `[更新]` を表示する。

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
- `framework/makefw/makefiles/__template.mk` と常に同一であるべき `makefile`

### 対象外

- `SUBDIRS` ベースの手書き `makefile`
- 先頭行にテンプレート識別子を持たない `makefile`
- `makepart.mk` / `makechild.mk` / `makelocal.mk`

## 運用上の注意

- 最終階層 `makefile` に固有設定を直接書かないでください。差分は次回同期で失われます。
- 固有設定は `makepart.mk` などに移してください。
- まず `--dry-run` で対象を確認し、その後に通常実行する運用を推奨します。
