# サブディレクトリの検出 (GNUmakefile/makefile/Makefile を含むディレクトリのみ)
# Detect subdirectories containing GNUmakefile/makefile
#
# SUBDIRS が makelocal.mk / makepart.mk で明示指定済みなら宣言順を尊重する
# (順序依存があるため、並列ビルド下でも宣言順に直列化する: 後段の連鎖を参照)。
# 未指定ならワイルドカードで自動検出する (兄弟は独立とみなし並列を許容)。
# SUBDIRS explicitly set by makelocal.mk/makepart.mk -> honor declared order.
# Otherwise auto-detect via wildcard (siblings assumed independent -> allow parallel).
ifeq ($(origin SUBDIRS),undefined)
    SUBDIRS := $(sort $(dir $(wildcard */GNUmakefile */makefile */Makefile)))
    _MAKEFW_SUBDIRS_ORDERED :=
else
    _MAKEFW_SUBDIRS_ORDERED := 1
endif

# サブディレクトリの OS フィルタリング
# OS-based subdirectory filtering
#
# 最終ディレクトリ名 (大文字小文字無視) に基づくフィルター ルール:
# Filter rules based on the last directory component (case-insensitive):
#   "linux"   → Linux の場合のみ有効 / active only on Linux
#   "windows" → Windows の場合のみ有効 / active only on Windows
#   "shared"  → Linux, Windows どちらでも有効 / active on both
#   その他    → Linux, Windows どちらでも有効 / active on both (default)

# 小文字変換関数 (pure Make, no shell calls)
# Lowercase conversion function
_lc = $(subst A,a,$(subst B,b,$(subst C,c,$(subst D,d,$(subst E,e,$(subst F,f,$(subst G,g,$(subst H,h,$(subst I,i,$(subst J,j,$(subst K,k,$(subst L,l,$(subst M,m,$(subst N,n,$(subst O,o,$(subst P,p,$(subst Q,q,$(subst R,r,$(subst S,s,$(subst T,t,$(subst U,u,$(subst V,v,$(subst W,w,$(subst X,x,$(subst Y,y,$(subst Z,z,$(1)))))))))))))))))))))))))))

# ディレクトリ パスの最終コンポーネントを小文字で取得
# Get the last component of a directory path in lowercase
# e.g., "foo/Linux/" -> "linux", "Windows/" -> "windows"
_dir_lc_name = $(call _lc,$(notdir $(patsubst %/,%,$(1))))

# OS フィルター: 現在の OS に適合するサブディレクトリのみ残す
# OS filter: keep only subdirectories matching the current OS
#   "linux"   dir on Windows -> excluded
#   "windows" dir on Linux   -> excluded
#   others (including "shared") -> always included
define _os_filter_subdir
$(strip \
    $(if $(filter linux,$(call _dir_lc_name,$(1))),\
        $(if $(PLATFORM_LINUX),$(1),),\
    $(if $(filter windows,$(call _dir_lc_name,$(1))),\
        $(if $(PLATFORM_WINDOWS),$(1),),\
    $(1))))
endef

SUBDIRS := $(foreach d,$(SUBDIRS),$(call _os_filter_subdir,$(d)))

# カレント ディレクトリのパス判定による自動テンプレート選択
# MAKEFW_BUILD が未設定の場合は、直下のビルド対象ソース有無で自動判定する
# (明示設定は自動判定より優先される)

# MAKEFW_BUILD 未設定時の自動判定
# Auto-detect MAKEFW_BUILD when not explicitly set.
# 直下にビルド対象ソース (*.c / *.cc / *.cpp / *.csproj) または TEST_SRCS / ADD_SRCS が
# 存在し、かつパスに /libsrc/ または /src/ を含む場合のみ 1 とする。
# サブフォルダーのみにソースを持つライブラリルートは 0 と誤判定されるため、
# その場合は makelocal.mk で MAKEFW_BUILD := 1 を明示する。
ifeq ($(MAKEFW_BUILD),)
    ifneq (,$(findstring /libsrc/,$(CURDIR))$(findstring /src/,$(CURDIR)))
        ifneq ($(strip $(wildcard *.c) $(wildcard *.cc) $(wildcard *.cpp) $(wildcard *.csproj) $(TEST_SRCS) $(ADD_SRCS)),)
            MAKEFW_BUILD := 1
        else
            MAKEFW_BUILD := 0
        endif
    else
        MAKEFW_BUILD := 0
    endif
endif

ifeq ($(MAKEFW_BUILD),1)

# パスに /libsrc/ を含む場合はライブラリ用テンプレート
ifneq (,$(findstring /libsrc/,$(CURDIR)))
    ifneq ($(wildcard *.csproj),)
        include $(MAKEFW_HOME)/makefiles/makelibsrc_dotnet.mk
    else
        include $(MAKEFW_HOME)/makefiles/makelibsrc_c_cpp.mk
    endif
