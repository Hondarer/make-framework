# C 言語サブディレクトリ対応の詳細と実装ガイド

## 概要

この文書は、makefw を使用して C 言語ソース コードをサブディレクトリへ配置する方法を説明します。

大規模な C 言語プロジェクトでは、ソース コードを機能別にサブディレクトリに分割することが一般的です。  
本フレームワークは、以下の観点からサブディレクトリ対応を提供します。

1. **ライブラリ**: サブディレクトリに配置したソース ファイルを単一のライブラリにリンク
2. **コマンド (実行ファイル)**: サブディレクトリに配置したソース ファイルを単一の実行ファイルにリンク
3. **テスト**: サブディレクトリごとのテスト コードとテスト対象ソースの管理

## サブディレクトリ対応の仕様

### NO_LINK 変数

```makefile
# サブフォルダーはコンパイルのみ
NO_LINK = 1
```

**動作:**

- `NO_LINK = 1` を設定したディレクトリでは、ソース ファイルのコンパイルのみが行われます
- リンク処理 (ライブラリ生成や実行ファイル生成) はスキップされます
- コンパイル結果のオブジェクト ファイル (`.o` / `.obj`) は、各サブディレクトリの `obj/` に配置されます

**配置先:**

`NO_LINK = 1` は、リンクを行う起点ディレクトリの `makechild.mk` に定義します。  
`makechild.mk` は自ディレクトリには適用されず子階層以降にのみ有効であるため、起点ディレクトリでは通常のリンクが行われ、すべてのサブディレクトリではコンパイルのみが実行されます。

```makefile
# libhierarchy-example/makechild.mk (起点ディレクトリ)
# サブフォルダーはコンパイルのみ
NO_LINK = 1
```

これにより、各サブディレクトリに個別の `makepart.mk` で `NO_LINK = 1` を定義する必要がなくなります。

### オブジェクト ファイルの自動収集

親ディレクトリ (リンクを行うディレクトリ) では、サブディレクトリのオブジェクト ファイルが自動的に収集されます。

**makelibsrc_c_cpp.mk / makesrc_c_cpp.mk より:**

```makefile
# サブディレクトリの obj ディレクトリを再帰的に検索して、オブジェクト ファイルを収集
ifeq ($(OS),Windows_NT)
    SUBDIR_OBJS := $(shell find . -type d -name obj -not -path "./obj" -exec find {} -maxdepth 1 -type f -name "*.obj" \; 2>/dev/null)
else
    SUBDIR_OBJS := $(shell find . -type d -name obj -not -path "./obj" -exec find {} -maxdepth 1 -type f -name "*.o" \; 2>/dev/null)
endif
OBJS += $(SUBDIR_OBJS)
```

これにより、親ディレクトリでリンクを実行すると、サブディレクトリのオブジェクト ファイルも含めてリンクされます。

### 再帰的 make 処理

`makemain.mk` は、makefile を含むサブディレクトリを自動検出し、再帰的に make を実行します。

```makefile
# サブディレクトリの検出 (GNUmakefile/makefile/Makefile を含むディレクトリのみ)
# makelocal.mk で SUBDIRS を上書きした場合はその設定を尊重する
SUBDIRS ?= $(sort $(dir $(wildcard */GNUmakefile */makefile */Makefile)))

# サブディレクトリの再帰的 make 処理
ifneq ($(SUBDIRS),)
    .PHONY: $(SUBDIRS)
    $(SUBDIRS):
	@if [ -n "$(MAKECMDGOALS)" ]; then \
		$(MAKE) -C $@ $(MAKECMDGOALS); \
	else \
		$(MAKE) -C $@; \
	fi

    # 主要なターゲットにサブディレクトリ依存を追加 (サブディレクトリを先に処理)
    default build clean test run restore rebuild: $(SUBDIRS)
endif
```

## ライブラリのサブディレクトリ対応

### ディレクトリ構造

