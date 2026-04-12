# 各 makefile から呼び出され、
# 1. プラットフォームの判定を行う
# 2. testfw の配置パスを解決する
# 3. ソースファイルのエンコード指定から LANG を得る
# 4. コンパイルコマンド関連を設定する
# 5. 親階層から makefile の存在する階層までに存在する makepart.mk を
#    親階層から makefile の存在する階層に向かって順次 include する
#    各 makepart.mk の直後に、同ディレクトリの makechild.mk が存在すれば include する
#    (カレントディレクトリの makechild.mk は子階層以降にのみ適用されるため除く)
# 6. カレントディレクトリの makelocal.mk を include する

SHELL := /bin/bash

# プラットフォーム判定
# すでに定義されているか確認
ifeq ($(origin PLATFORM), undefined)
    # 判定
    ifeq ($(OS),Windows_NT)
        PLATFORM := Windows
    else
        UNAME_S := $(shell uname -s 2>/dev/null)
        ifeq ($(UNAME_S),Linux)
            PLATFORM := Linux
        else
            PLATFORM := Unknown
        endif
    endif
endif

export PLATFORM

override undefine PLATFORM_WINDOWS
override undefine PLATFORM_LINUX
override undefine PLATFORM_UNKNOWN

ifeq ($(PLATFORM),Windows)
    override PLATFORM_WINDOWS := 1
    export PLATFORM_WINDOWS
else ifeq ($(PLATFORM),Linux)
    override PLATFORM_LINUX := 1
    export PLATFORM_LINUX
else
    override PLATFORM_UNKNOWN := 1
    export PLATFORM_UNKNOWN
endif

#$(info PLATFORM: $(PLATFORM))
#$(info PLATFORM_WINDOWS: $(PLATFORM_WINDOWS))
#$(info PLATFORM_LINUX: $(PLATFORM_LINUX))
#$(info PLATFORM_UNKNOWN: $(PLATFORM_UNKNOWN))

ifdef PLATFORM_UNKNOWN
    $(error Unsupported PLATFORM: $(PLATFORM). Supported platforms are Linux and Windows)
endif

# testfw の配置パスを解決
# Resolve testfw location
# 優先順位:
# 1. 明示指定された TESTFW_DIR
# 2. 統合プロジェクト配下の framework/testfw
# 3. 単独 CI / sibling 配置の testfw
ifeq ($(strip $(TESTFW_DIR)),)
    ifneq ($(wildcard $(WORKSPACE_FOLDER)/framework/testfw),)
        TESTFW_DIR := $(WORKSPACE_FOLDER)/framework/testfw
    else ifneq ($(wildcard $(WORKSPACE_FOLDER)/testfw),)
        TESTFW_DIR := $(WORKSPACE_FOLDER)/testfw
    endif
else
    TESTFW_DIR := $(abspath $(TESTFW_DIR))
endif
TESTFW_DIR_ERROR := testfw directory not found. Set TESTFW_DIR or place testfw under $(WORKSPACE_FOLDER)/framework/testfw or $(WORKSPACE_FOLDER)/testfw.
export TESTFW_DIR

DEFINES :=

# ソースファイルのエンコード指定から LANG を得る
# FILES_LANG is stable across recursive make invocations in the same workspace
ifeq ($(origin MAKEFW_FILES_LANG), undefined)
    MAKEFW_FILES_LANG := $(shell bash $(WORKSPACE_FOLDER)/framework/makefw/bin/get_files_lang.sh)
endif
export MAKEFW_FILES_LANG
FILES_LANG := $(MAKEFW_FILES_LANG)

#$(info FILES_LANG: $(FILES_LANG));

# FILES_LANG からエンコーディング部分を抽出
FILES_ENCODING := $(lastword $(subst ., ,$(FILES_LANG)))

# FILES_LANG が UTF-8 の場合は変換不要 (cat に置換)
ifneq (,$(filter utf8 UTF-8 utf-8 UTF8,$(FILES_ENCODING)))
    ICONV := cat
