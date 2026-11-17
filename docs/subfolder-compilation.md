# C 言語サブディレクトリ対応の詳細と実装ガイド

## 概要

この文書は、makefw を使用して C 言語ソース コードをサブディレクトリへ配置する方法を説明します。

大規模な C 言語プロジェクトでは、ソース コードを機能ごとにサブディレクトリへ分割することが一般的です。  
本フレームワークは、次の観点からサブディレクトリ対応を提供します。

1. **ライブラリ**: サブディレクトリに配置したソース ファイルを単一のライブラリにリンク
2. **コマンド (実行ファイル)**: サブディレクトリに配置したソース ファイルを単一の実行ファイルにリンク
3. **テスト**: サブディレクトリごとのテスト コードとテスト対象ソースの管理

この文書の例は、架空の app `app/hierarchy-example` を使います。

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

```makefile
# makelibsrc_c_cpp.mk / makesrc_c_cpp.mk (抜粋)
SUBDIR_OBJS := $(shell bash "$(MAKEFW_HOME)/bin_internal/filter_existing_source_objs.sh" linux subdirs)
OBJS += $(SUBDIR_OBJS)
```

これにより、親ディレクトリでリンクを実行すると、サブディレクトリのオブジェクト ファイルも含めてリンクされます。  
Linux では、makefile の読み込み時に存在するオブジェクトを列挙して、リンクの前提に加えます。  
Windows では、リンクのレシピの中でオブジェクトを列挙します。

収集の対象は `bin_internal/filter_existing_source_objs.sh` が判定します。  
削除済みのソースに対応する古いオブジェクトを混入させないため、生成元のソースが存在するものだけを収集対象とします。  
判定の根拠は次のいずれかです。

- 手書きのソース `<サブディレクトリ>/<ステム>.c` (`.cc`、`.cpp` も同様)
- コード生成の出力 `<サブディレクトリ>/gen/<ステム>.c` (`.cc`、`.cpp` も同様)

2 番目の条件により、ライブラリや実行体のサブディレクトリへ `.l` / `.y` を置いた場合でも、そこから生成されたオブジェクトがリンクを行う親ディレクトリまで収集されます。

`gen/` を根拠にできるのはサブディレクトリだけです。  
リンクを行うディレクトリ自身の `gen/` 由来オブジェクトは、このスクリプトではなく `_flex_bison_compile.mk` が `MAKEFW_EXTRA_OBJS` 経由でリンク入力へ加えます。  
両方で収集すると、同一のオブジェクトを二重にリンクしてしまいます。

収集したオブジェクトは、属するサブディレクトリの再帰 make が終わってから、親が存在を確認します。  
リンクの規則は、サブディレクトリの再帰 make とそのオブジェクトを同じ規則の前提に並べるため、順序を指定しないと、並列ビルドで親が再帰 make の完了を待たずにオブジェクトを確認します。  
GCC は既存のオブジェクトを上書きするとき、出力先を削除してから作り直します。  
その瞬間に親の確認が当たると、親にはそのオブジェクトを作る規則がないため、make は「make するルールがありません」で止まります。  
そのため、各オブジェクトに、属するサブディレクトリの再帰 make を順序だけの前提 (order-only prerequisite) として加えています。

### 再帰的 make 処理

`makemain.mk` は、makefile を含むサブディレクトリを自動で検出し、主要なターゲットの前提にします。

```makefile
# makemain.mk (抜粋)
default build clean run restore rebuild _gen _test_build: $(SUBDIRS)
```

- `SUBDIRS` を指定しない場合は、`GNUmakefile`、`makefile`、`Makefile` のいずれかを含むサブディレクトリを検出し、並列に処理します。
- `makelocal.mk` または `makepart.mk` で `SUBDIRS` を指定した場合は、指定した順に 1 つずつ処理します。
- 特定の OS だけで使うサブディレクトリは、OS に応じて対象から外れます。
- `make test` は、テストのビルド (`_test_build`) とテストの実行 (`_test_run`) の 2 段階で処理します。`_test_build` は上記の前提でサブディレクトリへ伝わり、`_test_run` は直下のテストを先に実行してからサブディレクトリを処理します。

