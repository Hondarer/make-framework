# flex (.l) / bison (.y) を GENDIR で C ソースへ変換し、OBJDIR でコンパイルする。
#
# flex / bison はクロスプラットフォームな外部コマンドとして扱い、mc.exe/rc.exe の
# ような Windows 専用ツールと異なり PLATFORM_* によるコンパイル対象の出し分けは
# 行わない。Windows で win_flex/win_bison を使う場合は、BISON / FLEX で実行する
# コマンド名を指定する。
#
# bison の生成物 (.tab.c / .tab.h) と flex の生成物 (.lex.c) はコンパイル対象に近い
# 中間ファイルであり、$(GENDIR) に置く。コンパイル結果 (.o/.obj) は他の .o/.obj と
# 同様に $(OBJDIR) に置く。
#
# GENDIR_EXTRA_C: アプリ側の makepart.mk が、flex/bison 以外の手段 (ヘッダー解析
# ツール等) で $(GENDIR) に生成する C ソースを、このファイルのコンパイル機構に
# 合流させるための拡張点。$(GENDIR) は常に "gen" (ワークスペース共通の固定値、
# _flags.mk で定義) であり、makepart.mk はこのファイルより先に評価されるため
# makepart.mk 側では $(GENDIR) 変数をまだ参照できない。makepart.mk 側ではリテラル
# "gen" を直接使うこと (framework/makefw/docs/makeparts.md の例 6 を参照)。
#
# 前提: _collect_srcs.mk (SRCS_L / SRCS_Y) と _flags.mk (OBJDIR / GENDIR) の後、
# Windows では _msvc_compile.mk (_run_msvc_compile) の後に include する。

BISON ?= bison
FLEX ?= flex
BISONFLAGS ?=
ifdef PLATFORM_WINDOWS
# win_flex の生成コードを MSVC でコンパイルできるように、unistd.h ではなく
# Windows 互換 API を使用させる。
# see: https://github.com/lexxmark/winflexbison
FLEXFLAGS ?= --wincompat
else ifdef PLATFORM_LINUX
FLEXFLAGS ?=
endif

GEN_TAB_C := $(addprefix $(GENDIR)/,$(SRCS_Y:.y=.tab.c))
GEN_TAB_H := $(addprefix $(GENDIR)/,$(SRCS_Y:.y=.tab.h))
GEN_LEX_C := $(addprefix $(GENDIR)/,$(SRCS_L:.l=.lex.c))

GENDIR_C := $(GEN_TAB_C) $(GEN_LEX_C) $(GENDIR_EXTRA_C)
GENDIR_OBJS := $(patsubst $(GENDIR)/%.c,$(OBJDIR)/%.o,$(GENDIR_C))

ifneq ($(strip $(GEN_TAB_C)$(GEN_LEX_C)),)

# .y -> (bison) .tab.c / .tab.h
$(GENDIR)/%.tab.c $(GENDIR)/%.tab.h: %.y | $(GENDIR)
	@echo "bison $(BISONFLAGS) $<"
	$(BISON) -d $(BISONFLAGS) -o $(GENDIR)/$*.tab.c $<

# .l -> (flex) .lex.c
$(GENDIR)/%.lex.c: %.l | $(GENDIR)
	@echo "flex $(FLEXFLAGS) $<"
	$(FLEX) $(FLEXFLAGS) -o $@ $<

endif # GEN_TAB_C / GEN_LEX_C

ifneq ($(strip $(GENDIR_C)),)

# コンパイル結果を MAKEFW_EXTRA_OBJS へ合流させる。
# 実行体 / ライブラリのリンクは (Linux/Windows とも) SRCS_C から求めた既定の
# オブジェクト一覧とは別に MAKEFW_EXTRA_OBJS を明示的にリンク入力へ加える
# 仕組みを既に持つ (framework/makefw/makefiles/_ident.mk の _IDENT_MANIFEST_OBJ
# が同じ仕組みを使う先例)。GENDIR_OBJS は常に .o 拡張子で計算されるため、
# Windows では他のオブジェクトと同様に .obj へ変換する。
MAKEFW_EXTRA_OBJS += $(if $(PLATFORM_WINDOWS),$(patsubst %.o,%.obj,$(GENDIR_OBJS)),$(GENDIR_OBJS))

# GENDIR の C ソースをコンパイルする (SRCS_C の自動収集は経由しない)。
# 同一ディレクトリの .y に由来する .tab.h があれば、gen/*.c のコンパイル前に
# 揃える (flex 生成コードが #include "*.tab.h" するため)。
#
# 警告抑制について: flex/bison 自体が生成する .tab.c / .lex.c は上流ツールの
# 出力であり本リポジトリ側では改変できない。cJSON 等の外部 OSS 取り込みと同様に
# (see: app/cjson/makepart.mk)、生成コードに起因する警告に限り例外的に抑制する。
# GENDIR_EXTRA_C 経由でアプリが自前生成する .c (flex/bison 由来ではない) は、
# アプリ側のコード品質に責任があるため、ここでの抑制対象に含めない。
ifdef PLATFORM_LINUX
MAKEFW_FLEXBISON_WARN_SUPPRESS := -Wno-conversion -Wno-sign-conversion -Wno-switch-default -Wno-padded

$(OBJDIR)/%.o: $(GENDIR)/%.c $(GEN_TAB_H) | $(OBJDIR)
	@echo "$(CC) -I. -I$(GENDIR) -c -o $@ $<"
	@$(CC) $(CFLAGS) -I. -I$(GENDIR) $(if $(filter $(GEN_TAB_C) $(GEN_LEX_C),$<),$(MAKEFW_FLEXBISON_WARN_SUPPRESS)) -c -o $@ $<
endif # PLATFORM_LINUX

# Windows: SRCS_C 由来の MSVC 一括コンパイル (_msvc_compile.mk) と同じ機構
# (_run_msvc_compile) を GENDIR のソースにも適用する。cl.exe は /Fo にディレクトリを
# 指定すればソース側のサブディレクトリを問わず基底ファイル名で .obj を出力するため、
# gen/ 配下のソースをそのまま渡せる。
ifdef PLATFORM_WINDOWS
MAKEFW_FLEXBISON_WARN_SUPPRESS := /wd4702

.PHONY: _flex_bison_msvc_compile
_msvc_compile: _flex_bison_msvc_compile
_flex_bison_msvc_compile: $(GENDIR_C) | $(OBJDIR) $(OUTPUT_DIR)
	$(call _run_msvc_compile,$(CC),$(CFLAGS) /I. /I$(GENDIR) $(MAKEFW_FLEXBISON_WARN_SUPPRESS),$(OBJDIR),\
		$(GEN_TAB_C) $(GEN_LEX_C),)
	$(call _run_msvc_compile,$(CC),$(CFLAGS) /I. /I$(GENDIR),$(OBJDIR),$(GENDIR_EXTRA_C),)
endif # PLATFORM_WINDOWS

endif # GENDIR_C
