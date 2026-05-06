# makefile テンプレート自動選択機構

本ドキュメントでは、makefw フレームワークにおける makefile テンプレートの自動選択機構について説明します。

## 概要

makefw では、`app/<app_name>/makefile` 用の app 直下テンプレート (`__app_root_template.mk`) と、配下の makefile (最終ビルド層・中間走査層) 用の統一テンプレート (`__template.mk`) を使い分けます。ビルドを行うかどうかは `MAKEFW_BUILD` フラグで制御し、フラグが設定されている場合のみディレクトリパスと言語の自動判定でビルドテンプレートを選択します。

これにより、以下のメリットが得られます：

- **役割ごとの統一**: app 直下用と配下用でテンプレートを固定し、メンテナンスを容易にする
- **ビルド/走査の分離**: `MAKEFW_BUILD := 1` を `makechild.mk` に記述することでビルド対象を明示
- **自動判定**: ディレクトリパスと .csproj の有無で自動的に適切なビルドテンプレートを選択
- **柔軟性**: プロジェクト固有の設定は makepart.mk で管理

## アーキテクチャー

### ファイル構成

```text
framework/makefw/makefiles/
+-- __app_root_template.mk  # app/<app_name>/makefile 用テンプレート
+-- __template.mk           # 配下の makefile 用統一テンプレート
+-- prepare.mk              # 準備処理（コンパイラ設定、makepart.mk / makechild.mk / makelocal.mk 読み込み）
+-- makemain.mk             # MAKEFW_BUILD フラグに基づくビルドテンプレート選択ロジック
+-- makelibsrc_c_cpp.mk     # C/C++ ライブラリビルド用テンプレート
+-- makelibsrc_dotnet.mk    # .NET ライブラリビルド用テンプレート
+-- makesrc_c_cpp.mk        # C/C++ 実行体ビルド用テンプレート
+-- makesrc_dotnet.mk       # .NET 実行体ビルド用テンプレート
```

### 処理フロー

```plantuml
@startuml
start
:makefile (__template.mk);
:(1) ワークスペース検索 (find-up 関数);
:(2) prepare.mk を include;
note right
  - コンパイラ設定 (CC, CXX, LD, AR)
  - makechild.mk の読み込み（親階層から順次、自身を除く）
  - makepart.mk の読み込み（親階層から順次）
  - makelocal.mk の読み込み（カレントディレクトリのみ）
end note
:(3) makemain.mk を include;
:(4) サブディレクトリ検出;
note right
  GNUmakefile/makefile/Makefile を
  含むサブディレクトリを検出
end note
:(5) サブディレクトリの OS フィルタリング;
note right
  最終ディレクトリ名 (大文字小文字無視) で判定:
  "linux"   → Linux のみ有効
  "windows" → Windows のみ有効
  "shared" / その他 → 両 OS で有効
  詳細: os-subdirectory-filtering.md
end note
:(6) MAKEFW_BUILD フラグの確認;

if (MAKEFW_BUILD = 1 ?) then (yes)
  :(7) パス判定による分岐;
  if (パスに /libsrc/ を含む?) then (yes)
    :ライブラリ;
    if (.csproj が存在?) then (yes)
      :makelibsrc_dotnet.mk;
      stop
    else (no)
      :makelibsrc_c_cpp.mk;
      stop
    endif
  else (no)
    if (パスに /src/ を含む?) then (yes)
      :実行体;
      if (.csproj が存在?) then (yes)
        :makesrc_dotnet.mk;
        stop
      else (no)
        :makesrc_c_cpp.mk;
        stop
      endif
    else (no)
      :エラー: /libsrc/ または /src/ が必要;
      stop
    endif
  endif
else (no)
  :サブディレクトリ走査のみ;
  stop
endif
@enduml
```

## app 直下テンプレート (__app_root_template.mk)

`app/<app_name>/makefile` で使用する標準テンプレートです。`prod` / `test` の呼び出し、`doxy` 実行、ログファイル管理を担当します。

## 統一テンプレート (__template.mk)

配下の makefile (最終ビルド層・中間走査層) で使用する標準テンプレートです。