```text
app/hierarchy-example/prod/
+-- lib/                                    # ビルド済みライブラリ出力先
|   +-- liblibhierarchy-example.so
+-- libsrc/
    +-- makefile                            # 再帰ビルド用
    +-- makepart.mk
    +-- libhierarchy-example/
        +-- makefile                        # ライブラリ本体 (リンク実行)
        +-- makepart.mk                     # LIB_TYPE = shared 設定
        +-- makechild.mk                    # NO_LINK = 1 (サブフォルダはコンパイルのみ)
        +-- func.c                          # ルートのソースファイル
        +-- obj/
        |   +-- func.o
        +-- subfolder_a/
        |   +-- makefile                    # サブディレクトリ (makechild.mk により NO_LINK 適用)
        |   +-- func_a.c
        |   +-- obj/
        |       +-- func_a.o
        +-- subfolder_b/
            +-- makefile                    # サブディレクトリ (makechild.mk により NO_LINK 適用)
            +-- func_b.c
            +-- obj/
                +-- func_b.o
```

### 設定ファイルの内容

**libhierarchy-example/makepart.mk (起点ディレクトリ):**

```makefile
ifeq ($(OS),Windows_NT)
    # Windows
    CFLAGS   += /DSUBFOLDER_SAMPLE_EXPORTS
    CXXFLAGS += /DSUBFOLDER_SAMPLE_EXPORTS
endif

# 動的ライブラリとして生成
LIB_TYPE = shared
```

**libhierarchy-example/makechild.mk (起点ディレクトリ):**

```makefile
# サブフォルダーはコンパイルのみ
NO_LINK = 1
```

`makechild.mk` は自ディレクトリには適用されないため、`libhierarchy-example/` ではリンクが実行され、サブディレクトリ (`subfolder_a/`, `subfolder_b/`) ではコンパイルのみが行われます。

### ビルドの流れ

1. `make` を `libhierarchy-example/` で実行
2. `makemain.mk` がサブディレクトリ `subfolder_a/` と `subfolder_b/` を検出
3. 各サブディレクトリで `make` が再帰的に実行される
4. サブディレクトリでは `NO_LINK = 1` によりコンパイルのみ実行
5. 親ディレクトリで全オブジェクト ファイルを収集してライブラリを生成

**生成されるライブラリ:**

```text
app/hierarchy-example/prod/lib/liblibhierarchy-example.so
```

このライブラリには、`func.o`、`func_a.o`、`func_b.o` が含まれます。

## コマンド (実行ファイル) のサブディレクトリ対応

### ディレクトリ構造

```text
app/hierarchy-example/prod/
+-- bin/                                    # ビルド済み実行ファイル出力先
|   +-- sample-app
+-- src/
    +-- makefile                            # 再帰ビルド用
    +-- makepart.mk
    +-- sample-app/
        +-- makefile                        # 実行ファイル本体 (リンク実行)
        +-- makechild.mk                    # NO_LINK = 1 (サブフォルダはコンパイルのみ)
        +-- sample-app.h                    # ヘッダーファイル
        +-- main.c                          # メインソースファイル
        +-- obj/
        |   +-- main.o
        +-- subfolder_a/
        |   +-- makefile                    # サブディレクトリ (makechild.mk により NO_LINK 適用)
        |   +-- helper_a.c
        |   +-- obj/
        |       +-- helper_a.o
        +-- subfolder_b/
            +-- makefile                    # サブディレクトリ (makechild.mk により NO_LINK 適用)
            +-- helper_b.c
            +-- obj/
                +-- helper_b.o
```

### ソース コードの例

**main.c:**

```c
#include <stdio.h>
#include "sample-app.h"

int main(void)
{
    int a = 10;
    int b = 20;

    printf("Testing subfolder make for src\n");
    printf("helper_a(%d) = %d\n", a, helper_a(a));
    printf("helper_b(%d) = %d\n", b, helper_b(b));
    printf("helper_a(%d) + helper_b(%d) = %d\n", a, b, helper_a(a) + helper_b(b));

    return 0;
}
```

**subfolder_a/helper_a.c:**

```c
#include "../sample-app.h"

int helper_a(int value)
{
    return value * 2;
}
```

### 設定ファイルの内容

**sample-app/makechild.mk (起点ディレクトリ):**

```makefile
# サブフォルダーはコンパイルのみ
NO_LINK = 1
```

ライブラリの場合と同様に、起点ディレクトリの `makechild.mk` で `NO_LINK = 1` を定義します。

### ビルドの流れ