else
    # エンコーディング名のマッピング (VS Code files.encoding → iconv)
    ICONV_ENCODING_eucjp    := EUC-JP
    ICONV_ENCODING_eucJP    := EUC-JP
    ICONV_ENCODING_shiftjis := SHIFT_JIS
    ICONV_ENCODING_cp932    := CP932
    ICONV_ENCODING_iso2022jp := ISO-2022-JP

    ICONV_FROM := $(ICONV_ENCODING_$(FILES_ENCODING))
    ifeq ($(ICONV_FROM),)
        # マッピング未定義の場合はそのまま使用 (iconv が受け付ける可能性)
        ICONV_FROM := $(FILES_ENCODING)
    endif
    ICONV := iconv -c -f $(ICONV_FROM) -t UTF-8
endif

# アーキテクチャ判定
# Determine target architecture
ifeq ($(origin MAKEFW_TARGET_ARCH), undefined)
    # uname -m は Linux/Windows 共通で1回だけ呼ぶ
    # Call uname -m only once (shared between Linux and Windows)
    UNAME_ARCH := $(shell uname -m)
    # x86_64 を x64 に変換
    # Convert x86_64 to x64
    ifeq ($(UNAME_ARCH),x86_64)
        ARCH := x64
    else
        ARCH := $(UNAME_ARCH)
    endif

    ifdef PLATFORM_LINUX
        # RHEL系 (Oracle Linux, RHEL, CentOS, Rocky Linux など) の場合
        # For RHEL-based distributions (Oracle Linux, RHEL, CentOS, Rocky Linux, etc.)
        # /etc/redhat-release の有無判定と sed を1つの shell 呼び出しに統合
        # Combine redhat-release check and sed into single shell invocation
        RHEL_VERSION := $(shell sed -n 's/.*release \([0-9]\+\).*/\1/p' /etc/redhat-release 2>/dev/null)
        ifneq ($(RHEL_VERSION),)
            OS_ID := el$(RHEL_VERSION)
        else
            # その他の Linux ディストリビューション
            # Other Linux distributions
            OS_ID := $(shell . /etc/os-release 2>/dev/null && echo $$ID || echo linux)
        endif
        MAKEFW_TARGET_ARCH := linux-$(OS_ID)-$(ARCH)
    else ifdef PLATFORM_WINDOWS
        MAKEFW_TARGET_ARCH := windows-$(ARCH)
    endif
endif
export MAKEFW_TARGET_ARCH
TARGET_ARCH := $(MAKEFW_TARGET_ARCH)

# デフォルト設定 START ##############################################################

# コンフィグ設定 (RelWithDebInfo, Debug, Release)
# "make CONFIG=Debug" のように引数で指定するか、この先の makefile で置換する
CONFIG ?= RelWithDebInfo

# origin 関数は変数がどこから来たかを返します。
# - default: Makeの組み込みデフォルト値
# - environment: 環境変数から
# - file: makefileで定義
# - command line: コマンドライン引数から
# 以下は、make のデフォルト値の場合のみ、値を置き換えます。
# 環境変数やコマンドライン引数で指定された場合はそちらが優先されます。
ifdef PLATFORM_LINUX
    # Linux (gcc/g++)
    ifeq ($(origin CC),default)
        CC = gcc
    endif
    ifeq ($(origin CXX),default)
        CXX = g++
    endif
    ifeq ($(origin LD),default)
        LD = g++
    endif
    ifeq ($(origin AR),default)
        AR = ar
    endif
