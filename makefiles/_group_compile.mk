# Windows 向けグループコンパイルルール
# 複数ソースファイルを一度に cl.exe に渡し、MSYS プロセス起動オーバーヘッドを削減する
#
# 使い方:
#   make build                  # グループコンパイル有効 (Windows デフォルト)
#   make build GROUP_COMPILE=0  # グループコンパイル無効 (従来方式)

# グループコンパイルの有効化条件
# - Windows プラットフォームのみ
# - GROUP_COMPILE=0 で明示的に無効化可能
ifdef PLATFORM_WINDOWS
    GROUP_COMPILE ?= 1
else
    GROUP_COMPILE := 0
endif

ifeq ($(GROUP_COMPILE),1)

# グループコンパイルスクリプトのパス
GROUP_COMPILE_SCRIPT := $(WORKSPACE_DIR)/framework/makefw/bin/msvc_group_compile.ps1

# 再コンパイルが必要なソースを抽出する外部スクリプト
FIND_DIRTY_SRCS_SCRIPT := $(WORKSPACE_DIR)/framework/makefw/bin/find_dirty_srcs.sh

# 再コンパイルが必要なソースを抽出
# - .obj が存在しない
# - .obj より .c/.cpp が新しい
# - .d が存在しない
# - .d 内のワークスペース内ヘッダーが .obj より新しい
# 注: ワークスペース外のヘッダー (Windows SDK 等) はチェックしない
# 引数: $(1)=ソースリスト, $(2)=OBJDIR
define _find_dirty_srcs
$(shell bash "$(FIND_DIRTY_SRCS_SCRIPT)" "$(1)" "$(2)" "$(WORKSPACE_DIR)")
endef

# 変更のあるソースを抽出
SRCS_C_DIRTY := $(call _find_dirty_srcs,$(SRCS_C),$(OBJDIR))
SRCS_CPP_DIRTY := $(call _find_dirty_srcs,$(SRCS_CPP),$(OBJDIR))

# TEST_SRCS との分離 (-D_IN_TEST_SRC 付与のため)
# TEST_SRCS: -D_IN_TEST_SRC 付きでコンパイル
# その他: フラグなしでコンパイル
# → 混在時は cl.exe 呼び出しを分割
_TEST_SRC_NAMES := $(notdir $(TEST_SRCS))
SRCS_C_NORMAL = $(filter-out $(_TEST_SRC_NAMES),$(SRCS_C_DIRTY))
SRCS_C_TEST = $(filter $(_TEST_SRC_NAMES),$(SRCS_C_DIRTY))
SRCS_CPP_NORMAL = $(filter-out $(_TEST_SRC_NAMES),$(SRCS_CPP_DIRTY))
SRCS_CPP_TEST = $(filter $(_TEST_SRC_NAMES),$(SRCS_CPP_DIRTY))

# グループコンパイル用の共有 PDB (個別 PDB の代わり)
# 遅延評価 (=) を使用して、INCDIR 追加後の CFLAGS を参照する
GROUP_PDB = $(OBJDIR)/vc.pdb
GROUP_CFLAGS = $(filter-out /Fd:%,$(CFLAGS)) /Fd:$(GROUP_PDB)
GROUP_CXXFLAGS = $(filter-out /Fd:%,$(CXXFLAGS)) /Fd:$(GROUP_PDB)
GROUP_CFLAGS_TEST = $(filter-out /Fd:%,$(CFLAGS_TEST)) /Fd:$(GROUP_PDB)
GROUP_CXXFLAGS_TEST = $(filter-out /Fd:%,$(CXXFLAGS_TEST)) /Fd:$(GROUP_PDB)

# グループコンパイルターゲット
.PHONY: _group_compile _group_compile_c_normal _group_compile_c_test _group_compile_cpp_normal _group_compile_cpp_test

_group_compile: _group_compile_c_normal _group_compile_c_test _group_compile_cpp_normal _group_compile_cpp_test

# 8192 バイト分割でグループコンパイルを実行するヘルパー
# 引数: compiler, flags, objdir, sources, extra_flags (optional)
define _run_group_compile
	@srcs="$(4)"; \
	if [ -n "$$srcs" ]; then \
		chunk=""; \
		for src in $$srcs; do \
			if [ $$(($${#chunk} + $${#src} + 1)) -gt 8000 ]; then \
				powershell -ExecutionPolicy Bypass -File $(GROUP_COMPILE_SCRIPT) \
					-Compiler "$(1)" -Flags "$(2)" -ObjDir "$(3)" \
					-Sources "$$chunk" -WorkspaceDir "$(WORKSPACE_DIR)" $(5) || exit $$?; \
				chunk="$$src"; \
			else \
				if [ -n "$$chunk" ]; then chunk="$$chunk $$src"; else chunk="$$src"; fi; \
			fi; \
		done; \
		if [ -n "$$chunk" ]; then \
			powershell -ExecutionPolicy Bypass -File $(GROUP_COMPILE_SCRIPT) \
				-Compiler "$(1)" -Flags "$(2)" -ObjDir "$(3)" \
				-Sources "$$chunk" -WorkspaceDir "$(WORKSPACE_DIR)" $(5) || exit $$?; \
		fi; \
	fi
endef

_group_compile_c_normal: $(notdir $(LINK_SRCS)) $(notdir $(CP_SRCS)) | $(OBJDIR)
	$(call _run_group_compile,$(CC),$(GROUP_CFLAGS),$(OBJDIR),$(SRCS_C_NORMAL),)

_group_compile_c_test: $(notdir $(LINK_SRCS)) $(notdir $(CP_SRCS)) | $(OBJDIR)
	$(call _run_group_compile,$(CC),$(GROUP_CFLAGS_TEST),$(OBJDIR),$(SRCS_C_TEST),-ExtraFlags "-D_IN_TEST_SRC")

_group_compile_cpp_normal: $(notdir $(LINK_SRCS)) $(notdir $(CP_SRCS)) | $(OBJDIR)
	$(call _run_group_compile,$(CXX),$(GROUP_CXXFLAGS),$(OBJDIR),$(SRCS_CPP_NORMAL),)

_group_compile_cpp_test: $(notdir $(LINK_SRCS)) $(notdir $(CP_SRCS)) | $(OBJDIR)
	$(call _run_group_compile,$(CXX),$(GROUP_CXXFLAGS_TEST),$(OBJDIR),$(SRCS_CPP_TEST),-ExtraFlags "-D_IN_TEST_SRC")

else
# GROUP_COMPILE=0 または Linux の場合は空ターゲット
.PHONY: _group_compile
_group_compile:
	@:

endif # GROUP_COMPILE
