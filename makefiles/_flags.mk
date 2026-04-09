# _flags.mk 自身のディレクトリを include 時に確定（後から MAKEFILE_LIST が変化するため）
_MAKEFW_MAKEFILES_DIR := $(patsubst %/,%,$(dir $(lastword $(MAKEFILE_LIST))))

# ユーザー設定のデフォルト値
C_STANDARD        ?= 17             # 90, 99, 11, 17, 23
CXX_STANDARD      ?= 17             # 14, 17, 20, 23
C_EXTENSIONS      ?= OFF            # ON or OFF (GNU 拡張)
CXX_EXTENSIONS    ?= OFF            # ON or OFF (GNU 拡張)
STRICT            ?= ON             # 規格準拠を強める補助フラグ
CONFIG            ?= RelWithDebInfo # ビルド構成

# 標準フラグ生成 (C)
ifeq ($(C_EXTENSIONS),ON)
    GNU_C_PREFIX := gnu
else
    GNU_C_PREFIX := c
endif

# MSVC の C は c11/c17/clatest のみ想定。c90/c99 は警告扱い
define _c_std_msvc
$(if $(filter $(1),11 17),/std:c$(1),\
$(if $(filter $(1),23),/std:clatest,\
$(warning MSVC C$(1) は未サポートまたは非推奨。/std:clatest にフォールバックします) /std:clatest))
endef

# GCC の C は -std=cNN か -std=gnuNN
define _c_std_gnu
-std=$(GNU_C_PREFIX)$(1)
endef

ifdef PLATFORM_LINUX
    C_STDFLAG := $(call _c_std_gnu,$(C_STANDARD))
    ifeq ($(STRICT),ON)
        C_STDFLAG += -Wpedantic
    endif
else ifdef PLATFORM_WINDOWS
    C_STDFLAG := $(call _c_std_msvc,$(C_STANDARD)) /Zc:preprocessor
endif

# 標準フラグ生成 (C++)
ifeq ($(CXX_EXTENSIONS),ON)
    GNU_CXX_PREFIX := gnu++
else
    GNU_CXX_PREFIX := c++
endif

# MSVC の C++ は c++14/17/20/23/c++latest
define _cxx_std_msvc
$(if $(filter $(1),14 17 20 23),/std:c++$(1),/std:c++latest)
endef

# GCC の C++ は -std=c++NN か -std=gnu++NN
define _cxx_std_gnu
-std=$(GNU_CXX_PREFIX)$(1)
endef

ifdef PLATFORM_LINUX
    CXX_STDFLAG := $(call _cxx_std_gnu,$(CXX_STANDARD))
    ifeq ($(STRICT),ON)
        CXX_STDFLAG += -Wpedantic
    endif
else ifdef PLATFORM_WINDOWS
    CXX_STDFLAG := $(call _cxx_std_msvc,$(CXX_STANDARD)) /Zc:__cplusplus
    ifeq ($(STRICT),ON)
        CXX_STDFLAG += /permissive-
    endif
endif

# 推奨の警告オプション
ifdef PLATFORM_LINUX
    CWARNS   ?= -Wall -Wextra
    CXXWARNS ?= -Wall -Wextra
else ifdef PLATFORM_WINDOWS
    CWARNS   ?= /W4
    CXXWARNS ?= /W4
endif

# 上位の CFLAGS/CXXFLAGS に取り込み
CFLAGS   += $(C_STDFLAG) $(CWARNS)
CXXFLAGS += $(CXX_STDFLAG) $(CXXWARNS)

# 文字コード
ifdef PLATFORM_WINDOWS
    ifneq (,$(filter %.utf8 %.UTF-8 %.utf-8 %.UTF8,$(FILES_LANG)))
        # UTF-8
        CFLAGS   += /utf-8
        CXXFLAGS += /utf-8
    endif
endif

# nologo
ifdef PLATFORM_WINDOWS
    CFLAGS   += /nologo
    CXXFLAGS += /nologo
    LDFLAGS  += /NOLOGO
endif

# subsystem
ifdef PLATFORM_WINDOWS
    # /SUBSYSTEM:CONSOLE は、main と wmain のどちらを採用するかにかかわる
    # 指定しないと、LINK : fatal error LNK1561: entry point must be defined となる場合がある
    LDFLAGS  += /SUBSYSTEM:CONSOLE
endif

# WIN32_MANIFEST: マニフェスト埋め込み (Windows EXE のみ)
# 使い方: makepart.mk に WIN32_MANIFEST = utf8 (または任意の .manifest ファイルパス) を記述
# 効果: activeCodePage=UTF-8 により argv を含むプロセス全体を UTF-8 モードにする (Win10 1903+)
ifdef PLATFORM_WINDOWS
  ifdef WIN32_MANIFEST
    ifeq ($(WIN32_MANIFEST),utf8)
      _WIN32_MANIFEST_FILE := $(_MAKEFW_MAKEFILES_DIR)/utf8_manifest.manifest
    else
      _WIN32_MANIFEST_FILE := $(WIN32_MANIFEST)
    endif
    # link.exe には Windows パスが必要。MSYS 環境では cygpath -m で変換する
    # -w (バックスラッシュ形式) は sh 経由でコマンドを実行する際にエスケープされてパスが壊れるため
    # -m (フォワードスラッシュ形式: D:/a/...) を使用する
    _WIN32_MANIFEST_WIN := $(shell cygpath -m "$(abspath $(_WIN32_MANIFEST_FILE))" 2>/dev/null)
    ifeq ($(_WIN32_MANIFEST_WIN),)
      _WIN32_MANIFEST_WIN := $(abspath $(_WIN32_MANIFEST_FILE))
    endif
    LDFLAGS += /MANIFEST:EMBED /MANIFESTINPUT:$(_WIN32_MANIFEST_WIN)
  endif