else ifdef PLATFORM_WINDOWS
    # Windows (MSVC)

    # Windows 環境のインターロックチェック
    # bash と cl の存在確認を1回の where 呼び出しにまとめて取得
    # Check bash and cl existence, consolidating where calls
    # 1. bash の存在確認と MinGW (MSYS) bash の検証
    ifeq ($(origin MAKEFW_BASH_PATH), undefined)
        MAKEFW_BASH_PATH := $(shell where bash 2>/dev/null | head -1)
    endif
    export MAKEFW_BASH_PATH
    BASH_PATH := $(MAKEFW_BASH_PATH)
    ifeq ($(BASH_PATH),)
        $(error bash へのパスが通っていません。MinGW (MSYS) へのパスを設定してください。)
    endif
    ifneq ($(findstring System32,$(BASH_PATH)),)
        $(error System32 の bash.exe が検出されました。MinGW (MSYS) の bash を優先してください。)
    endif
    ifneq ($(findstring WindowsApps,$(BASH_PATH)),)
        $(error WindowsApps の bash.exe が検出されました。MinGW (MSYS) の bash を優先してください。)
    endif

    # 2. cl.exe の存在確認 (結果を CL_PATH として再利用し、where cl の重複呼び出しを排除)
    # Check cl.exe existence (reuse result as CL_PATH to eliminate duplicate where cl calls)
    # Note: This file is evaluated by Bash even on Windows, so use /dev/null instead of nul.
    ifeq ($(origin MAKEFW_CL_PATH), undefined)
        MAKEFW_CL_PATH := $(shell where.exe cl 2>/dev/null | head -1)
    endif
    export MAKEFW_CL_PATH
    CL_PATH := $(MAKEFW_CL_PATH)
    ifeq ($(CL_PATH),)
        $(error cl.exe へのパスが通っていません。Visual Studio Build Tools へのパスを設定してください。)
    endif

    ifeq ($(origin CC),default)
        CC = cl
    endif
    ifeq ($(origin CXX),default)
        CXX = cl
    endif
    ifeq ($(origin LD),default)
        # MinGW の link ではなく MSVC の link を確実に選択させる
        # CL_PATH は上で取得済みのため再利用
        # CL_PATH is already obtained above, reuse it
        # 1. cl を link に置換する
        # 2. 可能なら 8.3 形式に変換
        # 3. bash 実行向けに Unix パス形式へ変換
        # 短縮名が取得できない環境でも、後段でクォートして実行できるパスを保持する
        MAKEFW_LINK_PATH_WIN := $(subst cl.exe,link.exe,$(CL_PATH))
        MAKEFW_LINK_PATH_SHORT := $(shell cygpath -d "$(MAKEFW_LINK_PATH_WIN)" 2>/dev/null)
        ifeq ($(MAKEFW_LINK_PATH_SHORT),)
            MAKEFW_LINK_PATH_SHORT := $(MAKEFW_LINK_PATH_WIN)
        endif
        MAKEFW_LINK_PATH_UNIX := $(shell cygpath -u "$(MAKEFW_LINK_PATH_SHORT)" 2>/dev/null)
        ifeq ($(MAKEFW_LINK_PATH_UNIX),)
            MAKEFW_LINK_PATH := $(MAKEFW_LINK_PATH_SHORT)
        else
            MAKEFW_LINK_PATH := $(MAKEFW_LINK_PATH_UNIX)
        endif
        export MAKEFW_LINK_PATH
        LD = $(MAKEFW_LINK_PATH)
    endif
    ifeq ($(origin AR),default)
        AR = lib
    endif

    # 3. dotnet.exe の存在確認と実行パス解決
    ifeq ($(origin MAKEFW_DOTNET_PATH), undefined)
        MAKEFW_DOTNET_PATH_WIN := $(shell where.exe dotnet 2>/dev/null | head -1)
        ifneq ($(MAKEFW_DOTNET_PATH_WIN),)
            MAKEFW_DOTNET_PATH_UNIX := $(shell cygpath -u "$(MAKEFW_DOTNET_PATH_WIN)" 2>/dev/null)
            ifeq ($(MAKEFW_DOTNET_PATH_UNIX),)
                MAKEFW_DOTNET_PATH := $(MAKEFW_DOTNET_PATH_WIN)
            else
                MAKEFW_DOTNET_PATH := $(MAKEFW_DOTNET_PATH_UNIX)
            endif
        endif
    endif
    export MAKEFW_DOTNET_PATH
endif

ifeq ($(origin DOTNET), undefined)
    ifneq ($(strip $(MAKEFW_DOTNET_PATH)),)
        DOTNET := $(MAKEFW_DOTNET_PATH)
    else
        DOTNET := dotnet
    endif
endif
export DOTNET

