# fix_if_comments.py — C/C++ 条件分岐整形コマンド

## 概要

`fix_if_comments.py` は、C/C++ ソースコード中のプリプロセッサ条件分岐について、
`#else` / `#endif` コメントと Linux/Windows 二択分岐の書式を機械的に標準化する保守コマンドです。

本コマンドは **C/C++ 用** です。  
makefile の `ifdef` / `else ifdef` 整形は対象に含めません。

## 目的

深い条件分岐では、`#endif` がどの条件に対応するかを即座に読めることが重要です。  
また、クロスプラットフォームコードでは Linux と Windows の分岐条件を明示的に揃えておくと、保守時の判断ミスを減らせます。

このコマンドは、makefw ワークスペースで推奨する以下のルールを C/C++ 側へ適用します。

- `#else` コメントは「そのブロックで真になる条件」を書く
- `#endif` コメントは対応するマクロ名だけを書く
- Linux/Windows 二択分岐は `#else` ではなく `#elif defined(PLATFORM_WINDOWS)` に寄せる
- 複雑な条件式は安全側で変更しない

## 採用ルール

### `#ifdef` / `#ifndef`

```c
#ifndef MACRO
...
#else /* MACRO */
...
#endif /* MACRO */

#ifdef MACRO
...
#else /* !MACRO */
...
#endif /* MACRO */
```

### 単一マクロの `#if defined(MACRO)`

```c
#if defined(MACRO)
...
#else /* !MACRO */
...
#endif /* MACRO */
```

### 単純な `#if defined()` / `#elif defined()` チェーン

```c
#if defined(COMPILER_GCC)
...
#elif defined(COMPILER_CLANG)
...
#elif defined(COMPILER_MSVC)
...
#endif /* COMPILER_ */
```

`#else` がある場合は、チェーン内のすべての条件が偽であることを `!MACRO_A && !MACRO_B` の形で付与します。

### Linux/Windows 二択分岐

```c
#if defined(PLATFORM_LINUX)
...
#elif defined(PLATFORM_WINDOWS)
...
#endif /* PLATFORM_ */
```

Windows 側を暗黙の `#else` にせず、条件を明示します。

## 変更しないケース

- `#if EXPR` のような複雑な式
- 複合条件を含む `#elif`
- C/C++ 以外のファイル

複雑な条件は、意図を誤って壊さないことを優先して非変更とします。

## 対象ファイル

ディレクトリ指定時は次の拡張子を再帰処理します。

- `.c`
- `.h`
- `.cc`
- `.hpp`

## 使い方

```bash
# 差分確認のみ
python framework/makefw/bin/fix_if_comments.py --dry-run prod/porter

# 実際に適用
python framework/makefw/bin/fix_if_comments.py prod/porter

# 個別ファイル指定
python framework/makefw/bin/fix_if_comments.py src/foo.c include/bar.h
```

## makefw との関係

makefile 側の OS 分岐ルールは [make-platform-guideline.md](make-platform-guideline.md) に従います。  
`fix_if_comments.py` は、その C/C++ 側に相当する保守補助コマンドとして位置づけます。
