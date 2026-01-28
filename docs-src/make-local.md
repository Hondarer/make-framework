# makelocal.mk 仕様

## 概要

`makelocal.mk` は、自ディレクトリに限定される設定ファイルです。`makepart.mk` の階層継承とは異なり、定義した内容は子階層に継承されません。

## 背景

`makepart.mk` は `prepare.mk` によりプロジェクトルートから階層を下って順次インクルードされます。
この設計により、親階層で定義した設定 (`LIBS`, `LIBSDIR`, `CFLAGS` など) が子階層に継承されます。

```
prod/
+-- makepart.mk          # LIBS += baselib (子階層すべてに継承)
+-- myapp/
    +-- makepart.mk      # OUTPUT_DIR = ... (子階層すべてに継承)
    +-- libsrc/
        +-- mylib/
            +-- Makefile # 上記すべての設定が有効
```

しかし、特定のディレクトリのみに適用したい設定 (フック、ローカルフラグなど) を `makepart.mk` に定義すると、そのディレクトリ以下のすべてのサブフォルダでも有効になってしまいます。  
このような場合は `makelocal.mk` を使用します。

## ファイルの役割分担

| ファイル | スコープ | 用途 |
|---------|---------|------|
| `makepart.mk` | 階層継承 (親->子に伝播) | `LIBS`, `LIBSDIR`, `CFLAGS`, `OUTPUT_DIR` など共通設定 |
| `makelocal.mk` | 自ディレクトリ限定 | フックターゲット、ローカルフラグ、ディレクトリ固有設定 |

## インクルード順序

```
1. prepare.mk
   +-- makepart.mk (親階層から順にインクルード、継承)
   +-- makelocal.mk (自ディレクトリのみ、継承なし)

2. makemain.mk
   +-- テンプレート (makelibsrc_c_cpp.mk など)
```

`prepare.mk` は各ディレクトリの Makefile から include されるため、`prepare.mk` の最後で `makelocal.mk` を読み込みます。

## 実装

### prepare.mk での読み込み処理

`prepare.mk` の最後に以下を行います。

```makefile
# makelocal.mk の読み込み (カレントディレクトリのみ)
# prepare.mk は各ディレクトリの Makefile から include されるため、
# ここでカレントディレクトリの makelocal.mk を読み込めばよい
-include $(CURDIR)/makelocal.mk
```

- `-include` を使用することで、ファイルが存在しない場合もエラーにならない
- `$(CURDIR)` はカレントディレクトリを指すため、継承は発生しない

### 実装のメリット

`makelocal.mk` の読み込みを `prepare.mk` で行うことにより、以下のメリットがあります。

1. **テンプレートを汚さない**: 各テンプレートファイル (makelibsrc_c_cpp.mk 等) に個別の処理を追加する必要がない
2. **一貫性**: すべてのビルドタイプ (C/C++, .NET) で同じ動作

## 使用例

### 例1: makepart.mk と makelocal.mk の併用

```makefile
# prod/myapp/libsrc/makepart.mk
# 子階層にも継承される設定
LIBS += mybaselib
CFLAGS += -DMYAPP_VERSION=\"1.0.0\"
```

```makefile
# prod/myapp/libsrc/mylib/makelocal.mk
# このディレクトリのみに適用される設定
MY_LOCAL_FLAG := 1
```

### 例2: ディレクトリ固有の変数設定

```makefile
# prod/myapp/src/myapp/makelocal.mk
# このディレクトリのみに適用
EXTRA_LDFLAGS := -lspeciallib
```

### 例3: フックターゲットの定義 (別途フック機能が必要)

```makefile
# prod/myapp/libsrc/generated/makelocal.mk
.PHONY: pre-build
pre-build:
    @echo "Generating code..."
    python $(WORKSPACE_FOLDER)/tools/codegen.py
```

## 配置の指針

| 設定項目 | 配置先 | 理由 |
|---------|--------|------|
| `LIBS`, `LIBSDIR` | makepart.mk | 子階層にも継承させたい |
| `CFLAGS`, `CXXFLAGS` | makepart.mk | 共通のコンパイルオプション |
| `OUTPUT_DIR` | makepart.mk | 出力先の統一 |
| フックターゲット | makelocal.mk | 自ディレクトリのみに限定 |
| ローカル変数 | makelocal.mk | 継承させたくない設定 |
