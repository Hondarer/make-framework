# make-framework

makefw は、C/C++ と .NET の app を階層的にビルドする GNU Make テンプレートを提供します。

makefw は 64 ビット環境専用です。  
32 ビット環境向けのビルド、互換処理、回避策は一切提供しません。

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

## 第三者ソースの公開シンボルを固有名へ変換します

`bin_internal/generate_symbol_namespace.py` は、配布元の識別子とライブラリ固有の接頭辞から、実装コンパイル用の内部対応ヘッダーと対応解除ヘッダーを生成します。  
公開シンボル一覧は 1 行 1 識別子、API 呼び出しマクロ一覧は `MACRO_NAME TARGET_API` の 2 列で記載し、空行と `#` コメントを使用できます。  
API 表の関数ポインターを呼ぶだけで実シンボルを持たないマクロは、対象 API に自身の名前を記載します。  
不正な識別子や重複を拒否し、出力内容が同じ場合は更新日時を維持します。

```sh
python3 framework/makefw/bin_internal/generate_symbol_namespace.py \
    --symbols prod/public_symbols.txt --api-macros prod/public_api_macros.txt \
    --prefix example_app_ \
    --namespace-header prod/include_internal/example_app_namespace.h \
    --undef-header prod/include_internal/example_app_undef.h
```

展開器からは `load_mapping()` で対応表を読み、`transform_public_header()` で配布ヘッダーの識別子を変換します。  
コメントと文字列リテラルは変換せず、構造体フィールドや外部モジュールの入口を対応表へ含めません。  
公開ヘッダーには固有名の宣言を提供し、旧名を受け付ける alias マクロを残さない構成にします。  
内部対応ヘッダーは第三者ソースの実装コンパイルにだけ使用してください。
