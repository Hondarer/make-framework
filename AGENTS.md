# AGENTS.md

## リポジトリ概要

C/C++ と .NET のビルドを支える Make テンプレート、補助スクリプト、運用ドキュメントをまとめたリポジトリです。ルートで成果物を直接ビルドせず、他のプロジェクトから利用されるテンプレート基盤です。

## 必須参照

- [README.md](README.md)
- [文書一覧](docs/README.md)

## 作業時の入口

- `makefiles/__template.mk` - 末端 makefile の共通テンプレート
- `makefiles/__each_app_template.mk` - `app/<app_name>/makefile` 用テンプレート
- `makefiles/__app_template.mk` - `app/makefile` 用テンプレート
- `makefiles/prepare.mk` - 事前処理と `makepart.mk` 読み込み
- `makefiles/makemain.mk` - パスと言語に基づくテンプレート自動選択
- `makefiles/makelibsrc_*.mk`, `makefiles/makesrc_*.mk` - ライブラリ / 実行体用テンプレート
- `bin/update_template_makefiles.py` - テンプレート由来の makefile を最新版に同期するスクリプト
- `bin/` - その他の補助スクリプト
- `docs/template-auto-selection.md` - 自動選択ルール
- `docs/makeparts.md` - `makepart.mk`、`makechild.mk`、`makelocal.mk` の役割
- `docs/hooks.md` - `makelocal.mk` の pre/post フック
- `docs/library-search-paths.md` - Linux の `-L` / `-rpath-link` / `-rpath` の使い分け

## 注意点

- パスに `/libsrc/` または `/src/` を含む前提や、`.csproj` の有無で切り替える前提を維持してください。
- Linux で `LIBSDIR` を `LDFLAGS` へ展開するときは、`-L` と `-rpath-link` を対で与えること。  
  `-L` は間接依存 (`DT_NEEDED`) の探索に使われず、リンクの成否が `LD_LIBRARY_PATH` に依存するため。  
  see: `docs/library-search-paths.md`
- `makepart.mk` 系の継承順序は互換性に直結するため、`prepare.mk` とドキュメントを合わせて確認してください。
- テンプレートと補助ファイルで拡張する方針を維持してください。
- `bin/` 配下の Python スクリプトで日本語を出力するときは、モジュール レベル (関数定義より前) に  
  以下を追加して stdout/stderr を UTF-8 に固定してください。  
  Windows のデフォルト `sys.stdout.encoding` は `cp932` であり、出力が文字化けします。

  ```python
  sys.stdout.reconfigure(encoding="utf-8")
  sys.stderr.reconfigure(encoding="utf-8")
  ```
