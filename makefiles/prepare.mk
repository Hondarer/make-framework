# 各 Makefile から呼び出され、
# 1. c_cpp_properties.json から defines を設定する
# 2. ソースファイルのエンコード指定から LANG を得る
# 3. コンパイルコマンド関連を設定する
# 4. 親階層から Makefile の存在する階層までに存在する makeflags.mk を
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
    # Linux
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
    # Windows
    ifeq ($(origin CC),default)
        CC = cl
    endif
    ifeq ($(origin CXX),default)
        CXX = cl
    endif
    ifeq ($(origin LD),default)
        LD = link
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

# makeflags.mk の検索
MAKEFLAGS_MK := $(shell \
	dir=`pwd`; \
	while [ "$$dir" != "/" ]; do \
		if [ -f "$$dir/makeflags.mk" ]; then \
			if command -v cygpath > /dev/null 2>&1; then \
				cygpath -w "$$dir/makeflags.mk"; \
			else \
				echo "$$dir/makeflags.mk"; \
			fi; \
		fi; \
		if [ -f "$$dir/.workspaceRoot" ]; then \
			break; \
		fi; \
		dir=$$(dirname $$dir); \
	done \
)

# 逆順にする
MAKEFLAGS_MK := $(foreach mkfile, $(shell seq $(words $(MAKEFLAGS_MK)) -1 1), $(word $(mkfile), $(MAKEFLAGS_MK)))

# makeflags.mk が存在すればインクルード
$(foreach makeflags, $(MAKEFLAGS_MK), $(eval include $(makeflags)))
