# gcc 警告オプション運用ガイド  
EL8 (gcc8) / EL10 (gcc14) 共通

## 目的

本ガイドは、gcc の警告を品質ゲートとして活用し、  
EL8 (gcc8) と EL10 (gcc14) の両環境でビルドを破綻させずに  
ロバストな C / C++ プログラミングを行うことを目的とする。

特に以下を重視する。

- 移植時に顕在化しやすい未定義動作や API 設計ミスの早期検出  
- コンパイラ世代差 (gcc8 ↔ gcc14) による警告増減への耐性  
- メモリレイアウトをそのままファイル I/O に用いる要件への対応  
  (暗黙パディング検出は必須)

## 基本方針

- -Wall -Wextra を基礎とし、バグに直結しやすい警告のみを厳選して追加する  
- C と C++ で意味の異なる警告は必ず分離する  
- 警告を抑制するための指定 (=0, -Wno-*) は原則使わない  
- gcc14 で warning → error に昇格した項目に依存しないコードを書く  

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

### Makefile 例

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

- ファイル I/O 用構造体は用途専用に分離する  
- フィールドは固定幅整数型のみを使用する  
- sizeof と offsetof を static_assert で固定化する  
- packed 構造体は memcpy 専用とし、直接アクセスを避ける  

## 付録 A: 各警告の概要

- -Wall  
  一般的に有用とされる基本警告群。

- -Wextra  
  -Wall に含まれない追加警告。

- -Wformat=2  
  printf 系フォーマット不整合を厳密に検出。

- -Wshadow  
  変数の意図しない隠蔽を検出。

- -Wundef  
  未定義マクロ使用を検出。

- -Wpointer-arith  
  非標準なポインタ演算を検出。

- -Wcast-qual  
  const / volatile 除去キャストを検出。

- -Wcast-align  
  アラインメント破壊の可能性を検出。

- -Wswitch-enum  
  enum の未処理列挙子を検出。

- -Wswitch-default  
  default 節の無い switch を検出。

- -Wpacked  
  packed 指定による危険なレイアウトを検出。

- -Wpadded  
  暗黙パディングの発生を検出。

- -Wunknown-pragmas  
  未対応 pragma を検出。

- -Wmissing-prototypes (C)  
  非 static 関数の未宣言を検出。

- -Wstrict-prototypes (C)  
  古い関数宣言形式を検出。

- -Wmissing-declarations (C)  
  ヘッダ未宣言のグローバル関数を検出。
