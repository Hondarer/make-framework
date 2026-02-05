# サブディレクトリの検出 (GNUmakefile/makefile/Makefileを含むディレクトリのみ)
# Detect subdirectories containing GNUmakefile/makefile
SUBDIRS := $(sort $(dir $(wildcard */GNUmakefile */makefile */Makefile)))

# カレントディレクトリのパス判定による自動テンプレート選択
#
# ディレクトリパターン:
#   /libsrc/ を含む → ライブラリ用テンプレート (makelibsrc_*.mk)
#   /src/    を含む → 実行体用テンプレート (makesrc_*.mk)
#
# 言語判定:
#   .csproj が存在 → .NET 用テンプレート (*_dotnet.mk)
#   .csproj が無い → C/C++ 用テンプレート (*_c_cpp.mk)

# パスに /libsrc/ を含む場合はライブラリ用テンプレート
ifneq (,$(findstring /libsrc/,$(CURDIR)))
    # .csproj があれば .NET ライブラリ、なければ C/C++ ライブラリ
    ifneq ($(wildcard *.csproj),)
        include $(WORKSPACE_FOLDER)/makefw/makefiles/makelibsrc_dotnet.mk
    else
        include $(WORKSPACE_FOLDER)/makefw/makefiles/makelibsrc_c_cpp.mk
    endif
# パスに /src/ を含む場合は実行ファイル用テンプレート
else ifneq (,$(findstring /src/,$(CURDIR)))
    # .csproj があれば .NET 実行体、なければ C/C++ 実行体
    ifneq ($(wildcard *.csproj),)
        include $(WORKSPACE_FOLDER)/makefw/makefiles/makesrc_dotnet.mk
    else
        include $(WORKSPACE_FOLDER)/makefw/makefiles/makesrc_c_cpp.mk
    endif
else
    $(error Cannot auto-select makefile template. Current path must contain /libsrc/ or /src/: $(CURDIR))
endif

# サブディレクトリの再帰的make処理
# Recursive make for subdirectories
ifneq ($(SUBDIRS),)
    # サブディレクトリ自体をターゲット化し、指定されたターゲットを伝播
    # Make subdirectories as targets and propagate the specified goal
    .PHONY: $(SUBDIRS)
    $(SUBDIRS):
    #@echo "Making $(MAKECMDGOALS) in $@"
	@$(MAKE) -C $@ $(MAKECMDGOALS)

    # 主要なターゲットにサブディレクトリ依存を追加 (サブディレクトリを先に処理)
    # Add subdirectory dependencies to main targets (process subdirectories first)
    default build clean test run restore rebuild: $(SUBDIRS)
endif
