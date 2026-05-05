# AGENTS.md

## 重要事項

- 自動ステージング、コミット禁止。指示があるまでステージング、コミットは行わないこと。
- 思考の断片は英語でもよいが、ユーザーに気づきを与えたり報告する際は日本語を用いること。

## リポジトリ概要

C/C++ と .NET のビルドを支える Make テンプレート、補助スクリプト、運用ドキュメントをまとめた repo です。ルートで成果物を直接ビルドする repo ではなく、他のプロジェクトから利用されるテンプレート基盤です。

## 作業時の入口

- `makefiles/__template.mk` - 末端 makefile の共通テンプレート
- `makefiles/prepare.mk` - 事前処理と `makepart.mk` 読み込み
- `makefiles/makemain.mk` - パスと言語に基づくテンプレート自動選択
- `makefiles/makelibsrc_*.mk`, `makefiles/makesrc_*.mk` - ライブラリ / 実行体用テンプレート
- `bin/` - 補助スクリプト
- `docs/template-auto-selection.md` - 自動選択ルール
- `docs/makeparts.md` - `makepart.mk`、`makechild.mk`、`makelocal.mk` の役割

## 注意点

- パスに `/libsrc/` または `/src/` を含む前提や、`.csproj` の有無で切り替える前提を崩さないこと。
- `makepart.mk` 系の継承順序は互換性に直結するため、`prepare.mk` とドキュメントを合わせて確認すること。
- テンプレートと補助ファイルで拡張する方針を維持すること。