```makefile
# app 配下 makefile テンプレート
# すべての app/<app_name>/.../makefile で使用する標準テンプレート
# 本ファイルの直接編集は禁止する。

# ワークスペースのディレクトリ
find-up = \
    $(if $(wildcard $(1)/$(2)),$(1),\
        $(if $(filter $(1),$(patsubst %/,%,$(dir $(1)))),,\
            $(call find-up,$(patsubst %/,%,$(dir $(1))),$(2))\
        )\
    )

# 再帰 make 間でワークスペースルートは不変のため、内部キャッシュ変数で継承する
ifeq ($(origin MAKEFW_WORKSPACE_DIR), undefined)
    MAKEFW_WORKSPACE_DIR := $(strip $(call find-up,$(CURDIR),.workspaceRoot))
endif
export MAKEFW_WORKSPACE_DIR

WORKSPACE_DIR := $(MAKEFW_WORKSPACE_DIR)

# 準備処理 (ビルドテンプレートより前に include)
include $(WORKSPACE_DIR)/framework/makefw/makefiles/prepare.mk

##### makepart.mk の内容は、このタイミングで処理される #####

# ビルドテンプレートを include
include $(WORKSPACE_DIR)/framework/makefw/makefiles/makemain.mk
```

### 重要なポイント

1. **統一性**: 配下の最終ビルド層・中間走査層のすべての makefile が完全に同一
2. **編集禁止**: 固有の設定は makepart.mk / makechild.mk / makelocal.mk に記述
3. **処理順序**: prepare.mk → makechild.mk / makepart.mk / makelocal.mk → makemain.mk

## 自動選択ロジック (makemain.mk)

ディレクトリパスと .csproj の有無により、適切なビルドテンプレートを自動選択します。  
`MAKEFW_BUILD := 1` が設定されている場合のみビルドを実行します (未設定はサブディレクトリ走査のみ)。

```makefile
# カレントディレクトリのパス判定による自動テンプレート選択
# MAKEFW_BUILD := 1 が設定されている場合のみビルドを実行する (デフォルト: サブディレクトリ走査のみ)

ifeq ($(MAKEFW_BUILD),1)

# パスに /libsrc/ を含む場合はライブラリ用テンプレート
ifneq (,$(findstring /libsrc/,$(CURDIR)))
    ifneq ($(wildcard *.csproj),)
        include $(WORKSPACE_DIR)/framework/makefw/makefiles/makelibsrc_dotnet.mk
    else
        include $(WORKSPACE_DIR)/framework/makefw/makefiles/makelibsrc_c_cpp.mk
    endif
# パスに /src/ を含む場合は実行ファイル用テンプレート
else ifneq (,$(findstring /src/,$(CURDIR)))
    ifneq ($(wildcard *.csproj),)
        include $(WORKSPACE_DIR)/framework/makefw/makefiles/makesrc_dotnet.mk
    else
        include $(WORKSPACE_DIR)/framework/makefw/makefiles/makesrc_c_cpp.mk
    endif
else
    $(error Cannot auto-select makefile template. MAKEFW_BUILD=1 requires /libsrc/ or /src/ in path: $(CURDIR))
endif

endif  # MAKEFW_BUILD
```

### 判定ルール

`MAKEFW_BUILD := 1` の場合のみ以下の判定が行われます。未設定の場合はサブディレクトリ走査のみを行います。

| ディレクトリパス | .csproj | 選択されるテンプレート |
|--------------|---------|-------------------|
| `/libsrc/` を含む | 無し | `makelibsrc_c_cpp.mk` |
| `/libsrc/` を含む | 有り | `makelibsrc_dotnet.mk` |
| `/src/` を含む | 無し | `makesrc_c_cpp.mk` |
| `/src/` を含む | 有り | `makesrc_dotnet.mk` |
| 上記以外 | - | エラー |

### MAKEFW_BUILD フラグ

`MAKEFW_BUILD` は `makechild.mk` または `makelocal.mk` に記述します。

| ファイル | 設定例 | 効果範囲 |
|--------|--------|---------|
| `libsrc/makechild.mk` | `MAKEFW_BUILD := 1` | `libsrc/` 配下の全ディレクトリに継承 |
| `src/makechild.mk` | `MAKEFW_BUILD := 1` | `src/` 配下の全ディレクトリに継承 |
| `src/<subdir>/makelocal.mk` | `MAKEFW_BUILD := 0` | そのディレクトリのみ走査に戻す |

`prepare.mk` は `makechild.mk` (親階層から継承) を先に読み込み、その後に `makelocal.mk` (カレントのみ) を読み込むため、`makelocal.mk` による上書きが正しく機能します。

## サブディレクトリの OS フィルタリング

サブディレクトリ名に基づく OS フィルタリングの詳細は、[サブディレクトリの OS フィルタリング](os-subdirectory-filtering.md) を参照してください。

## 使用例

### C/C++ ライブラリ

