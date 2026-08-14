# make-framework

makefw は、C/C++ と .NET の app を階層的にビルドする GNU Make テンプレートを提供します。

## 主要な入口

- [作業規則](AGENTS.md)
- [文書一覧](docs/README.md)
- [make ファイル断片](docs/makeparts.md)
- [テンプレートの選択](docs/template-auto-selection.md)
- [フック](docs/hooks.md)
- [ビルド構成](docs/build-configurations.md)

## 利用方法

各 app の小文字 `makefile` から、`makefiles/` 配下のテンプレートを読み込みます。  
app 固有の値は `makepart.mk`、子孫への設定は `makechild.mk`、局所フックは `makelocal.mk` に記載します。

テンプレートから配置済み makefile を更新する場合は、[更新手順](docs/update_template_makefiles.md) に従ってください。
