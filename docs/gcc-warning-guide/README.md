# gcc 警告オプション運用ガイド

## 目的

本ガイドは、gcc の警告を品質ゲートとして活用し、
EL8 (gcc8) と EL10 (gcc14) の両環境でビルドを破綻させずに
ロバストな C / C++ プログラミングを行うことを目的としています。

特に以下を重視しています。

- 移植時に顕在化しやすい未定義動作や API 設計ミスの早期検出
- コンパイラ世代差 (gcc8 ↔ gcc14) による警告増減への耐性
- メモリレイアウトをそのままファイル I/O に用いる要件への対応
  (暗黙パディング検出は必須です)

## 基本方針

- -Wall -Wextra を基礎とし、バグに直結しやすい警告のみを厳選して追加します
- C と C++ で意味の異なる警告は必ず分離します
- 警告を抑制するための指定 (=0, -Wno-*) は原則使いません
- gcc14 で warning → error に昇格した項目に依存しないコードを書きます

## 推奨警告セット

### Base 警告 (言語共通)

```text
-Wall -Wextra
-Wformat=2
-Wshadow
-Wundef
-Wpointer-arith
-Wcast-qual
-Wcast-align
-Wswitch-enum
-Wswitch-default
-Wpacked
-Wpadded
-Wunknown-pragmas
```

### C 専用警告

```text
-Wmissing-prototypes
-Wstrict-prototypes
-Wmissing-declarations
```

### makefile 例

```makefile
WARN_BASE = \
    -Wall -Wextra \
    -Wformat=2 \
    -Wshadow -Wundef \
    -Wpointer-arith -Wcast-qual -Wcast-align \
    -Wswitch-enum -Wswitch-default \
    -Wpacked -Wpadded \
    -Wunknown-pragmas

WARN_C_ONLY = \
    -Wmissing-prototypes \
    -Wstrict-prototypes \
    -Wmissing-declarations

CFLAGS   += $(WARN_BASE) $(WARN_C_ONLY)
CXXFLAGS += $(WARN_BASE)
```

## 構造体レイアウト固定 (I/O) に関する指針

- ファイル I/O 用構造体は用途専用に分離します
- フィールドは固定幅整数型のみを使用します
- sizeof と offsetof を static_assert で固定化します
- packed 構造体は memcpy 専用とし、直接アクセスを避けます

## 付録 A: 各警告の概要

- -Wall
  一般的に有用とされる基本警告群です。

- -Wextra
  -Wall に含まれない追加警告です。

- -Wformat=2
  printf 系フォーマット不整合を厳密に検出します。

- -Wshadow
  変数の意図しない隠蔽を検出します。

- -Wundef
  未定義マクロ使用を検出します。

- -Wpointer-arith
  非標準なポインタ演算を検出します。

- -Wcast-qual
  const / volatile 除去キャストを検出します。

- -Wcast-align
  アラインメント破壊の可能性を検出します。

- -Wswitch-enum
  enum の未処理列挙子を検出します。

- -Wswitch-default
  default 節の無い switch を検出します。

- -Wpacked
  packed 指定による危険なレイアウトを検出します。

- -Wpadded
  暗黙パディングの発生を検出します。

- -Wunknown-pragmas
  未対応 pragma を検出します。

- -Wmissing-prototypes (C)
  非 static 関数の未宣言を検出します。

- -Wstrict-prototypes (C)
  古い関数宣言形式を検出します。

- -Wmissing-declarations (C)
  ヘッダ未宣言のグローバル関数を検出します。