正確な内容は `makefiles/makemain.mk` を参照してください。

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
ifdef PLATFORM_WINDOWS
    # DLL エクスポート定義
    CFLAGS   += /DHIERARCHY_EXAMPLE_EXPORTS
    CXXFLAGS += /DHIERARCHY_EXAMPLE_EXPORTS
endif

# 動的ライブラリとして生成
LIB_TYPE = shared
```

**libhierarchy-example/makechild.mk (起点ディレクトリ):**

```makefile
# サブフォルダーはコンパイルのみ
NO_LINK = 1
```

`makechild.mk` は自ディレクトリには適用されないため、`libhierarchy-example/` ではリンクが実行され、サブディレクトリ (`subfolder_a/`, `subfolder_b/`) ではコンパイルのみが実行されます。

### ビルドの流れ

1. `libhierarchy-example/` で `make` を実行
2. `makemain.mk` がサブディレクトリ `subfolder_a/` と `subfolder_b/` を検出
3. 各サブディレクトリで `make` が再帰的に実行される
4. サブディレクトリでは `NO_LINK = 1` によりコンパイルのみ実行
5. 親ディレクトリで全オブジェクト ファイルを収集してライブラリを生成

`make` は、1 回の実行で各サブディレクトリを 1 回だけたどります。  
サブディレクトリを持つディレクトリの `build` は、前提としてサブディレクトリを処理した後、並列度を決めて同じディレクトリの make を起動し直し、直下のソースのコンパイルとリンクを行います。  
起動し直した make は、サブディレクトリを処理済みとして扱い、再びたどりません。  
サブディレクトリの `pre-build` と `post-build` のフックも、1 回の `make` で 1 回だけ実行されます。

**生成されるライブラリ:**

```text
app/hierarchy-example/prod/lib/liblibhierarchy-example.so
```

このライブラリには、`func.o`、`func_a.o`、`func_b.o` が含まれます。

## コマンド (実行ファイル) のサブディレクトリ対応

### ディレクトリ構造

```text
app/hierarchy-example/prod/
+-- cbin/                                   # ビルド済み実行ファイル出力先
|   +-- sample-app
+-- src/
    +-- makefile                            # 再帰ビルド用
    +-- makepart.mk
    +-- cmd/
        +-- makefile                        # 再帰ビルド用
        +-- makepart.mk                     # OUTPUT_DIR 設定 (prod/cbin)
        +-- sample-app/
            +-- makefile                    # 実行ファイル本体 (リンク実行)
            +-- makechild.mk                # NO_LINK = 1 (サブフォルダはコンパイルのみ)
            +-- sample-app.h                # ヘッダーファイル
            +-- main.c                      # メインソースファイル
            +-- obj/
            |   +-- main.o
            +-- subfolder_a/
            |   +-- makefile                # サブディレクトリ (makechild.mk により NO_LINK 適用)
            |   +-- helper_a.c
            |   +-- obj/
            |       +-- helper_a.o
            +-- subfolder_b/
                +-- makefile                # サブディレクトリ (makechild.mk により NO_LINK 適用)
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

**cmd/makepart.mk:**

```makefile
# 出力ディレクトリ
OUTPUT_DIR := $(MYAPP_DIR)/prod/cbin
```

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
    +-- makelocal.mk                        # TEST_SRCS 設定 (ルートのテスト対象)
    +-- makechild.mk                        # NO_LINK = 1 (サブフォルダはコンパイルのみ)
    +-- hierarchy-exampleTest.cc            # ルートのテストコード
    +-- bin/
    |   +-- hierarchy-exampleTest           # テスト実行ファイル
    +-- obj/
    |   +-- func.o                          # テスト対象ソースのオブジェクト
    |   +-- hierarchy-exampleTest.o         # テストコードのオブジェクト
    +-- results/                            # テスト結果出力先 (「テスト レポートの構造」を参照)
    +-- subfolder_a/
    |   +-- makefile                        # サブディレクトリ (makechild.mk により NO_LINK 適用)
    |   +-- makelocal.mk                    # TEST_SRCS 設定 (サブディレクトリのテスト対象)
    |   +-- hierarchy-exampleTest_a.cc      # サブディレクトリのテストコード
    |   +-- obj/
    |       +-- func_a.o
    |       +-- hierarchy-exampleTest_a.o
    +-- subfolder_b/
        +-- makefile                        # サブディレクトリ (makechild.mk により NO_LINK 適用)
        +-- makelocal.mk                    # TEST_SRCS 設定 (サブディレクトリのテスト対象)
        +-- hierarchy-exampleTest_b.cc      # サブディレクトリのテストコード
        +-- obj/
            +-- func_b.o
            +-- hierarchy-exampleTest_b.o
