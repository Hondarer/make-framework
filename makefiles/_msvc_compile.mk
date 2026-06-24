# Windows 向け MSVC コンパイル ルール
# 複数ソース ファイルを一度に cl.exe に渡し、MSYS プロセス起動オーバーヘッドを削減する
#
# 依存関係抽出: /sourceDependencies <dir> (JSON, ロケール非依存)
# 必須環境: Visual Studio 2022 以上

ifdef PLATFORM_WINDOWS

# MSVC のプロセス内並列コンパイルを有効化
CFLAGS   += $(MAKEFW_CL_MPFLAG)
CXXFLAGS += $(MAKEFW_CL_MPFLAG)

# MSVC コンパイル スクリプトのパス
MSVC_COMPILE_SCRIPT := $(WORKSPACE_DIR)/framework/makefw/bin/msvc_compile.ps1

# 再コンパイルが必要なソースを抽出する外部スクリプト
FIND_DIRTY_SRCS_SCRIPT := $(WORKSPACE_DIR)/framework/makefw/bin/find_dirty_srcs.sh

# 再コンパイルが必要なソースを抽出
# - .obj が存在しない
# - .obj より .c/.cpp が新しい
# - .d が存在しない
# - .d 内のワークスペース内ヘッダーが .obj より新しい
# 注: ワークスペース外のヘッダー (Windows SDK 等) はチェックしない
# 引数: $(1)=ソース リスト, $(2)=OBJDIR
define _find_dirty_srcs
$(shell bash "$(FIND_DIRTY_SRCS_SCRIPT)" "$(1)" "$(2)" "$(WORKSPACE_DIR)")
endef

# MSVC コンパイル時の PDB 生成ルール
# - static lib: OUTPUT_DIR 配下のターゲット名 PDB
# - それ以外  : OBJDIR 配下のターゲット名 PDB
# _msvc_compile.mk は LIB_TYPE/TARGET 決定前に include されるため遅延評価にする
MSVC_PDB = $(if $(filter static,$(LIB_TYPE)),$(OUTPUT_DIR)/$(basename $(TARGET)).pdb,$(if $(filter both,$(LIB_TYPE)),$(OUTPUT_DIR)/$(basename $(TARGET_STATIC)).pdb,$(OBJDIR)/$(basename $(TARGET)).pdb))

# 変更のあるソースを抽出
# 共有 PDB が欠落している場合は、関連ソースをすべて再コンパイルして再生成する
SRCS_C_DIRTY = $(if $(wildcard $(MSVC_PDB)),$(call _find_dirty_srcs,$(SRCS_C),$(OBJDIR)),$(SRCS_C))
SRCS_CPP_DIRTY = $(if $(wildcard $(MSVC_PDB)),$(call _find_dirty_srcs,$(SRCS_CPP),$(OBJDIR)),$(SRCS_CPP))

# TEST_SRCS との分離 (-D_IN_TEST_SRC 付与のため)
# TEST_SRCS: -D_IN_TEST_SRC 付きでコンパイル
# その他: フラグなしでコンパイル
# → 混在時は cl.exe 呼び出しを分割
_TEST_SRC_NAMES := $(notdir $(TEST_SRCS))
SRCS_C_NORMAL = $(filter-out $(_TEST_SRC_NAMES),$(SRCS_C_DIRTY))
SRCS_C_TEST = $(filter $(_TEST_SRC_NAMES),$(SRCS_C_DIRTY))
SRCS_CPP_NORMAL = $(filter-out $(_TEST_SRC_NAMES),$(SRCS_CPP_DIRTY))
SRCS_CPP_TEST = $(filter $(_TEST_SRC_NAMES),$(SRCS_CPP_DIRTY))

MSVC_CFLAGS = $(filter-out /Fd:%,$(CFLAGS)) /Fd:$(MSVC_PDB)
MSVC_CXXFLAGS = $(filter-out /Fd:%,$(CXXFLAGS)) /Fd:$(MSVC_PDB)
MSVC_CFLAGS_TEST = $(filter-out /Fd:%,$(CFLAGS_TEST)) /Fd:$(MSVC_PDB)
MSVC_CXXFLAGS_TEST = $(filter-out /Fd:%,$(CXXFLAGS_TEST)) /Fd:$(MSVC_PDB)

# MSVC コンパイル ターゲット
.PHONY: _msvc_compile _msvc_compile_c_normal _msvc_compile_c_test _msvc_compile_cpp_normal _msvc_compile_cpp_test

_msvc_compile: _msvc_compile_c_normal _msvc_compile_c_test _msvc_compile_cpp_normal _msvc_compile_cpp_test

# 8192 バイト単位に分割して MSVC コンパイルを実行するヘルパー
# 引数: compiler, flags, objdir, sources, extra_flags (optional)
define _run_msvc_compile
	@srcs="$(4)"; \
	if [ -n "$$srcs" ]; then \
		chunk=""; \
		for src in $$srcs; do \
			if [ $$(($${#chunk} + $${#src} + 1)) -gt 8000 ]; then \
				powershell -ExecutionPolicy Bypass -File $(MSVC_COMPILE_SCRIPT) \
					-Compiler "$(1)" -Flags "$(2)" -ObjDir "$(3)" \
					-Sources "$$chunk" -WorkspaceDir "$(WORKSPACE_DIR)" $(5) || exit $$?; \
				chunk="$$src"; \
			else \
				if [ -n "$$chunk" ]; then chunk="$$chunk $$src"; else chunk="$$src"; fi; \
			fi; \
		done; \
		if [ -n "$$chunk" ]; then \
			powershell -ExecutionPolicy Bypass -File $(MSVC_COMPILE_SCRIPT) \
				-Compiler "$(1)" -Flags "$(2)" -ObjDir "$(3)" \
				-Sources "$$chunk" -WorkspaceDir "$(WORKSPACE_DIR)" $(5) || exit $$?; \
		fi; \
	fi
endef

# MSVC コンパイルの実行前に必要なディレクトリを作成する。
# static lib では /Fd が OUTPUT_DIR 配下を指すため、make -j でも OUTPUT_DIR を先に作成する必要がある。
_msvc_compile_c_normal: $(notdir $(LINK_SRCS)) $(notdir $(CP_SRCS)) | $(OBJDIR) $(OUTPUT_DIR)
	$(call _run_msvc_compile,$(CC),$(MSVC_CFLAGS),$(OBJDIR),$(SRCS_C_NORMAL),)

_msvc_compile_c_test: $(notdir $(LINK_SRCS)) $(notdir $(CP_SRCS)) | $(OBJDIR) $(OUTPUT_DIR)
	$(call _run_msvc_compile,$(CC),$(MSVC_CFLAGS_TEST),$(OBJDIR),$(SRCS_C_TEST),-ExtraFlags "-D_IN_TEST_SRC")

_msvc_compile_cpp_normal: $(notdir $(LINK_SRCS)) $(notdir $(CP_SRCS)) | $(OBJDIR) $(OUTPUT_DIR)
	$(call _run_msvc_compile,$(CXX),$(MSVC_CXXFLAGS),$(OBJDIR),$(SRCS_CPP_NORMAL),)

_msvc_compile_cpp_test: $(notdir $(LINK_SRCS)) $(notdir $(CP_SRCS)) | $(OBJDIR) $(OUTPUT_DIR)
	$(call _run_msvc_compile,$(CXX),$(MSVC_CXXFLAGS_TEST),$(OBJDIR),$(SRCS_CPP_TEST),-ExtraFlags "-D_IN_TEST_SRC")

else
.PHONY: _msvc_compile
_msvc_compile:
	@:

endif # PLATFORM_WINDOWS