```text
ディレクトリ: app/calc/prod/libsrc/calc/
ファイル構成:
  - makefile (__template.mk の内容)
  - add.c, subtract.c, multiply.c, divide.c
  - makepart.mk (固有設定、必要な場合のみ)

判定結果:
  MAKEFW_BUILD: 1 (app/calc/prod/libsrc/makechild.mk で設定)
  パス: /libsrc/ を含む → ライブラリ
  .csproj: 無し → C/C++
  → makelibsrc_c_cpp.mk を使用
```

### .NET ライブラリ

```text
ディレクトリ: app/calc.net/prod/libsrc/CalcLib/
ファイル構成:
  - makefile (__template.mk の内容)
  - CalcLib.csproj
  - Calculator.cs
  - makepart.mk (固有設定、必要な場合のみ)

判定結果:
  MAKEFW_BUILD: 1 (app/calc.net/prod/libsrc/makechild.mk で設定)
  パス: /libsrc/ を含む → ライブラリ
  .csproj: 有り → .NET
  → makelibsrc_dotnet.mk を使用
```

### C/C++ 実行体

```text
ディレクトリ: app/calc/prod/src/add/
ファイル構成:
  - makefile (__template.mk の内容)
  - add.c
  - makepart.mk (固有設定、必要な場合のみ)

判定結果:
  MAKEFW_BUILD: 1 (app/calc/prod/src/makechild.mk で設定)
  パス: /src/ を含む → 実行体
  .csproj: 無し → C/C++
  → makesrc_c_cpp.mk を使用
```

### .NET 実行体

```text
ディレクトリ: app/calc.net/prod/src/CalcApp/
ファイル構成:
  - makefile (__template.mk の内容)
  - CalcApp.csproj
  - Program.cs
  - makepart.mk (固有設定、必要な場合のみ)

判定結果:
  MAKEFW_BUILD: 1 (app/calc.net/prod/src/makechild.mk で設定)
  パス: /src/ を含む → 実行体
  .csproj: 有り → .NET
  → makesrc_dotnet.mk を使用
```

## プロジェクト固有設定 (makepart.mk)

各プロジェクト固有の設定は、`makepart.mk` ファイルに記述します。

### makepart.mk の配置場所

makepart.mk は、以下の階層に配置できます：

1. **カレントディレクトリ** - 最も優先される
2. **親ディレクトリ (複数)** - ワークスペースルートまで遡って検索
3. **複数の階層** - 親階層から順次読み込まれる

### makepart.mk / makechild.mk / makelocal.mk の読み込みタイミング

`prepare.mk` 内で、以下の順序で読み込まれます：

1. **makechild.mk + makepart.mk**: ワークスペースルートからカレントディレクトリまでの各階層を走査。
   `makechild.mk` はカレントディレクトリ自身を除外 (子階層以降にのみ適用)。
2. **makelocal.mk**: カレントディレクトリのみ。`makechild.mk` より後に読み込まれるため、フラグの上書きに使用。

### makepart.mk の記述例

**例 1: 動的ライブラリの指定**

```makefile
# app/calc/prod/libsrc/calc/makepart.mk

# ライブラリの追加
LIBS += calcbase

ifeq ($(OS),Windows_NT)
    # Windows: DLL エクスポート定義
    CFLAGS   += /DCALC_EXPORTS
    CXXFLAGS += /DCALC_EXPORTS
endif

# 生成されるライブラリを動的ライブラリ (shared) とする
# 未指定の場合 (デフォルト) は static
# both を指定すると shared + static の両方を生成する (static 側は名前に _static が付く)
LIB_TYPE = shared
```

**例 2: テスト共通設定**

```makefile
# app/calc/test/makepart.mk

# テストフレームワークをリンク
LINK_TEST = 1

# テスト関連ライブラリは、すべて静的リンクとする
ifeq ($(OS),Windows_NT)
    # Windows: CALC_STATIC マクロを定義
    CFLAGS   += /DCALC_STATIC
    CXXFLAGS += /DCALC_STATIC
endif

# ライブラリ検索パスの追加
LIBSDIR += \
    $(WORKSPACE_DIR)/framework/testfw/lib \
    $(WORKSPACE_DIR)/app/calc/test/lib
```

## 導入方法

既存プロジェクトに makefile テンプレート自動選択機構を導入する手順を説明します。

すべての階層の makefile (最終ビルド層・中間走査層) が `__template.mk` と同一内容になります。  
ビルドを行うかどうかは `makechild.mk` の `MAKEFW_BUILD := 1` で制御します。

