# 各 makefile から呼び出され、
# 1. c_cpp_properties.json から defines を設定する
# 2. ソースファイルのエンコード指定から LANG を得る
# 3. コンパイルコマンド関連を設定する
# 4. 親階層から makefile の存在する階層までに存在する makepart.mk を
#    親階層から makefile の存在する階層に向かって順次 include する
# 5. カレントディレクトリの makelocal.mk を include する

SHELL := /bin/bash

# c_cpp_properties.json から defines を得る (get_config.sh に統合)
# Get defines from c_cpp_properties.json (consolidated into get_config.sh)
DEFINES := $(shell sh $(WORKSPACE_FOLDER)/makefw/cmnd/get_config.sh defines)
# defines の値を変数名 (値 = 1) として設定する
$(foreach define, $(DEFINES), $(eval $(define) = 1))

#$(info DEFINES: $(DEFINES));

# ソースファイルのエンコード指定から LANG を得る
FILES_LANG := $(shell sh $(WORKSPACE_FOLDER)/makefw/cmnd/get_files_lang.sh)

#$(info FILES_LANG: $(FILES_LANG));

# FILES_LANG が UTF-8 の場合は nkf を省略 (cat に置換)
ifneq (,$(filter %.utf8 %.UTF-8 %.utf-8 %.UTF8,$(FILES_LANG)))
    NKF := cat
else
    NKF := nkf
endif

# アーキテクチャ判定
# Determine target architecture
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

ifneq ($(OS),Windows_NT)
    # Linux (ex: linux-el8-x64)
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
    TARGET_ARCH := linux-$(OS_ID)-$(ARCH)
else
    # Windows (ex: windows-x64)
    TARGET_ARCH := windows-$(ARCH)
endif

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
ifneq ($(OS),Windows_NT)
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
else
    # Windows (MSVC)

    # Windows 環境のインターロックチェック
    # bash と cl の存在確認を1回の where 呼び出しにまとめて取得
    # Check bash and cl existence, consolidating where calls
    # 1. bash の存在確認と MinGW (MSYS) bash の検証
    BASH_PATH := $(shell where bash 2>/dev/null | head -1)
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
    CL_PATH := $(shell where cl 2>/dev/null | head -1)
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
        # 2. 8.3 形式に変換 (スペースを含まないパスに変換)
        # 3. Unix パス形式に変換 (bash でバックスラッシュが消えるのを防ぐ)
        LD = $(shell cygpath -u "$$(cygpath -d "$(subst cl.exe,link.exe,$(CL_PATH))")")
    endif
    ifeq ($(origin AR),default)
        AR = lib
    endif
endif

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

# makepart.mk の検索
# dirname コマンドの代わりにシェルのパラメータ展開を使用してプロセス生成を削減
# Use shell parameter expansion instead of dirname command to reduce process creation
MAKEPART_MK := $(shell \
	dir=`pwd`; \
	while [ "$$dir" != "/" ]; do \
		if [ -f "$$dir/makepart.mk" ]; then \
			if command -v cygpath > /dev/null 2>&1; then \
				cygpath -w "$$dir/makepart.mk"; \
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
ifeq ($(OS),Windows_NT)
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

# makepart.mk が存在すればインクルード
$(foreach makepart, $(MAKEPART_MK), $(eval include $(makepart)))

# makelocal.mk の読み込み (カレントディレクトリのみ)
# prepare.mk は各ディレクトリの makefile から include されるため、
# ここでカレントディレクトリの makelocal.mk を読み込めばよい
-include $(CURDIR)/makelocal.mk
