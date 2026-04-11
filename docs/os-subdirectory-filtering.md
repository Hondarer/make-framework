# サブディレクトリの OS フィルタリング

本ドキュメントでは、makemain.mk におけるサブディレクトリの OS フィルタリング機能について説明します。

## 概要

makemain.mk では、サブディレクトリの再帰的 make 処理に先立ち、ディレクトリ名に基づく OS フィルタリングを行います。これにより、プラットフォーム固有のコードをディレクトリ単位で分離できます。

## フィルタルール

サブディレクトリの **最終ディレクトリ名** (大文字小文字を無視) に基づいて、以下のルールで判定します。

| 最終ディレクトリ名 | Linux | Windows | 説明 |
|---|:---:|:---:|---|
| `linux` | 有効 | 除外 | Linux 固有のコード |
| `windows` | 除外 | 有効 | Windows 固有のコード |
| `shared` | 有効 | 有効 | 両 OS 共通コード (明示的) |
| その他 | 有効 | 有効 | デフォルト動作 |

- `shared` とその他は動作上同じですが、`shared` はクロスプラットフォームであることを明示する意図で使用します。
- 大文字小文字を無視するため、`Linux`、`LINUX`、`linux` はすべて同一視されます。

## ディレクトリ構成例

```text
prod/calc/src/calcapp/
+-- makefile
+-- shared/          # 両 OS で有効 (明示的)
|   +-- makefile
|   +-- common.c
+-- linux/           # Linux でのみ有効
|   +-- makefile
|   +-- platform_linux.c
+-- windows/         # Windows でのみ有効
|   +-- makefile
|   +-- platform_windows.c
+-- utils/           # 両 OS で有効 (デフォルト)
    +-- makefile
    +-- helper.c
```

### Linux での実行結果

```text
SUBDIRS = linux/ shared/ utils/
# windows/ は除外される
```

### Windows での実行結果

```text
SUBDIRS = shared/ utils/ windows/
# linux/ は除外される
```

## 複数階層での動作

サブディレクトリが複数階層にまたがる場合、各階層で個別にフィルタリングが適用されます。最終ディレクトリ名のみで判定されるため、中間階層の名前は影響しません。

```text
prod/calc/src/calcapp/
+-- platform/           # "platform" → 両 OS で有効
    +-- makefile
    +-- linux/           # "linux" → Linux でのみ有効
    |   +-- makefile
    |   +-- impl_linux.c
    +-- windows/         # "windows" → Windows でのみ有効
        +-- makefile
        +-- impl_windows.c
```

この場合、`calcapp/` レベルでは `platform/` が両 OS で有効となり、`platform/` 内で再帰的に make が実行される際に `linux/` または `windows/` がフィルタリングされます。