C_STANDARD   := 17
CXX_STANDARD := 17

#$(info ----)
#$(info CONFIG: $(CONFIG))
#$(info OS: $(OS))
#$(info CC: $(CC))
#$(info CXX: $(CXX))
#$(info LD: $(LD))
#$(info AR: $(AR))
#$(info C_STANDARD: $(C_STANDARD))
#$(info CXX_STANDARD: $(CXX_STANDARD))

# デフォルト設定 END ################################################################

# MYAPP_FOLDER: app/<appname> のルート絶対パス
# Define MYAPP_FOLDER: absolute path to the app/<appname> root directory
# makepart.mk / makechild.mk / makelocal.mk から $(MYAPP_FOLDER) で自 app 内を参照可能にする
# Allows makepart.mk / makechild.mk / makelocal.mk to reference within the app via $(MYAPP_FOLDER)
#
# 有効条件: CURDIR が $(WORKSPACE_FOLDER)/app/<appname>/... 配下であること
# Valid when: CURDIR is under $(WORKSPACE_FOLDER)/app/<appname>/...
# 無効条件: ワークスペースルート、$(WORKSPACE_FOLDER)/app 直下、app 外ディレクトリ
# Invalid at: workspace root, directly under $(WORKSPACE_FOLDER)/app, or outside app/
#
# cross-app 参照は $(MYAPP_FOLDER)/../otherapp/... を使用する
# Cross-app references use $(MYAPP_FOLDER)/../otherapp/...
# 内部で realpath -m により正規化され、.. は除去される
# Internally normalized via realpath -m to remove ..
#
# 性能: 親 make が export した値を子 make が環境変数として継承した場合、
#        CURDIR が同一 app 配下であれば再計算をスキップする
# Performance: when inherited from parent via environment, skip re-evaluation
#              if CURDIR is still under the same app directory

# 親 make から継承した MYAPP_FOLDER が有効か判定
# Check if MYAPP_FOLDER inherited from parent make is still valid
_MYAPP_NEEDS_EVAL := 1
ifeq ($(origin MYAPP_FOLDER),environment)
    ifneq ($(findstring $(MYAPP_FOLDER)/,$(CURDIR)/),)
        # CURDIR は継承された MYAPP_FOLDER 配下 — キャッシュヒット、再計算不要
        # CURDIR is under inherited MYAPP_FOLDER — cache hit, skip re-evaluation
        _MYAPP_NEEDS_EVAL :=
    endif
endif

ifneq ($(_MYAPP_NEEDS_EVAL),)

# CURDIR からワークスペースルートを除いた相対パスを取得
# Get relative path from CURDIR by removing the workspace root prefix
_MYAPP_REL_FROM_WS := $(patsubst $(WORKSPACE_FOLDER)/%,%,$(CURDIR))

# app/ で始まるか判定
# Check if the relative path starts with app/
_MYAPP_STARTS_WITH_APP := $(filter app/%,$(_MYAPP_REL_FROM_WS))

ifneq ($(_MYAPP_STARTS_WITH_APP),)
    # app/ プレフィックスを除去して残りのパスを取得
    # Remove app/ prefix to get the remaining path
    _MYAPP_AFTER_APP := $(patsubst app/%,%,$(_MYAPP_REL_FROM_WS))

    # 最初のパスセグメント (appname) を抽出
    # Extract the first path segment (appname)
    # word 1 of subst /,<space>,path → 最初のセグメント
    _MYAPP_APPNAME := $(firstword $(subst /, ,$(_MYAPP_AFTER_APP)))

    # app 直下 (appname のみ = セグメントが1つ) かどうかを判定
    # Check if we're directly under app/ (only one segment = appname itself)
    _MYAPP_SEGMENTS := $(words $(subst /, ,$(_MYAPP_AFTER_APP)))

    ifneq ($(_MYAPP_APPNAME),)
        MYAPP_FOLDER := $(WORKSPACE_FOLDER)/app/$(_MYAPP_APPNAME)
        export MYAPP_FOLDER
    else
        # app/ 直下 (appname が空)
        # Directly under app/ (appname is empty)
        MYAPP_FOLDER = $(error MYAPP_FOLDER is not available at $(CURDIR). It is only valid under app/<appname>/ directories)
    endif