ライブラリと同様に、サブディレクトリのオブジェクト ファイルが親ディレクトリに収集されてリンクされます。

**生成される実行ファイル:**

```text
app/hierarchy-example/prod/cbin/sample-app
```

## テストのサブディレクトリ対応

### ディレクトリ構造

```text
app/hierarchy-example/test/src/
+-- makefile                                # 再帰ビルド用
+-- hierarchy-exampleTest/
    +-- makefile                            # テスト本体 (リンク・テスト実行)
    +-- makepart.mk                         # TEST_SRCS 設定 (ルートのテスト対象)
    +-- makechild.mk                        # NO_LINK = 1 (サブフォルダはコンパイルのみ)
    +-- hierarchy-exampleTest.cc             # ルートのテストコード
    +-- bin/
    |   +-- hierarchy-exampleTest            # テスト実行ファイル
    +-- obj/
    |   +-- func.o                          # テスト対象ソースのオブジェクト
    |   +-- hierarchy-exampleTest.o          # テストコードのオブジェクト
    +-- results/                            # テスト結果出力先
    |   +-- all_tests/                      # 全体テスト結果
    |   |   +-- summary.log
    |   |   +-- coverage.xml
    |   |   +-- func.c.gcov.txt
    |   |   +-- func_a.c.gcov.txt
    |   |   +-- func_b.c.gcov.txt
    |   +-- subfolder_sampleTest.test_func/
    |   |   +-- results.log
    |   |   +-- func.c.gcov.txt
    |   +-- subfolder_sampleTest_a.test_func_a/
    |   |   +-- results.log
    |   |   +-- func_a.c.gcov.txt
    |   +-- subfolder_sampleTest_b.test_func_b/
    |       +-- results.log
    |       +-- func_b.c.gcov.txt
    +-- subfolder_a/
    |   +-- makefile                        # サブディレクトリ (makechild.mk により NO_LINK 適用)
    |   +-- makelocal.mk                    # TEST_SRCS 設定 (サブディレクトリのテスト対象)
    |   +-- hierarchy-exampleTest_a.cc       # サブディレクトリのテストコード
    |   +-- obj/
    |       +-- func_a.o
    |       +-- hierarchy-exampleTest_a.o
    +-- subfolder_b/
        +-- makefile                        # サブディレクトリ (makechild.mk により NO_LINK 適用)
        +-- makelocal.mk                    # TEST_SRCS 設定 (サブディレクトリのテスト対象)
        +-- hierarchy-exampleTest_b.cc       # サブディレクトリのテストコード
        +-- obj/
            +-- func_b.o
            +-- hierarchy-exampleTest_b.o
```

### 設定ファイルの内容

**hierarchy-exampleTest/makepart.mk (起点ディレクトリ):**

```makefile
# テスト対象のソース ファイル
TEST_SRCS := \
	$(MYAPP_DIR)/prod/libsrc/libhierarchy-example/func.c
```

**hierarchy-exampleTest/makechild.mk (起点ディレクトリ):**

```makefile
# サブフォルダーはコンパイルのみ
NO_LINK = 1
```

**subfolder_a/makelocal.mk (サブディレクトリ):**

```makefile
# テスト対象のソース ファイル
# NOTE: 上位フォルダーで TEST_SRCS を指定している場合、テスト対象ソースが重複しないように留意すること。
TEST_SRCS := \
	$(MYAPP_DIR)/prod/libsrc/libhierarchy-example/subfolder_a/func_a.c
```

テストでは、`NO_LINK = 1` は起点ディレクトリの `makechild.mk` に、`TEST_SRCS` は各サブディレクトリの `makelocal.mk` にそれぞれ分離して定義します。  
`TEST_SRCS` を `makelocal.mk` に配置することで、各テスト対象の指定が自ディレクトリに限定され、親階層に継承されません。

### テスト コードの例

**hierarchy-exampleTest.cc (親ディレクトリ):**

```cpp
#include <testfw.h>
#include <hierarchy-example.h>

class subfolder_sampleTest : public Test
{
};

TEST_F(subfolder_sampleTest, test_func)
{
    // Act
    int rtc = func(); // [手順] - func() を呼び出す。

    // Assert
    EXPECT_EQ(0, rtc); // [確認] - func() から 0 が返されること。
}
```

