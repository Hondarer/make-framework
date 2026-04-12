# makefile サブディレクトリ走査テンプレート
# prod/test 配下の中間階層 makefile で使用する標準テンプレート
# 本ファイルの編集は禁止する。makelocal.mk を作成して拡張・カスタマイズすること。

# ワークスペースのディレクトリ
find-up = \
    $(if $(wildcard $(1)/$(2)),$(1),\
        $(if $(filter $(1),$(patsubst %/,%,$(dir $(1)))),,\
            $(call find-up,$(patsubst %/,%,$(dir $(1))),$(2))\
        )\
    )

# 再帰 make 間でワークスペースルートは不変のため、内部キャッシュ変数で継承する
ifeq ($(origin MAKEFW_WORKSPACE_FOLDER), undefined)
    MAKEFW_WORKSPACE_FOLDER := $(strip $(call find-up,$(CURDIR),.workspaceRoot))
endif
export MAKEFW_WORKSPACE_FOLDER

WORKSPACE_FOLDER := $(MAKEFW_WORKSPACE_FOLDER)

# 準備処理 (走査テンプレートより前に include)
include $(WORKSPACE_FOLDER)/framework/makefw/makefiles/prepare.mk

# サブディレクトリ走査テンプレートを include
include $(WORKSPACE_FOLDER)/framework/makefw/makefiles/makesubdir.mk