### 1. すべての makefile を更新

すべての makefile を `__template.mk` の内容で置き換えます。

```bash
# 例: app/calc/prod/libsrc/calc/makefile を更新
cp framework/makefw/makefiles/__template.mk app/calc/prod/libsrc/calc/makefile

# 一括更新には保守コマンドを使用
python framework/makefw/bin/update_template_makefiles.py
```

### 2. MAKEFW_BUILD の設定

ビルドを実行するには、`libsrc/` または `src/` コンテナーディレクトリに `makechild.mk` を作成します。

```makefile
# app/calc/prod/libsrc/makechild.mk
MAKEFW_BUILD := 1
```

`makechild.mk` は配下のすべてのディレクトリに継承されます (`prepare.mk` がコンテナー自身を除外するため、コンテナーは走査のみになります)。

`/src/<something>/` のようなサブ中間走査層が存在する場合は、そのディレクトリに `makelocal.mk` で `MAKEFW_BUILD := 0` を指定して走査に戻します。

```makefile
# app/calc/test/src/libcalcbaseTest/makelocal.mk
MAKEFW_BUILD := 0
```

### 3. 固有設定の移行

既存の makefile に固有設定 (LIBS, CFLAGS など) がある場合、`makepart.mk` に移行します。

**変更前 (makefile):**

```makefile
include $(WORKSPACE_DIR)/framework/makefw/makefiles/prepare.mk

# 固有設定
LIBS += calcbase
LIB_TYPE = shared

include $(WORKSPACE_DIR)/framework/makefw/makefiles/makelibsrc_c_cpp.mk
```

**変更後:**

**makefile (`__template.mk` の内容):**

```makefile
# app 配下 makefile テンプレート
# すべての app/<app_name>/.../makefile で使用する標準テンプレート
# 本ファイルの直接編集は禁止する。

include $(WORKSPACE_DIR)/framework/makefw/makefiles/prepare.mk

##### makepart.mk の内容は、このタイミングで処理される #####

include $(WORKSPACE_DIR)/framework/makefw/makefiles/makemain.mk
```

**makepart.mk (固有設定):**

```makefile
LIBS += calcbase
LIB_TYPE = shared
```

### 4. 動作確認

```bash
cd app/calc/prod/libsrc/calc
make clean
make
```

## トラブルシューティング

### エラー: "Cannot auto-select makefile template"

**原因**: `MAKEFW_BUILD := 1` が設定されているが、ディレクトリパスに `/libsrc/` も `/src/` も含まれていない

**解決策**:
1. ディレクトリ構造を見直し、`libsrc` または `src` の下に配置する
2. または、当該ディレクトリの `makelocal.mk` に `MAKEFW_BUILD := 0` を設定して走査のみに戻す

### ビルドが実行されない (サブディレクトリ走査のみになる)

**確認事項**:
1. `libsrc/` または `src/` コンテナーに `makechild.mk` (`MAKEFW_BUILD := 1`) が存在するか
2. サブ中間走査層の `makelocal.mk` で `MAKEFW_BUILD := 0` が上書きされていないか

### ビルドが失敗する

**確認事項**:
1. `makepart.mk` の内容が正しいか
2. `WORKSPACE_DIR` が正しく設定されているか (`.workspaceRoot` ファイルの配置)
3. 依存ライブラリが正しくビルドされているか

**デバッグ方法**:

```bash
make debug  # 変数の内容を表示
```

## まとめ

makefile テンプレート自動選択機構により、以下が実現されます：

- **役割ごとの統一**: app 直下用と配下用でテンプレートを固定
- **ビルド/走査の分離**: `MAKEFW_BUILD := 1` (`makechild.mk`) と `MAKEFW_BUILD := 0` (`makelocal.mk`) で責務を明示
- **自動化**: ディレクトリパスと言語の自動判定
- **保守性**: 固有設定は makepart.mk / makechild.mk / makelocal.mk で管理
- **拡張性**: 新しい言語やビルドタイプの追加が容易

この機構により、プロジェクト全体のビルドシステムが統一され、メンテナンスが大幅に容易になります。

## 保守コマンド

app 直下テンプレートまたは統一テンプレートを更新したあと、すでに配置済みの対応 `makefile` を再同期するには、次の保守コマンドを利用します。

```bash
python framework/makefw/bin/update_template_makefiles.py --dry-run
python framework/makefw/bin/update_template_makefiles.py
```

詳細は [update_template_makefiles.md](update_template_makefiles.md) を参照してください。
