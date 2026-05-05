# Windows 向けバッチコンパイルルール
# 複数ソースファイルを一度に cl.exe に渡し、MSYS プロセス起動オーバーヘッドを削減する
#
# 使い方:
#   make build                  # バッチコンパイル有効 (Windows デフォルト)
#   make build BATCH_COMPILE=0  # バッチコンパイル無効 (従来方式)

# バッチコンパイルの有効化条件
# - Windows プラットフォームのみ
# - BATCH_COMPILE=0 で明示的に無効化可能
ifdef PLATFORM_WINDOWS
    BATCH_COMPILE ?= 1
else
    BATCH_COMPILE := 0
endif

ifeq ($(BATCH_COMPILE),1)

# バッチコンパイルスクリプトのパス
BATCH_COMPILE_SCRIPT := $(WORKSPACE_DIR)/framework/makefw/bin/msvc_batch_compile.ps1

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

# バッチコンパイル用の共有 PDB (個別 PDB の代わり)
# 遅延評価 (=) を使用して、INCDIR 追加後の CFLAGS を参照する
BATCH_PDB = $(OBJDIR)/vc.pdb
BATCH_CFLAGS = $(filter-out /Fd:%,$(CFLAGS)) /Fd:$(BATCH_PDB)
BATCH_CXXFLAGS = $(filter-out /Fd:%,$(CXXFLAGS)) /Fd:$(BATCH_PDB)
BATCH_CFLAGS_TEST = $(filter-out /Fd:%,$(CFLAGS_TEST)) /Fd:$(BATCH_PDB)
BATCH_CXXFLAGS_TEST = $(filter-out /Fd:%,$(CXXFLAGS_TEST)) /Fd:$(BATCH_PDB)

# バッチコンパイルターゲット
.PHONY: _batch_compile _batch_compile_c_normal _batch_compile_c_test _batch_compile_cpp_normal _batch_compile_cpp_test

_batch_compile: _batch_compile_c_normal _batch_compile_c_test _batch_compile_cpp_normal _batch_compile_cpp_test

# 8192 バイト分割でバッチコンパイルを実行するヘルパー
# 引数: compiler, flags, objdir, sources, extra_flags (optional)
define _run_batch_compile
	@srcs="$(4)"; \
	if [ -n "$$srcs" ]; then \
		chunk=""; \
		for src in $$srcs; do \
			if [ $$(($${#chunk} + $${#src} + 1)) -gt 8000 ]; then \
				powershell -ExecutionPolicy Bypass -File $(BATCH_COMPILE_SCRIPT) \
					-Compiler "$(1)" -Flags "$(2)" -ObjDir "$(3)" \
					-Sources "$$chunk" -WorkspaceDir "$(WORKSPACE_DIR)" $(5) || exit $$?; \
				chunk="$$src"; \
			else \
				if [ -n "$$chunk" ]; then chunk="$$chunk $$src"; else chunk="$$src"; fi; \
			fi; \
		done; \
		if [ -n "$$chunk" ]; then \
			powershell -ExecutionPolicy Bypass -File $(BATCH_COMPILE_SCRIPT) \
				-Compiler "$(1)" -Flags "$(2)" -ObjDir "$(3)" \
				-Sources "$$chunk" -WorkspaceDir "$(WORKSPACE_DIR)" $(5) || exit $$?; \
		fi; \
	fi
endef

_batch_compile_c_normal: $(notdir $(LINK_SRCS)) $(notdir $(CP_SRCS)) | $(OBJDIR)
	$(call _run_batch_compile,$(CC),$(BATCH_CFLAGS),$(OBJDIR),$(SRCS_C_NORMAL),)

_batch_compile_c_test: $(notdir $(LINK_SRCS)) $(notdir $(CP_SRCS)) | $(OBJDIR)
	$(call _run_batch_compile,$(CC),$(BATCH_CFLAGS_TEST),$(OBJDIR),$(SRCS_C_TEST),-ExtraFlags "-D_IN_TEST_SRC")

_batch_compile_cpp_normal: $(notdir $(LINK_SRCS)) $(notdir $(CP_SRCS)) | $(OBJDIR)
	$(call _run_batch_compile,$(CXX),$(BATCH_CXXFLAGS),$(OBJDIR),$(SRCS_CPP_NORMAL),)

_batch_compile_cpp_test: $(notdir $(LINK_SRCS)) $(notdir $(CP_SRCS)) | $(OBJDIR)
	$(call _run_batch_compile,$(CXX),$(BATCH_CXXFLAGS_TEST),$(OBJDIR),$(SRCS_CPP_TEST),-ExtraFlags "-D_IN_TEST_SRC")

else
# BATCH_COMPILE=0 または Linux の場合は空ターゲット
.PHONY: _batch_compile
_batch_compile:
	@:

endif # BATCH_COMPILE
