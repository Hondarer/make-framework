# サブディレクトリの検出 (GNUmakefile/makefile/Makefileを含むディレクトリのみ)
# Detect subdirectories containing GNUmakefile/makefile
SUBDIRS := $(sort $(dir $(wildcard */GNUmakefile */makefile */Makefile)))

# サブディレクトリの OS フィルタリング
# OS-based subdirectory filtering
#
# 最終ディレクトリ名 (大文字小文字無視) に基づくフィルタルール:
# Filter rules based on the last directory component (case-insensitive):
#   "linux"   → Linux の場合のみ有効 / active only on Linux
#   "windows" → Windows の場合のみ有効 / active only on Windows
#   "shared"  → Linux, Windows どちらでも有効 / active on both
#   その他    → Linux, Windows どちらでも有効 / active on both (default)

# 小文字変換関数 (pure Make, no shell calls)
# Lowercase conversion function
_lc = $(subst A,a,$(subst B,b,$(subst C,c,$(subst D,d,$(subst E,e,$(subst F,f,$(subst G,g,$(subst H,h,$(subst I,i,$(subst J,j,$(subst K,k,$(subst L,l,$(subst M,m,$(subst N,n,$(subst O,o,$(subst P,p,$(subst Q,q,$(subst R,r,$(subst S,s,$(subst T,t,$(subst U,u,$(subst V,v,$(subst W,w,$(subst X,x,$(subst Y,y,$(subst Z,z,$(1)))))))))))))))))))))))))))

# ディレクトリパスの最終コンポーネントを小文字で取得
# Get the last component of a directory path in lowercase
# e.g., "foo/Linux/" -> "linux", "Windows/" -> "windows"
_dir_lc_name = $(call _lc,$(notdir $(patsubst %/,%,$(1))))

# OS フィルタ: 現在の OS に適合するサブディレクトリのみ残す
# OS filter: keep only subdirectories matching the current OS
#   "linux"   dir on Windows -> excluded
#   "windows" dir on Linux   -> excluded
#   others (including "shared") -> always included
define _os_filter_subdir
$(strip \
    $(if $(filter linux,$(call _dir_lc_name,$(1))),\
        $(if $(filter Windows_NT,$(OS)),,$(1)),\
    $(if $(filter windows,$(call _dir_lc_name,$(1))),\
        $(if $(filter Windows_NT,$(OS)),$(1),),\
    $(1))))
endef

SUBDIRS := $(foreach d,$(SUBDIRS),$(call _os_filter_subdir,$(d)))

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