```

### 設定ファイルの内容

**hierarchy-exampleTest/makelocal.mk (起点ディレクトリ):**

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

テストでは、`NO_LINK = 1` は起点ディレクトリの `makechild.mk` に、`TEST_SRCS` は起点と各サブディレクトリの `makelocal.mk` にそれぞれ分離して定義します。  
`TEST_SRCS` を `makelocal.mk` に配置することで、各テスト対象の指定が自ディレクトリに限定され、子階層に継承されません。  
テスト対象のソースは、`TEST_SRCS` を指定したディレクトリへ取り込まれてコンパイルされます。

### テスト コードの例

**hierarchy-exampleTest.cc (親ディレクトリ):**

```cpp
#include <testfw.h>
#include <hierarchy-example.h>

class hierarchy_exampleTest : public Test
{
};

// func() が 0 を返すことの確認
TEST_F(hierarchy_exampleTest, test_func)
{
    // Arrange

    // Pre-Assert

    // Act
    int actual_ret = func(); // [手順] - func() を呼び出す。

    // Assert
    EXPECT_EQ(0, actual_ret); // [確認_正常系] - func() の戻り値が 0 であること。
}
```

**subfolder_a/hierarchy-exampleTest_a.cc (サブディレクトリ):**

```cpp
#include <testfw.h>
#include <hierarchy-example.h>

class hierarchy_exampleTest_a : public Test
{
};

// func_a() が 1 を返すことの確認
TEST_F(hierarchy_exampleTest_a, test_func_a)
{
    // Arrange

    // Pre-Assert

    // Act
    int actual_ret = func_a(); // [手順] - func_a() を呼び出す。

    // Assert
    EXPECT_EQ(1, actual_ret); // [確認_正常系] - func_a() の戻り値が 1 であること。
}
```

### TEST_SRCS の自動収集

テスト実行スクリプト (`framework/testfw/bin_internal/exec_test_c_cpp.sh`) は、起点の `TEST_SRCS` に、サブディレクトリの `TEST_SRCS` を合わせて、全体のカバレッジの対象にします。  
サブディレクトリの `TEST_SRCS` は、makefile を持つサブディレクトリごとに make を起動して問い合わせます (`query_test_sources.mk`)。  
`makelocal.mk` や `makepart.mk` を文字列として読むのではなく、makefw が解釈した値を使います。

- 対象のソースは、起点の `TEST_SRCS` を指定した順に並べ、サブディレクトリの分をパスの昇順で続けます。
- 同じソースが複数のディレクトリで指定されている場合は、1 回だけ対象にします。
- Windows のカバレッジの計測対象 (OpenCppCoverage の `--sources`) は、ソースごとに、`TEST_SRCS` を指定したディレクトリで指定します。

これにより、各サブディレクトリで個別にテスト対象を指定しつつ、全体のカバレッジ レポートを生成できます。  
テストを省略するかどうか (前回から変更がないか) の判定にも、合わせた後のソースを使います。

## テスト レポートの構造

`make test` を実行すると、`results/` ディレクトリにテスト レポートが生成されます。  
以下の例は、Linux での出力です。

### results/ ディレクトリ構造

```text
results/
+-- all_tests/                              # 全体テスト結果
|   +-- summary.md                          # テストサマリー
|   +-- coverage.xml                        # 全体カバレッジ (Cobertura 形式)
|   +-- coverage.json                       # 全体カバレッジ (gcovr の JSON 形式、Linux)
|   +-- func.c.gcov.md                      # func.c のカバレッジ詳細
|   +-- func_a.c.gcov.md                    # func_a.c のカバレッジ詳細
|   +-- func_b.c.gcov.md                    # func_b.c のカバレッジ詳細
|   +-- lcov/                               # HTML カバレッジレポート (Linux、genhtml がある場合)
+-- <テストクラス>.<テスト名>/              # 個別テスト結果
    +-- results.md                          # テスト実行ログ
    +-- <ソースファイル>.gcov.md            # 個別テストのカバレッジ
