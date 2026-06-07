# _ident.mk: IDENT ソース トレーサビリティ ルール
# IDENT source traceability rules
#
# makelibsrc_c_cpp.mk / makesrc_c_cpp.mk の末尾から include される。
# IDENT_ENABLED=1 の場合のみ include すること。
# Included at the end of makelibsrc_c_cpp.mk / makesrc_c_cpp.mk.
# Only include when IDENT_ENABLED=1.

# ローカル ソースに対応する .ident ファイルのリスト
# DEPS は SUBDIR_OBJS 追加前に計算済みのためローカル ソースのみ
# List of .ident files corresponding to local sources only
# (DEPS is computed before SUBDIR_OBJS is added)
_IDENT_LOCAL_IDENT_FILES := $(patsubst %.d,%.ident,$(DEPS))

# per-source .ident 生成ルール
# Per-source .ident generation rules
ifdef PLATFORM_LINUX

$(OBJDIR)/%.ident: $(OBJDIR)/%.o | $(OBJDIR)
	@python3 "$(MAKEFW_HOME)/bin/gen_ident_manifest.py" \
		--mode source-info \
		--dep-file "$(OBJDIR)/$*.d" \
		--src-dir "$(CURDIR)" \
		--workspace "$(WORKSPACE_DIR)" \
		--out "$@"

else ifdef PLATFORM_WINDOWS

ifeq ($(GROUP_COMPILE),1)
# GROUP_COMPILE=1: _group_compile が .d を生成するため、その完了後に .ident を生成
# GROUP_COMPILE=1: _group_compile generates .d files; build .ident after it completes
$(_IDENT_LOCAL_IDENT_FILES): _group_compile

$(OBJDIR)/%.ident: $(OBJDIR)/%.d | $(OBJDIR)
	@python3 "$(MAKEFW_HOME)/bin/gen_ident_manifest.py" \
		--mode source-info \
		--dep-file "$(OBJDIR)/$*.d" \
		--src-dir "$(CURDIR)" \
		--workspace "$(WORKSPACE_DIR)" \
		--out "$@"

else
# GROUP_COMPILE=0: .obj のコンパイル完了後に .ident を生成
# GROUP_COMPILE=0: generate .ident after .obj compilation completes
$(OBJDIR)/%.ident: $(OBJDIR)/%.obj | $(OBJDIR)
	@python3 "$(MAKEFW_HOME)/bin/gen_ident_manifest.py" \
		--mode source-info \
		--dep-file "$(OBJDIR)/$*.d" \
		--src-dir "$(CURDIR)" \
		--workspace "$(WORKSPACE_DIR)" \
		--out "$@"

endif

endif # PLATFORM

# NO_LINK=1: アーカイブを生成しないコンパイル専用サブディレクトリ (LIB_TYPE を問わず優先)
# .ident を _build_main に依存させてコンパイル時に生成する。親が CURDIR を走査して収集する。
# NO_LINK=1: compile-only subdirectory regardless of LIB_TYPE — takes priority.
# Attach .ident files to _build_main so they are generated during compilation.
# The parent directory walks CURDIR to collect them.
ifdef NO_LINK

_build_main: $(_IDENT_LOCAL_IDENT_FILES)

else

# LIB_TYPE=static/both: downstream に ident_dir を伝える .ident_srcs を生成
# LIB_TYPE=static/both: generate .ident_srcs to pass ident_dir to downstream consumers
ifneq (,$(filter static both,$(LIB_TYPE)))

ifdef PLATFORM_LINUX
  ifeq ($(LIB_TYPE),both)
    _IDENT_SRCS_TARGET := $(TARGET_STATIC)
  else
    _IDENT_SRCS_TARGET := $(TARGET)
  endif
_IDENT_SRCS_FILE := $(OUTPUT_DIR)/$(patsubst lib%.a,%.ident_srcs,$(_IDENT_SRCS_TARGET))
else ifdef PLATFORM_WINDOWS
  ifeq ($(LIB_TYPE),both)
    _IDENT_SRCS_TARGET := $(TARGET_STATIC)
  else
    _IDENT_SRCS_TARGET := $(TARGET)
  endif
_IDENT_SRCS_FILE := $(OUTPUT_DIR)/$(patsubst lib%.lib,%.ident_srcs,$(_IDENT_SRCS_TARGET))
endif

# アーカイブ完成後に .ident_srcs を生成 (order-only でアーカイブの再ビルドを防ぐ)
# Generate .ident_srcs after archive is ready (order-only to avoid triggering archive rebuild)
$(OUTPUT_DIR)/$(_IDENT_SRCS_TARGET): | $(_IDENT_SRCS_FILE)

$(_IDENT_SRCS_FILE): $(_IDENT_LOCAL_IDENT_FILES) $(MAKEFILE_LIST) | $(OUTPUT_DIR)
	@printf '[ident_dir]\n%s\n' '$(CURDIR)' > "$@.tmp" && mv "$@.tmp" "$@"

.PHONY: _ident_srcs_main
_ident_srcs_main: $(_IDENT_SRCS_FILE)

_build_main: _ident_srcs_main

CLEAN_COMMON += $(call _relpath,$(_IDENT_SRCS_FILE))

endif

ifneq ($(LIB_TYPE),static)

# shared / both / exe: _ident_manifest.c を生成してリンクに混入
# shared / both / exe: generate _ident_manifest.c and include it in the link step