else
    # app/ 配下でない (ワークスペースルート、framework/ 等)
    # Not under app/ (workspace root, framework/, etc.)
    MYAPP_FOLDER = $(error MYAPP_FOLDER is not available at $(CURDIR). It is only valid under app/<appname>/ directories)
endif

endif # _MYAPP_NEEDS_EVAL

# makepart.mk の検索
# dirname コマンドの代わりにシェルのパラメータ展開を使用してプロセス生成を削減
# Use shell parameter expansion instead of dirname command to reduce process creation
MAKEPART_MK := $(shell \
	dir=`pwd`; \
	while [ "$$dir" != "/" ]; do \
		if [ -f "$$dir/makepart.mk" ]; then \
			if command -v cygpath > /dev/null 2>&1; then \
				cygpath -m "$$dir/makepart.mk"; \
			else \
				echo "$$dir/makepart.mk"; \
			fi; \
		fi; \
		if [ -f "$$dir/.workspaceRoot" ]; then \
			break; \
		fi; \
		dir=$${dir%/*}; \
		if [ -z "$$dir" ]; then dir=/; fi; \
	done \
)

# 逆順にする (seq コマンドの代わりに Make の関数で実現してプロセス生成を削減)
# Reverse order using Make functions instead of seq command to reduce process creation
_reverse = $(if $(1),$(call _reverse,$(wordlist 2,$(words $(1)),$(1))) $(firstword $(1)))
MAKEPART_MK := $(strip $(call _reverse,$(MAKEPART_MK)))

# Windows の場合、MSVC C ランタイムライブラリの設定
# Set MSVC C runtime library configuration for Windows
ifdef PLATFORM_WINDOWS
    # MSVC C ランタイムライブラリの種類 (shared または static)
    # MSVC C runtime library type (shared or static)
    # shared: Multi-threaded DLL (/MD, /MDd)
    # static: Multi-threaded Static (/MT, /MTd)
    MSVC_CRT ?= shared

    # MSVC C ランタイムライブラリのサブディレクトリを CONFIG と MSVC_CRT から計算
    # Calculate MSVC C runtime library subdirectory from CONFIG and MSVC_CRT
    ifeq ($(CONFIG),Debug)
        ifeq ($(MSVC_CRT),shared)
            MSVC_CRT_SUBDIR := mdd
        else
            MSVC_CRT_SUBDIR := mtd
        endif
    else ifeq ($(CONFIG),Release)
        ifeq ($(MSVC_CRT),shared)
            MSVC_CRT_SUBDIR := md
        else
            MSVC_CRT_SUBDIR := mt
        endif
    else ifeq ($(CONFIG),RelWithDebInfo)
        ifeq ($(MSVC_CRT),shared)
            MSVC_CRT_SUBDIR := md
        else
            MSVC_CRT_SUBDIR := mt
        endif
    else
        $(error CONFIG は Debug, Release, RelWithDebInfo のいずれか)
    endif
endif

# makepart.mk をインクルードし、カレントディレクトリ以外では直後に makechild.mk もインクルード
# Include makepart.mk, and for non-current directories, immediately include makechild.mk afterward
# (カレントディレクトリの makechild.mk は子階層以降のみに適用するため除く)
# (The current directory's makechild.mk applies only to child directories, so it is excluded here)
define _include_makepart_and_child
$(eval include $(1))$(if $(filter-out $(CURDIR)/makepart.mk,$(1)),$(eval -include $(patsubst %/makepart.mk,%/makechild.mk,$(1))))
endef

$(foreach makepart, $(MAKEPART_MK), $(call _include_makepart_and_child,$(makepart)))

# makelocal.mk の読み込み (カレントディレクトリのみ)
# prepare.mk は各ディレクトリの makefile から include されるため、
# ここでカレントディレクトリの makelocal.mk を読み込めばよい
-include $(CURDIR)/makelocal.mk

# パス系変数の一括正規化
# Normalize path variables to absolute paths after all makepart/makechild/makelocal are loaded
# - INCDIR: sort で重複除去 (既存動作維持)
# - LIBSDIR, OUTPUT_DIR: sort で重複除去
# - TEST_SRCS, ADD_SRCS: 順序保持 (strip のみ)
ifdef PLATFORM_LINUX
    ifneq ($(INCDIR),)
        INCDIR := $(sort $(shell for d in $(INCDIR); do realpath -m "$$d" 2>/dev/null || echo "$$d"; done))
    endif
    ifneq ($(LIBSDIR),)
        LIBSDIR := $(sort $(shell for d in $(LIBSDIR); do realpath -m "$$d" 2>/dev/null || echo "$$d"; done))
    endif
    ifneq ($(OUTPUT_DIR),)
        OUTPUT_DIR := $(strip $(shell realpath -m "$(OUTPUT_DIR)" 2>/dev/null || echo "$(OUTPUT_DIR)"))
    endif
    ifneq ($(TEST_SRCS),)
        TEST_SRCS := $(strip $(shell for f in $(TEST_SRCS); do realpath -m "$$f" 2>/dev/null || echo "$$f"; done))
    endif
    ifneq ($(ADD_SRCS),)
        ADD_SRCS := $(strip $(shell for f in $(ADD_SRCS); do realpath -m "$$f" 2>/dev/null || echo "$$f"; done))
    endif
else ifdef PLATFORM_WINDOWS
    ifneq ($(INCDIR),)
        INCDIR := $(sort $(shell for d in $(INCDIR); do r=$$(realpath -m "$$d" 2>/dev/null || echo "$$d"); cygpath -m "$$r" 2>/dev/null || echo "$$r"; done))
    endif
    ifneq ($(LIBSDIR),)
        LIBSDIR := $(sort $(shell for d in $(LIBSDIR); do r=$$(realpath -m "$$d" 2>/dev/null || echo "$$d"); cygpath -m "$$r" 2>/dev/null || echo "$$r"; done))
    endif
    ifneq ($(OUTPUT_DIR),)
        OUTPUT_DIR := $(strip $(shell r=$$(realpath -m "$(OUTPUT_DIR)" 2>/dev/null || echo "$(OUTPUT_DIR)"); cygpath -m "$$r" 2>/dev/null || echo "$$r"))
    endif
    ifneq ($(TEST_SRCS),)
        TEST_SRCS := $(strip $(shell for f in $(TEST_SRCS); do r=$$(realpath -m "$$f" 2>/dev/null || echo "$$f"); cygpath -m "$$r" 2>/dev/null || echo "$$r"; done))
    endif
    ifneq ($(ADD_SRCS),)
        ADD_SRCS := $(strip $(shell for f in $(ADD_SRCS); do r=$$(realpath -m "$$f" 2>/dev/null || echo "$$f"); cygpath -m "$$r" 2>/dev/null || echo "$$r"; done))
    endif
endif

# TARGET_ARCH をコンパイル時定数として C/C++ コードに渡す
# Pass TARGET_ARCH as a compile-time string constant to C/C++ code
# DEFINES に既存の TARGET_ARCH 定義 (代入・宣言のみを問わず) があれば除去してから追加
# Remove any existing TARGET_ARCH definition from DEFINES (assignment or declaration) before adding
DEFINES := $(filter-out TARGET_ARCH%,$(DEFINES)) TARGET_ARCH='"$(TARGET_ARCH)"'

# DEFINES の各エントリを make 変数として定義する (makepart.mk などから参照可能にする)
# キーのみ: KEY → KEY := 1
# KEY=値 / KEY="値" / KEY='"値"' → KEY := 値 (シングル・ダブルクォートを除去)
define _def_var_from_defines
$(firstword $(subst =, ,$(1))) := $(if $(findstring =,$(1)),$(subst ',$(empty),$(subst ",,$(patsubst $(firstword $(subst =, ,$(1)))=%,%,$(1)))),1)
endef
$(foreach _d,$(DEFINES),$(eval $(call _def_var_from_defines,$(_d))))
