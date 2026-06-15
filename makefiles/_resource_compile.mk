# Windows リソース (.mc / .rc) のコンパイル
#
# ソース ディレクトリの *.mc / *.rc を自動収集し (_collect_srcs.mk)、
# $(OBJDIR)/<name>.res へコンパイルして LINK_INPUTS に追加する。
# LINK_INPUTS は EXE (makesrc) / DLL (makelibsrc) のリンクに直接渡され、
# 依存関係と再リンク判定にも乗る。
#
# Windows 専用 (mc.exe / rc.exe は Windows SDK のツール)。
# Linux では SRCS_MC / SRCS_RC が空のため何も行わない。
#
# 前提: _collect_srcs.mk (SRCS_MC / SRCS_RC) と _flags.mk (OBJDIR) の後に include する。

ifdef PLATFORM_WINDOWS

# メッセージ コンパイラ / リソース コンパイラのフラグ (上書き可)
# MCFLAGS の -U は Unicode メッセージ テーブルを生成する。
MCFLAGS ?= -U
RCFLAGS ?=

# 生成する .res の一覧 (cwd の *.mc / *.rc から導出)
RES_OUTPUTS := $(addprefix $(OBJDIR)/, $(SRCS_MC:.mc=.res) $(SRCS_RC:.rc=.res))

ifneq ($(strip $(RES_OUTPUTS)),)

# リンク入力に追加する (EXE: makesrc / DLL: makelibsrc が消費する)
LINK_INPUTS += $(RES_OUTPUTS)

# .mc -> (mc.exe) ヘッダー / .rc / MSG00001.bin -> (rc.exe) .res
# 生成物はすべて OBJDIR に置く。rc.exe は生成 .rc が参照する .bin を /i $(OBJDIR) で解決する。
$(OBJDIR)/%.res: %.mc | $(OBJDIR)
	@echo "mc.exe $(MCFLAGS) $<"
	@MSYS_NO_PATHCONV=1 mc.exe $(MCFLAGS) -h $(OBJDIR) -r $(OBJDIR) $<
	@echo "rc.exe $(OBJDIR)/$*.rc"
	@MSYS_NO_PATHCONV=1 rc.exe /nologo $(RCFLAGS) /i $(OBJDIR) /fo $@ $(OBJDIR)/$*.rc

# 単体 .rc -> (rc.exe) .res
# インクルード解決は OBJDIR, カレント ディレクトリ, INCDIR を探索する。
$(OBJDIR)/%.res: %.rc | $(OBJDIR)
	@echo "rc.exe $<"
	@MSYS_NO_PATHCONV=1 rc.exe /nologo $(RCFLAGS) /i $(OBJDIR) /i . $(addprefix /i ,$(INCDIR)) /fo $@ $<

# 同名 stem の .mc と .rc を同一ディレクトリに置かないこと (どちらも %.res を生成し衝突する)。

endif # RES_OUTPUTS

endif # PLATFORM_WINDOWS