```

`all_tests/` の `*.gcov.md` は、全体のカバレッジの対象 (起点とサブディレクトリの `TEST_SRCS`) のソースごとに出力されます。  
個別テストの `*.gcov.md` は、そのテストで実行されたソースだけです。

### summary.md の内容例

````markdown
# hierarchy-exampleTest のテスト結果サマリー

- 実施日時: 2026-11-18 02:20:21 JST

## テスト対象ソースの MD5

| MD5 | ファイル |
| --- | --- |
| 8701cc7afd102f0c49274762aec99b1a | app/hierarchy-example/prod/libsrc/libhierarchy-example/func.c |
| c48d4b18f94bc14f48caaaa830509757 | app/hierarchy-example/prod/libsrc/libhierarchy-example/subfolder_a/func_a.c |
| ad49655e644dfac6440ee8b8cb84488a | app/hierarchy-example/prod/libsrc/libhierarchy-example/subfolder_b/func_b.c |

Table: テスト対象ソースのファイル別の MD5 チェックサム

## テスト結果

| テスト ID | 結果 | パラメーター |
| --- | --- | --- |
| [hierarchy_exampleTest.test_func](../hierarchy_exampleTest.test_func/results.md) | PASSED |  |
| [hierarchy_exampleTest_a.test_func_a](../hierarchy_exampleTest_a.test_func_a/results.md) | PASSED |  |
| [hierarchy_exampleTest_b.test_func_b](../hierarchy_exampleTest_b.test_func_b/results.md) | PASSED |  |

Table: テスト ID 別の判定とパラメーター

## 集計

| 項目 | 件数 |
| --- | --- |
| Total tests | 3 |
| Passed | 3 |
| Warning(s) | 0 |
| Failed | 0 |

Table: 判定別のテスト件数

## 確認件数

| テスト定義 | 正常系 | 異常系 | 計 |
| --- | ---: | ---: | ---: |
| [hierarchy_exampleTest.test_func](../hierarchy_exampleTest.test_func/results.md) | 1 | 0 | 1 |
| [hierarchy_exampleTest_a.test_func_a](../hierarchy_exampleTest_a.test_func_a/results.md) | 1 | 0 | 1 |
| [hierarchy_exampleTest_b.test_func_b](../hierarchy_exampleTest_b.test_func_b/results.md) | 1 | 0 | 1 |
| 合計 | 3 | 0 | 3 |

Table: テスト定義別の正常系と異常系の確認件数

## カバレッジ

| File | Lines | Exec | Cover | Branch | BrCov | Missing |
| --- | --- | --- | --- | --- | --- | --- |
| func.c | 2 | 2 | 100% | - | - |  |
| func_a.c | 2 | 2 | 100% | - | - |  |
| func_b.c | 2 | 2 | 100% | - | - |  |
| TOTAL | 6 | 6 | 100% | - | - |  |

Table: ソース ファイル別の行とブランチのカバレッジ
````

### 個別テスト結果 (results.md) の内容例

````markdown
# hierarchy_exampleTest.test_func

- 判定: PASSED
- 実施日時: 2026-11-18 02:20:21 JST

## テスト項目の詳細

func() が 0 を返すことの確認

### 状態

特記すべき状態なし

### 手順

- func() を呼び出す。

### 確認 (正常系:1)

- 【正常系】func() の戻り値が 0 であること。

## テスト コード

```cpp
// func() が 0 を返すことの確認
TEST_F(hierarchy_exampleTest, test_func)
{
    // Arrange

    // Pre-Assert

    // Act
    int actual_ret = func(); // [手順] - func() を呼び出す。

    // Assert
    EXPECT_EQ(0, actual_ret); // [確認_正常系] - func() の戻り値が 0 であること。
}
```

## 実行結果

```text
./bin/hierarchy-exampleTest --gtest_filter=hierarchy_exampleTest.test_func
Running main() from testfw_gtest_main.cc
[==========] Running 1 test from 1 test suite.
[----------] Global test environment set-up.
[----------] 1 test from hierarchy_exampleTest
[ RUN      ] hierarchy_exampleTest.test_func
[       OK ] hierarchy_exampleTest.test_func (0 ms)
[----------] 1 test from hierarchy_exampleTest (0 ms total)