# STATIC_LIBS (makelibsrc shared/both) または LIBSFILES の .a/.lib から .ident_srcs を逆算
# Derive .ident_srcs paths from STATIC_LIBS (makelibsrc shared/both) or LIBSFILES (.a/.lib only)
ifdef PLATFORM_LINUX
  ifdef STATIC_LIBS
    _IDENT_LINK_STATIC_LIBS := $(STATIC_LIBS)
  else ifdef LIBSFILES
    _IDENT_LINK_STATIC_LIBS := $(filter %.a,$(LIBSFILES))
  else
    _IDENT_LINK_STATIC_LIBS :=
  endif
  _IDENT_STATIC_SRCS := $(foreach lib,$(_IDENT_LINK_STATIC_LIBS),\
      $(if $(filter lib%.a,$(notdir $(lib))),\
          $(dir $(lib))$(patsubst lib%.a,%.ident_srcs,$(notdir $(lib)))))
else ifdef PLATFORM_WINDOWS
  ifdef STATIC_LIBS
    _IDENT_LINK_STATIC_LIBS := $(STATIC_LIBS)
  else ifdef LIBSFILES
    _IDENT_LINK_STATIC_LIBS := $(filter %.lib,$(LIBSFILES))
  else
    _IDENT_LINK_STATIC_LIBS :=
  endif
  _IDENT_STATIC_SRCS := $(foreach lib,$(_IDENT_LINK_STATIC_LIBS),\
      $(if $(filter lib%.lib,$(notdir $(lib))),\
          $(dir $(lib))$(patsubst lib%.lib,%.ident_srcs,$(notdir $(lib)))))
endif

# git short hash スタンプ
# Git short hash stamp
_IDENT_GIT_HEAD := $(wildcard $(WORKSPACE_DIR)/.git/HEAD)
_IDENT_REV_FILE := $(OBJDIR)/.ident_rev

$(_IDENT_REV_FILE): $(_IDENT_GIT_HEAD) | $(OBJDIR)
	@git -C "$(WORKSPACE_DIR)" rev-parse --short HEAD > "$@.tmp" 2>/dev/null \
		&& mv "$@.tmp" "$@" \
		|| { printf 'unknown' > "$@"; rm -f "$@.tmp"; }

# manifest C ソースと object
# Manifest C source and object
_IDENT_MANIFEST_C   := $(OBJDIR)/_ident_manifest.c
ifdef PLATFORM_LINUX
_IDENT_MANIFEST_OBJ := $(OBJDIR)/_ident_manifest.o
else ifdef PLATFORM_WINDOWS
_IDENT_MANIFEST_OBJ := $(OBJDIR)/_ident_manifest.obj
endif

# サブディレクトリに NO_LINK サブディレクトリがある場合、その .ident も依存に加える
# (make 評価時点で存在するものを列挙; 存在しない場合は第一ビルド時に _ident_manifest.c が
#  存在しないため recipe は必ず走る)
# If there are NO_LINK subdirectories, include their .ident files as dependencies too.
# Files are enumerated at make parse time (existing files only); on first build
# _ident_manifest.c does not yet exist so the recipe always runs regardless.
_IDENT_SUBDIR_IDENT_FILES := $(shell find "$(CURDIR)" -name "*.ident" -type f 2>/dev/null)

# ローカル .ident + サブディレクトリ .ident + 静的ライブラリ変更 (.a/.lib) + .ident_srcs が揃ったら manifest を生成
# Generate manifest when local, subdirectory .ident, static lib archives, and .ident_srcs are ready
$(_IDENT_MANIFEST_C): $(_IDENT_LOCAL_IDENT_FILES) $(_IDENT_SUBDIR_IDENT_FILES) $(wildcard $(_IDENT_STATIC_SRCS)) $(_IDENT_LINK_STATIC_LIBS) $(_IDENT_REV_FILE) $(MAKEFILE_LIST) | $(OBJDIR)
	@python3 "$(MAKEFW_HOME)/bin/gen_ident_manifest.py" \
		--mode combine \
		--ident-dirs "$(CURDIR)" \
		$(if $(strip $(_IDENT_STATIC_SRCS)),--ident-srcs-files $(_IDENT_STATIC_SRCS),) \
		--target "$(TARGET)" \
		--target-arch "$(TARGET_ARCH)" \
		--rev-file "$(_IDENT_REV_FILE)" \
		--workspace "$(WORKSPACE_DIR)" \
		--out "$@"

# manifest のコンパイル
# Compile the manifest
ifdef PLATFORM_LINUX
$(_IDENT_MANIFEST_OBJ): $(_IDENT_MANIFEST_C) | $(OBJDIR)
	@$(CC) $(CFLAGS) -c -o "$@" "$<"

else ifdef PLATFORM_WINDOWS
$(_IDENT_MANIFEST_OBJ): $(_IDENT_MANIFEST_C) | $(OBJDIR)
	@MSYS_NO_PATHCONV=1 $(CC) $(CFLAGS) /Fd:"$(OBJDIR)/_ident_manifest.pdb" /c /Fo"$@" "$<"

endif

# 既存リンク ターゲットに manifest obj を依存として追加 (recipe は既存のものを維持)
# Add manifest obj as a dependency to the existing link target (existing recipe is preserved)
$(OUTPUT_DIR)/$(TARGET): $(_IDENT_MANIFEST_OBJ)

endif # LIB_TYPE != static

endif # NO_LINK
