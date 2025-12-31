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

ifneq ($(OS),Windows_NT)
    # Linux
    C_STDFLAG := $(call _c_std_gnu,$(C_STANDARD))
    ifeq ($(STRICT),ON)
        C_STDFLAG += -Wpedantic
    endif
else
    # Windows
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

ifneq ($(OS),Windows_NT)
    # Linux
    CXX_STDFLAG := $(call _cxx_std_gnu,$(CXX_STANDARD))
    ifeq ($(STRICT),ON)
        CXX_STDFLAG += -Wpedantic
    endif
else
    # Windows
    CXX_STDFLAG := $(call _cxx_std_msvc,$(CXX_STANDARD)) /Zc:__cplusplus
    ifeq ($(STRICT),ON)
        CXX_STDFLAG += /permissive-
    endif
endif

# 推奨の警告オプション
ifneq ($(OS),Windows_NT)
    # Linux
    CWARNS   ?= -Wall -Wextra
    CXXWARNS ?= -Wall -Wextra
else
    # Windows
    CWARNS   ?= /W4
    CXXWARNS ?= /W4
endif

# 上位の CFLAGS/CXXFLAGS に取り込み
CFLAGS   += $(C_STDFLAG) $(CWARNS)
CXXFLAGS += $(CXX_STDFLAG) $(CXXWARNS)

# 文字コード
ifeq ($(OS),Windows_NT)
    # Windows
    ifneq (,$(filter %.utf8 %.UTF-8 %.utf-8 %.UTF8,$(FILES_LANG)))
        # UTF-8
        CFLAGS   += /utf-8
        CXXFLAGS += /utf-8
    endif
endif

# nologo
ifeq ($(OS),Windows_NT)
    # Windows
    CFLAGS   += /nologo
    CXXFLAGS += /nologo
    # /SUBSYSTEM:CONSOLE は、main と wmain のどちらを採用するかにかかわる
    # 指定しないと、LINK : fatal error LNK1561: entry point must be defined となる場合がある
    LDFLAGS  += /NOLOGO /SUBSYSTEM:CONSOLE
endif

# runtime
ifneq ($(OS),Windows_NT)
    # Linux
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
else
    # Windows
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
ifneq ($(OS),Windows_NT)
    # Linux
    OBJDIR  := obj
else
    # Windows: ランタイムライブラリごとにサブディレクトリを分ける
    # Windows: Separate subdirectories for each runtime library to avoid mixing object files
    OBJDIR  := obj/$(MSVC_CRT_SUBDIR)
endif

# wrap-main
ifeq ($(USE_WRAP_MAIN),1)
    # リンクオプションの追加
    ifneq ($(OS),Windows_NT)
        # Linux
        # -Wl,--wrap=main により、エントリポイントを __wrap_main() に、元々のエントリポイントを __real_main() に変更
        LDFLAGS += -Wl,--wrap=main
    else
        # Windows
        # /Dmain=__real_main により、元々のエントリポイントを __real_main() に変更 (エントリポイントは main のまま)
        DEFINES += main=__real_main
        # wrapmain.lib により、main() から __wrap_main() をコール
        LIBS += wrapmain
    endif
endif

# 依存関係出力用フラグ
ifneq ($(OS),Windows_NT)
    # Linux
    DEPFLAGS = -MT $@ -MMD -MP -MF $(OBJDIR)/$*.d
else
    # Windows
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
