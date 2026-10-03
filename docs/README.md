# make-framework

C/C++ および .NET アプリケーションをビルドするための共通 Make テンプレートを提供するフレームワークです。

マルチ プラットフォーム (Linux / Windows) や複数のビルド構成、依存関係の自動解決、ソース配置に応じたテンプレート自動選択を支援します。

## 重要な文書

### ビルドの構成と設定

各 app のビルド構成や固有の設定を定義する際に参照します。

- [ビルド構成](build-configurations.md) - Debug や Release などのビルド構成と CRT リンク仕様
- [make ファイル断片](makeparts.md) - app 固有の設定を追加する makepart.mk の記述規則
- [サブフォルダーのコンパイル](subfolder-compilation.md) - 責務別サブディレクトリのコンパイル方式

### テンプレートと拡張

テンプレートの選択やカスタム処理を追加する際に参照します。

- [テンプレートの自動選択](template-auto-selection.md) - ソース配置や出力種別に応じたテンプレート選択規則
- [局所フック](hooks.md) - ビルド前後に実行するカスタム処理の定義方法

## 文書一覧

\toc depth=-1 exclude-basedir=true
