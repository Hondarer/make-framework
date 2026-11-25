# 入力
# - TEST_SRCS
#   - テストの対象 (カバレッジ対象) のソース ファイル
# - ADD_SRCS
#   - フォルダー外にあるソース ファイル
# - INCDIR
#   - makepart.mk / makelocal.mk で定義した include

# 出力 (コンパイラ区分)
# - SRCS_C
#   - C のソース ファイル
# - SRCS_CPP
#   - C++ のソース ファイル

# 出力 (ソース ファイルの扱い)
# - DIRECT_SRCS
#   - カレント ディレクトリにあるソースを指す指定
#   - TEST_SRCS, ADD_SRCS に指定されていて、参照先がカレント ディレクトリにある
#   - 外部のソースと同名のローカル実体は含めない (EXTERNAL_SRCS)
# - EXTERNAL_SRCS
#   - 外部のソースと同名のローカル実体があり、DIRECT_SRCS から外したソース
#   - 以前の引き込み (コピー) が残したものとして扱い、LINK_SRCS (Windows では CP_SRCS) で引き込み直す
# - LINK_SRCS
#   - シンボリック リンクして引き込むソース ファイル
#   - Linux にて、inject ファイル および フィルター ファイルがない
# - CP_SRCS
#   - フォルダー外からコピーして引き込むソース ファイル
#   - inject ファイル または フィルター ファイルがある
#   - Windows では、inject ファイル および フィルター ファイルがない引き込みファイルも CP_SRCS として扱う
# - _MAKEFW_FORCED_COPY_TARGETS (Linux のみ)
#   - CP_SRCS のうち、カレント ディレクトリに以前の引き込み (リンク) が残っているファイル名
#   - 配置の規則 (コピー) を必ず実行させて、リンクをコピーへ置き換える
# - _MAKEFW_FORCED_LINK_TARGETS (Linux のみ)
#   - EXTERNAL_SRCS のうち LINK_SRCS に入ったソースのファイル名
#   - 配置の規則 (リンク) を必ず実行させて、以前の引き込み (コピー) をリンクへ置き換える

# 出力 (include)
# - INCDIR
#   - makepart.mk / makelocal.mk から得た include パスを正規化

# 出力 (カバレッジ観点)
# - GCOVR_SRCS
#   - カバレッジ収集対象のソース ファイル

# inject, filter 判定
# Determine inject and filter files
CP_SRCS := $(foreach src,$(TEST_SRCS) $(ADD_SRCS), \
	$(if $(or $(wildcard $(notdir $(basename $(src))).inject$(suffix $(src))), \
		$(wildcard $(notdir $(src)).filter.sh)), \
		$(src)))

# DIRECT_SRCS の判定
# Determine DIRECT_SRCS
# Step 1: $(wildcard) によるファイル存在チェック (Make インプロセス、全バージョン対応)
_DIRECT_CANDIDATES := $(filter-out $(CP_SRCS),$(TEST_SRCS) $(ADD_SRCS))
_DIRECT_EXISTS := $(foreach f,$(_DIRECT_CANDIDATES),$(if $(wildcard ./$(notdir $(f))),$(f)))
# Step 2: シンボリック リンクの除外
# 一覧をシェル コマンドへ展開せず、ディレクトリ内のリンク名を一度だけ収集する。
ifneq ($(_DIRECT_EXISTS),)
    _SOURCE_LINK_NAMES := $(call _makefw_source_link_names,$(_makefw_source_link_scan))
    _DIRECT_SYMLINKS := $(foreach f,$(_DIRECT_EXISTS),$(if $(filter ./$(notdir $(f)),$(_SOURCE_LINK_NAMES)),$(f)))
    DIRECT_SRCS := $(filter-out $(_DIRECT_SYMLINKS),$(_DIRECT_EXISTS))
else
    DIRECT_SRCS :=
endif

# Step 3: 外部のソースと同名のローカル実体を除外する
# 同名のローカル実体は、以前の引き込み (コピー) が残したものとして扱い、引き込み直す。
# Exclude local files that share a name with an external source.
# They are treated as leftovers of an earlier placement (copy) and are placed again.
_EXTERNAL_SOURCE_DIRS := $(call _makefw_source_dirs_of_kind,$(DIRECT_SRCS),external missing)
EXTERNAL_SRCS := $(call _makefw_sources_in_dirs,$(DIRECT_SRCS),$(_EXTERNAL_SOURCE_DIRS))
DIRECT_SRCS := $(filter-out $(EXTERNAL_SRCS),$(DIRECT_SRCS))

LINK_SRCS := $(filter-out $(CP_SRCS) $(DIRECT_SRCS),$(TEST_SRCS) $(ADD_SRCS))

# 次の処理は、ADD_SRCS に inject ファイルや filter ファイルを指定するための追加処理
# make 開始時点でファイルが配置されていない場合は、CP_SRCS に正しく移動しきれないファイルがあるため
# This additional process allows specifying inject/filter files under ADD_SRCS before make begins, in case files aren't placed initially

# LINK_SRCS の中から `*.inject.*` に対応する元ファイルを探して CP_SRCS に追加
# Add original files matching `*.inject.*` in LINK_SRCS to CP_SRCS
CP_SRCS += $(foreach f, $(LINK_SRCS), \
	$(if $(findstring .inject.,$(notdir $(f))), \
		$(foreach src, $(filter %$(subst .inject.,.,$(notdir $(f))), $(LINK_SRCS)), $(src))))

