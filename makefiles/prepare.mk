# 各 Makefile から呼び出され、
# 1. c_cpp_properties.json から defines を設定する
# 2. ソースファイルのエンコード指定から LANG を得る
# 3. コンパイルコマンド関連を設定する
# 4. 親階層から Makefile の存在する階層までに存在する makepart.mk を
#    親階層から Makefile の存在する階層に向かって順次 include する

SHELL := /bin/bash

# c_cpp_properties.json から defines を得る
DEFINES := $(shell sh $(WORKSPACE_FOLDER)/makefw/cmnd/get_defines.sh)
# defines の値を変数名 (値 = 1) として設定する
$(foreach define, $(DEFINES), $(eval $(define) = 1))

#$(info DEFINES: $(DEFINES));

# ソースファイルのエンコード指定から LANG を得る
FILES_LANG := $(shell sh $(WORKSPACE_FOLDER)/makefw/cmnd/get_files_lang.sh)

#$(info FILES_LANG: $(FILES_LANG));

# FILES_LANG が UTF-8 の場合は nkf を省略 (cat で代用)
ifneq (,$(filter %.utf8 %.UTF-8 %.utf-8 %.UTF8,$(FILES_LANG)))
    NKF := cat
else
    NKF := nkf
endif

# アーキテクチャ判定
# Determine target architecture
ifneq ($(OS),Windows_NT)
    # Linux (ex: linux-el8-x64)
    # uname -m を使用してアーキテクチャを判定
    # Use uname -m to determine architecture
    UNAME_ARCH := $(shell uname -m)
    # x86_64 を x64 に変換
    # Convert x86_64 to x64
    ifeq ($(UNAME_ARCH),x86_64)
        ARCH := x64
    else
        ARCH := $(UNAME_ARCH)
    endif
    # RHEL系 (Oracle Linux, RHEL, CentOS, Rocky Linux など) の場合
    # For RHEL-based distributions (Oracle Linux, RHEL, CentOS, Rocky Linux, etc.)
    ifeq ($(shell [ -f /etc/redhat-release ] && echo 1),1)
        # バージョン番号を取得 (例: 8.10 -> 8)
        # Extract major version number (e.g., 8.10 -> 8)
        RHEL_VERSION := $(shell sed -n 's/.*release \([0-9]\+\).*/\1/p' /etc/redhat-release)
        OS_ID := el$(RHEL_VERSION)
    else
        # その他の Linux ディストリビューション
        # Other Linux distributions
        OS_ID := $(shell . /etc/os-release 2>/dev/null && echo $$ID || echo linux)
    endif
    TARGET_ARCH := linux-$(OS_ID)-$(ARCH)
else
    # Windows (ex: windows-x64)
    # uname -m を使用してアーキテクチャを判定 (MSYS/MinGW bash が提供)
    # Use uname -m to determine architecture (provided by MSYS/MinGW bash)
    UNAME_ARCH := $(shell uname -m)
    # x86_64 を x64 に変換
    # Convert x86_64 to x64
    ifeq ($(UNAME_ARCH),x86_64)
        ARCH := x64
    else
        ARCH := $(UNAME_ARCH)
    endif
    TARGET_ARCH := windows-$(ARCH)
endif

# デフォルト設定 START ##############################################################

# コンフィグ設定 (RelWithDebInfo, Debug, Release)
# "make CONFIG=Debug" のように引数で指定するか、この先の Makefile で置換する
CONFIG ?= RelWithDebInfo

# origin 関数は変数がどこから来たかを返します。
# - default: Makeの組み込みデフォルト値
# - environment: 環境変数から
# - file: Makefileで定義
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

    # 2. cl.exe の存在確認
    CL_CHECK := $(shell where cl 2>/dev/null | head -1)
    ifeq ($(CL_CHECK),)
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
        # 1. cl のパスを得る (where の出力は複数行の可能性があるため head -1 で最初の行のみ取得)
        # 2. cl を link に置換する
        # 3. 8.3 形式に変換 (スペースを含まないパスに変換)
        # 4. Unix パス形式に変換 (bash でバックスラッシュが消えるのを防ぐ)
        CL_PATH := $(shell where cl 2>/dev/null | head -1)
        ifneq ($(CL_PATH),)
            LD = $(shell cygpath -u "$$(cygpath -d "$(subst cl.exe,link.exe,$(CL_PATH))")")
        else
            LD = link
        endif
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
		dir=$$(dirname $$dir); \
	done \
)

# 逆順にする
MAKEPART_MK := $(foreach mkfile, $(shell seq $(words $(MAKEPART_MK)) -1 1), $(word $(mkfile), $(MAKEPART_MK)))

# makepart.mk が存在すればインクルード
$(foreach makepart, $(MAKEPART_MK), $(eval include $(makepart)))