**subfolder_a/hierarchy-exampleTest_a.cc (サブディレクトリ):**

```cpp
#include <testfw.h>
#include <hierarchy-example.h>

class subfolder_sampleTest_a : public Test
{
};

TEST_F(subfolder_sampleTest_a, test_func_a)
{
    // Act
    int rtc = func_a(); // [手順] - func_a() を呼び出す。

    // Assert
    EXPECT_EQ(1, rtc); // [確認] - func_a() から 1 が返されること。
}
```

### TEST_SRCS の自動収集

テスト実行スクリプト (`exec_test_c_cpp.sh`) は、サブディレクトリの `makepart.mk` から `TEST_SRCS` を自動的に収集します。

```bash
# TEST_SRCS が空の場合、サブフォルダーの makepart.mk から TEST_SRCS を収集
if [ -z "$TEST_SRCS" ]; then
    for makepart in $(find . -mindepth 2 -name "makepart.mk" 2>/dev/null); do
        subdir_test_srcs=$(grep -A10 "^TEST_SRCS" "$makepart" 2>/dev/null | \
            grep -v "^TEST_SRCS" | grep -v "^#" | grep -v "^--$" | \
            sed "s|\\\$(WORKSPACE_DIR)|$WORKSPACE_DIR|g" | \
            xargs 2>/dev/null)
        TEST_SRCS="$TEST_SRCS $subdir_test_srcs"
    done
fi
```

これにより、各サブディレクトリで個別にテスト対象を指定しつつ、全体のカバレッジ レポートを生成できます。

## テスト レポートの構造

`make test` を実行すると、`results/` ディレクトリにテスト レポートが生成されます。

### results/ ディレクトリ構造

```text
results/
+-- all_tests/                              # 全体テスト結果
|   +-- summary.log                         # テストサマリー
|   +-- coverage.xml                        # 全体カバレッジ (Cobertura形式)
|   +-- func.c.gcov.txt                     # func.c のカバレッジ詳細
|   +-- func_a.c.gcov.txt                   # func_a.c のカバレッジ詳細
|   +-- func_b.c.gcov.txt                   # func_b.c のカバレッジ詳細
|   +-- lcov/                               # HTML カバレッジレポート (Linux)
+-- <テストクラス>.<テスト名>/              # 個別テスト結果
    +-- results.log                         # テスト実行ログ
    +-- <ソースファイル>.gcov.txt           # 個別テストのカバレッジ
```

### summary.log の内容例

```text
Test start on Sat Jan 24 07:55:31 JST 2026.
----
MD5 checksums of files in TEST_SRCS:
8c18e38566df7a9630b40ca18881a5d4  app/hierarchy-example/prod/libsrc/libhierarchy-example/func.c
----
subfolder_sampleTest_a.test_func_a	PASSED
subfolder_sampleTest_b.test_func_b	PASSED
subfolder_sampleTest.test_func	PASSED
Test results:
----
Total tests	3
Passed		3
Warning(s)	0
Failed		0

------------------------------------------------------------------------------
                             Code Coverage Report
------------------------------------------------------------------------------
File                                       Lines    Exec  Cover   Missing
------------------------------------------------------------------------------
func.c                                         2       2   100%
func_a.c                                       2       2   100%
func_b.c                                       2       2   100%
------------------------------------------------------------------------------
TOTAL                                          6       6   100%
------------------------------------------------------------------------------
```

### 個別テスト結果 (results.log) の内容例

```text
Running test: subfolder_sampleTest.test_func on bin/hierarchy-exampleTest
----
## テスト項目

### 状態

### 手順

- func() を呼び出す。

### 確認内容 (1)

- func() から 0 が返されること。
----
TEST_F(subfolder_sampleTest, test_func)
{
    // Arrange

    // Pre-Assert

    // Act
    int rtc = func(); // [手順] - func() を呼び出す。

    // Assert
    EXPECT_EQ(0, rtc); // [確認] - func() から 0 が返されること。
}
----
./bin/hierarchy-exampleTest --gtest_filter=subfolder_sampleTest.test_func
Running main() from .../gtest_main.cc
[==========] Running 1 test from 1 test suite.
[----------] Global test environment set-up.
[----------] 1 test from subfolder_sampleTest
[ RUN      ] subfolder_sampleTest.test_func
[       OK ] subfolder_sampleTest.test_func (0 ms)
[----------] 1 test from subfolder_sampleTest (0 ms total)

[----------] Global test environment tear-down
[==========] 1 test from 1 test suite ran. (0 ms total)
[  PASSED  ] 1 test.
```