# LINK_SRCS の中から `*.filter.sh` に対応する元ファイルを探して CP_SRCS に追加
# Add original files matching `*.filter.sh` in LINK_SRCS to CP_SRCS
CP_SRCS += $(foreach f, $(LINK_SRCS), \
	$(if $(findstring .filter.sh,$(notdir $(f))), \
		$(foreach src, $(filter %$(subst .filter.sh,,$(notdir $(f))), $(LINK_SRCS)), $(src))))

# CP_SRCS の重複排除
# Remove duplicate entries from CP_SRCS
CP_SRCS := $(sort $(CP_SRCS))

# LINK_SRCS から CP_SRCS のファイルを削除
# Remove CP_SRCS files from LINK_SRCS
LINK_SRCS := $(filter-out $(CP_SRCS), $(LINK_SRCS))

# LINK_SRCS のリンク元存在チェック (Linux only, パース時)
# Verify LINK_SRCS source files exist at parse time (Linux only)
ifdef PLATFORM_LINUX
    _MISSING_LINK_SRCS := $(strip $(foreach f,$(LINK_SRCS),$(if $(wildcard $(f)),,$(f))))
    ifneq ($(_MISSING_LINK_SRCS),)
        $(error ERROR: Source files not found for LINK_SRCS: $(_MISSING_LINK_SRCS))
    endif
endif

# 以前の引き込みの残骸を、配置の規則で必ず置き換えさせる (Linux)
# 解析時はファイルを変更せず、置き換えはレシピの中だけで行う (make -n でファイルを変えない)。
# Make the placement rules replace leftovers of an earlier placement (Linux).
# Parsing never modifies files; replacement happens only in recipes (so make -n is side-effect free).
_MAKEFW_FORCED_COPY_TARGETS :=
_MAKEFW_FORCED_LINK_TARGETS :=
ifdef PLATFORM_LINUX
    ifneq ($(strip $(CP_SRCS)),)
        ifeq ($(origin _SOURCE_LINK_NAMES),undefined)
            _SOURCE_LINK_NAMES := $(call _makefw_source_link_names,$(_makefw_source_link_scan))
        endif
        _MAKEFW_FORCED_COPY_TARGETS := $(patsubst ./%,%,$(filter $(addprefix ./,$(notdir $(CP_SRCS))),$(_SOURCE_LINK_NAMES)))
    endif
    _MAKEFW_FORCED_LINK_TARGETS := $(notdir $(filter $(EXTERNAL_SRCS),$(LINK_SRCS)))
endif

# Windows ではシンボリック リンク機能に制限があるため、すべて CP_SRCS 扱いとする
ifdef PLATFORM_WINDOWS
    CP_SRCS += $(LINK_SRCS)
    LINK_SRCS :=
endif

# gcovr のフィルターを作成
# gcovr では、シンボリック リンクの場合は、実パスを与える必要がある
# Create filters for gcovr (symbolic links require real paths)
GCOVR_SRCS := $(foreach src,$(TEST_SRCS), \
	$(if $(filter $(src),$(LINK_SRCS)), \
		 $(src), \
		 $(notdir $(src))))

# コンパイル対象のソース ファイル (カレント ディレクトリから自動収集 + 指定ファイル)
# *.inject.* は対象ソースの末尾へ結合されるだけの断片であり、単独の翻訳単位としては成立しないため除外する
# Collect source files for compilation (auto-detect + specified files)
# *.inject.* files are only meant to be appended into their target source; they are not
# valid standalone translation units, so exclude them here
SRCS_C := $(sort $(filter-out %.inject.c,$(wildcard *.c)) $(notdir $(filter %.c,$(CP_SRCS) $(LINK_SRCS))))
SRCS_CPP := $(sort $(filter-out %.inject.cc %.inject.cpp,$(wildcard *.cc) $(wildcard *.cpp)) $(notdir $(filter %.cc,$(CP_SRCS) $(LINK_SRCS)) $(filter %.cpp,$(CP_SRCS) $(LINK_SRCS))))

# Windows リソース ソース (.mc メッセージ テーブル / .rc) の自動収集
# Auto-collect Windows resource sources (.mc message table / .rc)
# Windows 専用。コンパイルは _resource_compile.mk が担当する。
ifdef PLATFORM_WINDOWS
    SRCS_MC := $(sort $(wildcard *.mc))
    SRCS_RC := $(sort $(wildcard *.rc))
endif

# flex (.l) / bison (.y) ソースの自動収集
# Auto-collect flex (.l) / bison (.y) sources
# flex/bison はクロス プラットフォームな外部コマンドとして扱うため、
# .mc/.rc と異なり PLATFORM_* 分岐は行わない。コンパイルは _flex_bison_compile.mk が担当する。
SRCS_L := $(sort $(wildcard *.l))
SRCS_Y := $(sort $(wildcard *.y))

# INCDIR は prepare.mk で正規化済み (realpath -m + sort による重複除去)
# INCDIR is already normalized in prepare.mk (realpath -m + sort for dedup)

# デバッグ出力
#$(info ----)
#$(info TEST_SRCS: $(TEST_SRCS))
#$(info ADD_SRCS: $(ADD_SRCS))
#$(info ----)
#$(info DIRECT_SRCS: $(DIRECT_SRCS))
#$(info LINK_SRCS: $(LINK_SRCS))
#$(info CP_SRCS: $(CP_SRCS))
#$(info ----)
#$(info SRCS_C: $(SRCS_C))
#$(info SRCS_CPP: $(SRCS_CPP))
#$(info ----)
#$(info INCDIR: $(INCDIR))
#$(info ----)
#$(info GCOVR_SRCS: $(GCOVR_SRCS))
#$(info ----)
