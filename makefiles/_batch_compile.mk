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

# 再コンパイルが必要なソースを抽出するシェル関数
# - .obj が存在しない
# - .obj より .c/.cpp が新しい
# - .d が存在しない
# - .d 内のヘッダーが .obj より新しい
# 引数: $(1)=ソースリスト, $(2)=OBJDIR
define _find_dirty_srcs
$(shell \
    for src in $(1); do \
        base=$$(basename $$src | sed 's/\.[^.]*$$//'); \
        obj="$(2)/$$base.obj"; \
        dep="$(2)/$$base.d"; \
        if [ ! -f "$$obj" ] || [ "$$src" -nt "$$obj" ] || [ ! -f "$$dep" ]; then \
            echo "$$src"; \
        else \
            dirty=0; \
            while IFS= read -r line; do \
                h=$$(echo "$$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*\\\\$$//; s/\\\\ / /g'); \
                if [ -n "$$h" ] && [ "$$h" != "$$obj:" ] && [ -f "$$h" ] && [ "$$h" -nt "$$obj" ]; then \
                    dirty=1; break; \
                fi; \
            done < "$$dep"; \
            if [ $$dirty -eq 1 ]; then echo "$$src"; fi; \
        fi; \
    done \
)
endef

# 変更のあるソースを抽出
SRCS_C_DIRTY = $(call _find_dirty_srcs,$(SRCS_C),$(OBJDIR))
SRCS_CPP_DIRTY = $(call _find_dirty_srcs,$(SRCS_CPP),$(OBJDIR))

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

_batch_compile_c_normal: | $(OBJDIR)
	@srcs="$(SRCS_C_NORMAL)"; \
	if [ -n "$$srcs" ]; then \
		powershell -ExecutionPolicy Bypass -File $(BATCH_COMPILE_SCRIPT) \
			-Compiler "$(CC)" \
			-Flags "$(BATCH_CFLAGS)" \
			-ObjDir "$(OBJDIR)" \
			-Sources "$$srcs"; \
	fi

_batch_compile_c_test: | $(OBJDIR)
	@srcs="$(SRCS_C_TEST)"; \
	if [ -n "$$srcs" ]; then \
		powershell -ExecutionPolicy Bypass -File $(BATCH_COMPILE_SCRIPT) \
			-Compiler "$(CC)" \
			-Flags "$(BATCH_CFLAGS_TEST)" \
			-ObjDir "$(OBJDIR)" \
			-Sources "$$srcs" \
			-ExtraFlags "-D_IN_TEST_SRC"; \
	fi

_batch_compile_cpp_normal: | $(OBJDIR)
	@srcs="$(SRCS_CPP_NORMAL)"; \
	if [ -n "$$srcs" ]; then \
		powershell -ExecutionPolicy Bypass -File $(BATCH_COMPILE_SCRIPT) \
			-Compiler "$(CXX)" \
			-Flags "$(BATCH_CXXFLAGS)" \
			-ObjDir "$(OBJDIR)" \
			-Sources "$$srcs"; \
	fi

_batch_compile_cpp_test: | $(OBJDIR)
	@srcs="$(SRCS_CPP_TEST)"; \
	if [ -n "$$srcs" ]; then \
		powershell -ExecutionPolicy Bypass -File $(BATCH_COMPILE_SCRIPT) \
			-Compiler "$(CXX)" \
			-Flags "$(BATCH_CXXFLAGS_TEST)" \
			-ObjDir "$(OBJDIR)" \
			-Sources "$$srcs" \
			-ExtraFlags "-D_IN_TEST_SRC"; \
	fi

else
# BATCH_COMPILE=0 または Linux の場合は空ターゲット
.PHONY: _batch_compile
_batch_compile:
	@:

endif # BATCH_COMPILE