### カバレッジ ファイル (*.gcov.txt) の内容例

```text
        -:    0:Source:func.c
        -:    0:Graph:.../obj/func.gcno
        -:    0:Data:.../obj/func.gcda
        -:    0:Runs:1
        -:    0:Programs:1
        -:    1:#include <hierarchy-example.h>
        -:    2:
        1:    3:SUBFOLDER_SAMPLE_API int WINAPI func(void)
        -:    4:{
        1:    5:    return 0;
        -:    6:}
```

各行の先頭の数字は実行回数を示します:

- `-`: 実行対象外の行 (コメント、空行など)
- `1` 以上: 実行された回数

## サブディレクトリ対応のベスト プラクティス

### makefile の配置

各サブディレクトリに makefile を配置します。内容は標準テンプレートをそのまま使用します。

```makefile
# makefile テンプレート
# すべての最終階層 makefile で使用する標準テンプレート
# 本ファイルの編集は禁止する。makepart.mk を作成して拡張・カスタマイズすること。

find-up = \
    $(if $(wildcard $(1)/$(2)),$(1),\
        $(if $(filter $(1),$(patsubst %/,%,$(dir $(1)))),,\
            $(call find-up,$(patsubst %/,%,$(dir $(1))),$(2))\
        )\
    )

ifeq ($(origin MAKEFW_WORKSPACE_DIR), undefined)
    MAKEFW_WORKSPACE_DIR := $(strip $(call find-up,$(CURDIR),.workspaceRoot))
endif
export MAKEFW_WORKSPACE_DIR

WORKSPACE_DIR := $(MAKEFW_WORKSPACE_DIR)

include $(WORKSPACE_DIR)/framework/makefw/makefiles/prepare.mk

include $(WORKSPACE_DIR)/framework/makefw/makefiles/makemain.mk
```

### makechild.mk での NO_LINK 設定

リンクを行う起点ディレクトリに `makechild.mk` を配置し、`NO_LINK = 1` を定義します。  
これにより、すべてのサブディレクトリに自動的に適用されます。

```makefile
# 起点ディレクトリの makechild.mk
# サブフォルダーはコンパイルのみ
NO_LINK = 1
```

テストの場合は、各サブディレクトリの `makelocal.mk` で `TEST_SRCS` を設定します。

```makefile
# サブディレクトリの makelocal.mk
# テスト対象のソース ファイル
TEST_SRCS := \
	$(MYAPP_DIR)/prod/libsrc/.../subfolder_a/func_a.c
```

### TEST_SRCS の重複回避

テストでは、親ディレクトリとサブディレクトリで `TEST_SRCS` が重複しないように注意してください。重複すると、同じソース ファイルが複数回コンパイルされ、リンク エラーが発生します。

### ヘッダー ファイルの参照

サブディレクトリから親ディレクトリのヘッダー ファイルを参照する場合は、相対パスを使用します。

```c
#include "../sample-app.h"
```

または、`makepart.mk` で `INCDIR` を設定します。

```makefile
INCDIR += $(MYAPP_DIR)/prod/src/sample-app
```

## まとめ

| 観点 | 設定ファイル | 設定 | 説明 |
|------|------------|------|------|
| ライブラリ | 起点の `makechild.mk` | `NO_LINK = 1` | サブディレクトリではコンパイルのみ、起点でリンク |
| コマンド | 起点の `makechild.mk` | `NO_LINK = 1` | サブディレクトリではコンパイルのみ、起点でリンク |
| テスト | 起点の `makechild.mk` | `NO_LINK = 1` | サブディレクトリではコンパイルのみ、起点でリンク |
| テスト | 各サブの `makelocal.mk` | `TEST_SRCS` | サブディレクトリごとにテスト対象を指定 |
| テスト レポート | - | `results/` | 個別テスト結果と全体カバレッジを出力 |