# パスに /src/ を含む場合は実行ファイル用テンプレート
else ifneq (,$(findstring /src/,$(CURDIR)))
    ifneq ($(wildcard *.csproj),)
        include $(MAKEFW_HOME)/makefiles/makesrc_dotnet.mk
    else
        include $(MAKEFW_HOME)/makefiles/makesrc_c_cpp.mk
    endif
else
    $(error Cannot auto-select makefile template. MAKEFW_BUILD=1 requires /libsrc/ or /src/ in path: $(CURDIR))
endif

endif  # MAKEFW_BUILD

# サブディレクトリの再帰的 make 処理
# Recursive make for subdirectories
ifneq ($(SUBDIRS),)
    # 中間階層では引数なし `make` を default に向ける
    # Leaf build directories set their own default goal in make*_{c_cpp,dotnet}.mk
    ifneq ($(MAKEFW_BUILD),1)
        .DEFAULT_GOAL := default
    endif

    # サブディレクトリ自体をターゲット化し、指定されたターゲットを伝播
    # Make subdirectories as targets and propagate the specified goal
    .PHONY: $(SUBDIRS)
    $(SUBDIRS):
    #@echo "Making $(MAKECMDGOALS) in $@"
	@if [ ! -f "$@/makefile" ] && [ ! -f "$@/GNUmakefile" ] && [ ! -f "$@/Makefile" ]; then \
		echo "Skipping $@ (no makefile found)"; \
	else \
		$(call _MAKEFW_RESOLVE_PARALLEL_SHELL) \
		if [ -n "$(MAKECMDGOALS)" ]; then \
			$(MAKE) $$parallel_make_args -C $@ $(MAKECMDGOALS); \
		else \
			$(MAKE) $$parallel_make_args -C $@; \
		fi; \
	fi

    # 明示指定された SUBDIRS は宣言順を並列ビルド (-j) 下でも維持する。
    # 各サブディレクトリを直前のサブディレクトリへ order-only 依存させ、
    # makelocal.mk / makepart.mk が決めた順序を直列化する。
    # 各ターゲットは依然 $(MAKE) -C $@ を -j 付きで実行するため、
    # サブディレクトリ内部のコンパイル並列は保たれる。
    # Honor declared SUBDIRS order even under parallel make (-j): serialize
    # siblings via order-only prerequisites so a dependent dir builds after its
    # dependency. Auto-detected (independent) siblings stay parallel.
    ifneq ($(_MAKEFW_SUBDIRS_ORDERED),)
        _MAKEFW_PREV_SUBDIR :=
        $(foreach d,$(SUBDIRS),\
            $(if $(_MAKEFW_PREV_SUBDIR),$(eval $(d): | $(_MAKEFW_PREV_SUBDIR)))\
            $(eval _MAKEFW_PREV_SUBDIR := $(d)))
    endif

    # 主要なターゲットにサブディレクトリ依存を追加 (サブディレクトリを先に処理)
    # Add subdirectory dependencies to main targets (process subdirectories first)
    # test は 2 フェーズ エントリ (後述) が _test_build / _test_run を介して
    # 再帰するため、ここでは _test_build / _test_run を SUBDIRS へ伝播させる。
    # _test_build はビルド並列、_test_run は -j1 直列 (order-only で宣言順維持) で回る。
    # Add subdirectory dependencies to main targets (process subdirectories first).
    # 'test' itself is a 2-phase entry (below); the phase targets recurse instead.
    default build clean run restore rebuild _test_build _test_run: $(SUBDIRS)
endif

# test エントリ: 配下を 2 フェーズで巡回する。
#   Phase 1 (_test_build): テストバイナリのコンパイル/リンクのみ。ビルド並列。
#   Phase 2 (_test_run):   ビルド済みバイナリのテスト実行のみ。-j1 直列で出力順序維持。
# どの階層 (ルート / app モジュール / test 配下サブディレクトリ) で `make test` を
# 起動しても、その起動点がエントリとなり 2 フェーズが成立する。
# _test_build / _test_run 自体は単相で再帰するため、入れ子でも二重巡回は起きない。
#
# test entry: traverse the subtree in two phases (build in parallel, then run -j1).
# Any directory can be the entry point; the phase targets recurse single-phase.
.PHONY: test _test_build _test_run
test:
	@$(call _MAKEFW_RESOLVE_PARALLEL_SHELL) \
	echo "$(MAKE) $$parallel_make_args _test_build"; \
	$(MAKE) $$parallel_make_args _test_build
	@echo "$(MAKE) -j1 _test_run"
	@$(MAKE) -j1 _test_run

# 各フェーズの基底ターゲット。
# 中間集約ノードは上記の SUBDIRS 依存を、末端 (make*src*_*.mk) は実ビルド/実行を追加する。
# どちらも持たないディレクトリでも `make test` がエラーにならないよう空定義を置く。
# Phase base targets: intermediate nodes add SUBDIRS deps; leaf templates add the
# real build/run. Empty here so `make test` never errors in a bare directory.
_test_build:
_test_run:
