# Windows リソース (.mc / .rc) のコンパイル
#
# ソース ディレクトリの *.mc / *.rc を自動収集し (_collect_srcs.mk)、
# $(OBJDIR)/<name>.res へコンパイルして LINK_INPUTS に追加する。
# LINK_INPUTS は EXE (makesrc) / DLL (makelibsrc) のリンクに直接渡され、
# 依存関係と再リンク判定にも乗る。
# static lib では .res を COFF object に変換し、RESOURCE_OBJS として lib.exe に渡す。
#
# .mc から mc.exe が生成する .h / .rc / .bin はコンパイル対象のソースに近い中間ファイルであり、
# $(GENDIR) に置く。rc.exe によるコンパイル結果 (.res / .res.obj) は他の .o/.obj と同様に
# $(OBJDIR) に置く。
#
# Windows 専用 (mc.exe / rc.exe は Windows SDK のツール)。
# Linux では SRCS_MC / SRCS_RC が空のため何も行わない。
#
# 前提: _collect_srcs.mk (SRCS_MC / SRCS_RC) と _flags.mk (OBJDIR / GENDIR) の後に include する。

ifdef PLATFORM_WINDOWS

# メッセージ コンパイラ / リソース コンパイラのフラグ (上書き可)
# MCFLAGS の -U は Unicode メッセージ テーブルを生成する。
# -cp utf-8 は生成される .h / .rc の文字コードを UTF-8 (BOM 付き) に固定する。
# 既定 (ansi) はビルド環境のシステム ロケール (ANSI コードページ) に依存し、
# 日本語コメントなどが環境によって文字化けするため指定する。
# see: https://learn.microsoft.com/en-us/windows/win32/wes/message-compiler--mc-exe-
MCFLAGS ?= -U -cp utf-8
RCFLAGS ?=
CVTRES ?= cvtres.exe

MAKEFW_CVTRES_ARCH := $(or $(ARCH),$(lastword $(subst _, ,$(TARGET_ARCH))))
MAKEFW_CVTRES_MACHINE ?= $(if $(filter x64,$(MAKEFW_CVTRES_ARCH)),X64,$(if $(filter x86 i386 i686,$(MAKEFW_CVTRES_ARCH)),X86,$(if $(filter arm64 aarch64,$(MAKEFW_CVTRES_ARCH)),ARM64,$(MAKEFW_CVTRES_ARCH))))

# 生成する .res の一覧 (cwd の *.mc / *.rc から導出)
RES_OUTPUTS := $(addprefix $(OBJDIR)/, $(SRCS_MC:.mc=.res) $(SRCS_RC:.rc=.res))
RESOURCE_OBJS := $(patsubst %.res,%.res.obj,$(RES_OUTPUTS))

ifneq ($(strip $(RES_OUTPUTS)),)

# リンク入力に追加する (EXE: makesrc / DLL: makelibsrc が消費する)
LINK_INPUTS += $(RES_OUTPUTS)

# .mc -> (mc.exe) ヘッダー / .rc / MSG00001.bin -> (rc.exe) .res
# mc.exe の生成物 (ヘッダー / .rc / .bin) は GENDIR に置く。
# rc.exe は生成 .rc が参照する .bin を /i $(GENDIR) で解決し、コンパイル結果 .res は OBJDIR に置く。
$(OBJDIR)/%.res: %.mc | $(GENDIR) $(OBJDIR)
	@echo "mc.exe $(MCFLAGS) $<"
	@set -o pipefail; MSYS_NO_PATHCONV=1 mc.exe $(MCFLAGS) -h $(GENDIR) -r $(GENDIR) $< 2>&1 | $(MAKEFW_POWERSHELL_COMMAND) -File "$(MSVC_OUTPUT_FILTER_SCRIPT)" -InputEncoding Ansi
	@echo "rc.exe $(GENDIR)/$*.rc"
	@set -o pipefail; MSYS_NO_PATHCONV=1 rc.exe /nologo $(RCFLAGS) /i $(GENDIR) /fo $@ $(GENDIR)/$*.rc 2>&1 | $(MAKEFW_POWERSHELL_COMMAND) -File "$(MSVC_OUTPUT_FILTER_SCRIPT)" -InputEncoding Ansi

# 単体 .rc -> (rc.exe) .res
# インクルード解決は OBJDIR, カレント ディレクトリ, INCDIR を探索する。
$(OBJDIR)/%.res: %.rc | $(OBJDIR)
	@echo "rc.exe $<"
	@set -o pipefail; MSYS_NO_PATHCONV=1 rc.exe /nologo $(RCFLAGS) /i $(OBJDIR) /i . $(addprefix /i ,$(INCDIR)) /fo $@ $< 2>&1 | $(MAKEFW_POWERSHELL_COMMAND) -File "$(MSVC_OUTPUT_FILTER_SCRIPT)" -InputEncoding Ansi

# 同名 stem の .mc と .rc を同一ディレクトリに置かないこと (どちらも %.res を生成し衝突する)。

$(OBJDIR)/%.res.obj: $(OBJDIR)/%.res | $(OBJDIR)
	@echo "$(CVTRES) /MACHINE:$(MAKEFW_CVTRES_MACHINE) /OUT:$@ $<"
	@set -o pipefail; MSYS_NO_PATHCONV=1 "$(CVTRES)" /MACHINE:$(MAKEFW_CVTRES_MACHINE) /OUT:$@ $< 2>&1 | $(MAKEFW_POWERSHELL_COMMAND) -File "$(MSVC_OUTPUT_FILTER_SCRIPT)" -InputEncoding Ansi

endif # RES_OUTPUTS

endif # PLATFORM_WINDOWS