endif

# runtime
ifdef PLATFORM_LINUX
    # 構成別フラグ
    ifeq ($(CONFIG),Debug)
      CPPFLAGS += -D_DEBUG
      CFLAGS   += -O0 -g
      CXXFLAGS += -O0 -g
    else ifeq ($(CONFIG),Release)
      CPPFLAGS += -DNDEBUG
      CFLAGS   += -O2 -g
      CXXFLAGS += -O2 -g
    else ifeq ($(CONFIG),RelWithDebInfo)
      CPPFLAGS += -DNDEBUG
      CFLAGS   += -O2 -g
      CXXFLAGS += -O2 -g
    else
      $(error CONFIG は Debug, Release, RelWithDebInfo のいずれか)
    endif
else ifdef PLATFORM_WINDOWS
    # 共通フラグ
    CFLAGS   += /EHsc /MP
    CXXFLAGS += /EHsc /MP

    # ランタイムライブラリフラグの設定
    # Set runtime library flags based on MSVC_CRT (defined in prepare.mk)
    ifeq ($(MSVC_CRT),shared)
        # Multi-threaded DLL (/MD, /MDd)
        RT_FLAG_DEBUG   := /MDd
        RT_FLAG_RELEASE := /MD
    else ifeq ($(MSVC_CRT),static)
        # Multi-threaded Static (/MT, /MTd)
        RT_FLAG_DEBUG   := /MTd
        RT_FLAG_RELEASE := /MT
    else
        $(error MSVC_CRT は shared または static のいずれか)
    endif

    # 構成別フラグ
    ifeq ($(CONFIG),Debug)
      CPPFLAGS += /D_DEBUG
      CFLAGS   += $(RT_FLAG_DEBUG) /Od /RTC1 /GS /Zi
      CXXFLAGS += $(RT_FLAG_DEBUG) /Od /RTC1 /GS /Zi
      LDFLAGS  += /DEBUG /INCREMENTAL
    else ifeq ($(CONFIG),Release)
      CPPFLAGS += /DNDEBUG
      CFLAGS   += $(RT_FLAG_RELEASE) /O2 /Ob2 /Oy /Zi
      CXXFLAGS += $(RT_FLAG_RELEASE) /O2 /Ob2 /Oy /Zi
      LDFLAGS  += /DEBUG /INCREMENTAL:NO
    else ifeq ($(CONFIG),RelWithDebInfo)
      CPPFLAGS += /DNDEBUG
      CFLAGS   += $(RT_FLAG_RELEASE) /O2 /Ob2 /Zi
      CXXFLAGS += $(RT_FLAG_RELEASE) /O2 /Ob2 /Zi
      # 速度重視なら /DEBUG:FASTLINK、サイズ重視なら /DEBUG
      LDFLAGS  += /DEBUG /INCREMENTAL:NO
    else
      $(error CONFIG は Debug, Release, RelWithDebInfo のいずれか)
    endif
endif

# CPPFLAGS を CFLAGS/CXXFLAGS に適用
CFLAGS   += $(CPPFLAGS)
CXXFLAGS += $(CPPFLAGS)

# ビルド設定は基本的に固定のため、OBJDIR も obj に固定する
#OBJDIR  := obj/$(CONFIG)
ifdef PLATFORM_LINUX
    OBJDIR  := obj
else ifdef PLATFORM_WINDOWS
    # ランタイムライブラリごとにサブディレクトリを分ける
    # Separate subdirectories for each runtime library to avoid mixing object files
    OBJDIR  := obj/$(MSVC_CRT_SUBDIR)
endif

# wrap-main
ifeq ($(USE_WRAP_MAIN),1)
    # リンクオプションの追加
    ifdef PLATFORM_LINUX
        # -Wl,--wrap=main により、エントリポイントを __wrap_main() に、元々のエントリポイントを __real_main() に変更
        LDFLAGS += -Wl,--wrap=main
    else ifdef PLATFORM_WINDOWS
        # /Dmain=__real_main により、元々のエントリポイントを __real_main() に変更 (エントリポイントは main のまま)
        DEFINES += main=__real_main
        # wrapmain.lib により、main() から __wrap_main() をコール
        LIBS += wrapmain
    endif
endif

# 依存関係出力用フラグ
ifdef PLATFORM_LINUX
    DEPFLAGS = -MT $@ -MMD -MP -MF $(OBJDIR)/$*.d
else ifdef PLATFORM_WINDOWS
    # MSVC では /showIncludes を使用して依存関係を生成
    # Use /showIncludes to generate dependencies with MSVC
    DEPFLAGS = /showIncludes
endif

# デバッグ出力
#$(info ----)
#$(info C_STANDARD: $(C_STANDARD), C_EXTENSIONS: $(C_EXTENSIONS))
#$(info CXX_STANDARD: $(CXX_STANDARD), CXX_EXTENSIONS: $(CXX_EXTENSIONS))
#$(info DEPFLAGS: $(DEPFLAGS))
#$(info CFLAGS: $(CFLAGS))
#$(info CXXFLAGS: $(CXXFLAGS))
#$(info LDFLAGS: $(LDFLAGS))