[----------] Global test environment tear-down
[==========] 1 test from 1 test suite ran. (0 ms total)
[  PASSED  ] 1 test.
```
````

テスト コードの直前のコメント (`// func() が 0 を返すことの確認`) が、「テスト項目の詳細」の題名になります。

### カバレッジ ファイル (*.gcov.md) の内容例

個別テストの `*.gcov.md` は、gcov の出力をそのまま載せます。  
「ソース」はワークスペースからの相対パスです。

````markdown
# func.c のカバレッジ

- ソース: app/hierarchy-example/prod/libsrc/libhierarchy-example/func.c

```text
        -:    0:Source:func.c
        -:    0:Graph:.../obj/func.gcno
        -:    0:Data:.../obj/func.gcda
        -:    0:Runs:1
        -:    0:Programs:1
        -:    1:#include <hierarchy-example.h>
        -:    2:
        1:    3:int func(void)
        -:    4:{
        1:    5:    return 0;
        -:    6:}
```
````

`all_tests/` の `*.gcov.md` は、全体のカバレッジ (`coverage.xml`) から変換して作ります。  
そのため、先頭の行は次のとおり個別テストと異なります。

```text
        -:    0:Source:<ソースの絶対パス>
        -:    0:Graph:generated by cobertura2gcov
        -:    0:Data:cobertura.xml
```

各行の先頭の数字は実行回数を示します:

- `-`: 実行対象外の行 (コメント、空行など)
- `1` 以上: 実行された回数

## サブディレクトリ対応のベスト プラクティス

### makefile の配置

各サブディレクトリに makefile を配置します。  
内容は標準テンプレート `framework/makefw/makefiles/__template.mk` をそのまま複写し、編集しません。  
拡張やカスタマイズは、`makepart.mk`、`makechild.mk`、`makelocal.mk` で行います。

### makechild.mk での NO_LINK 設定

リンクを行う起点ディレクトリに `makechild.mk` を配置し、`NO_LINK = 1` を定義します。  
これにより、すべてのサブディレクトリに自動的に適用されます。

```makefile
# 起点ディレクトリの makechild.mk
# サブフォルダーはコンパイルのみ
NO_LINK = 1
```

テストの場合は、起点と各サブディレクトリの `makelocal.mk` で `TEST_SRCS` を設定します。

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
INCDIR += $(MYAPP_DIR)/prod/src/cmd/sample-app
```

## まとめ

| 観点 | 設定ファイル | 設定 | 説明 |
|------|------------|------|------|
| ライブラリ | 起点の `makechild.mk` | `NO_LINK = 1` | サブディレクトリではコンパイルのみ、起点でリンク |
| コマンド | 起点の `makechild.mk` | `NO_LINK = 1` | サブディレクトリではコンパイルのみ、起点でリンク |
| テスト | 起点の `makechild.mk` | `NO_LINK = 1` | サブディレクトリではコンパイルのみ、起点でリンク |
| テスト | 起点と各サブの `makelocal.mk` | `TEST_SRCS` | ディレクトリごとにテスト対象を指定し、全体のカバレッジでは合わせて扱う |
| テスト レポート | - | `results/` | 個別テスト結果と全体カバレッジを出力 |

Table: サブフォルダー コンパイルの設定要件一覧
