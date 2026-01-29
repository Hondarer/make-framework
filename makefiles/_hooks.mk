# フック機能の共通処理
# Common hook processing
#
# このファイルは各テンプレートファイルからインクルードされ、
# makelocal.mk で定義されたフックターゲットを検出し、
# 適切なタイミングで呼び出すための内部ターゲットを定義します。
#
# This file is included from each template file to detect hook targets
# defined in makelocal.mk and define internal targets to call them
# at the appropriate time.

# makelocal.mk のパス (自ディレクトリのみ)
# Path to makelocal.mk (current directory only)
# Note: makelocal.mk のインクルードは prepare.mk で行われる
# Note: makelocal.mk is included in prepare.mk
MAKELOCAL_MK := $(wildcard $(CURDIR)/makelocal.mk)

# makelocal.mk 内のフックターゲット検出
# Detect hook targets in makelocal.mk
ifneq ($(MAKELOCAL_MK),)
    HAS_PRE_BUILD := $(shell grep -qE '^pre-build[[:space:]]*:' $(MAKELOCAL_MK) 2>/dev/null && echo 1)
    HAS_POST_BUILD := $(shell grep -qE '^post-build[[:space:]]*:' $(MAKELOCAL_MK) 2>/dev/null && echo 1)
    HAS_PRE_CLEAN := $(shell grep -qE '^pre-clean[[:space:]]*:' $(MAKELOCAL_MK) 2>/dev/null && echo 1)
    HAS_POST_CLEAN := $(shell grep -qE '^post-clean[[:space:]]*:' $(MAKELOCAL_MK) 2>/dev/null && echo 1)
    HAS_PRE_TEST := $(shell grep -qE '^pre-test[[:space:]]*:' $(MAKELOCAL_MK) 2>/dev/null && echo 1)
    HAS_POST_TEST := $(shell grep -qE '^post-test[[:space:]]*:' $(MAKELOCAL_MK) 2>/dev/null && echo 1)
    HAS_INSTALL := $(shell grep -qE '^install[[:space:]]*:' $(MAKELOCAL_MK) 2>/dev/null && echo 1)
endif

#$(info HAS_PRE_BUILD: $(HAS_PRE_BUILD))
#$(info HAS_POST_BUILD: $(HAS_POST_BUILD))
#$(info HAS_PRE_CLEAN: $(HAS_PRE_CLEAN))
#$(info HAS_POST_CLEAN: $(HAS_POST_CLEAN))
#$(info HAS_PRE_TEST: $(HAS_PRE_TEST))
#$(info HAS_POST_TEST: $(HAS_POST_TEST))
#$(info HAS_INSTALL: $(HAS_INSTALL))

# ============================================================================
# build フック
# Build hooks
# ============================================================================

.PHONY: _pre_build_hook _post_build_hook

# pre-build フック
# pre-build hook
ifdef HAS_PRE_BUILD
_pre_build_hook: pre-build
else
_pre_build_hook:
	@:
endif

# post-build フック
# post-build hook
ifdef HAS_POST_BUILD
_post_build_hook: _build_main post-build
else
_post_build_hook: _build_main
	@:
endif

# ============================================================================
# clean フック
# Clean hooks
# ============================================================================

.PHONY: _pre_clean_hook _post_clean_hook

# pre-clean フック
# pre-clean hook
ifdef HAS_PRE_CLEAN
_pre_clean_hook: pre-clean
else
_pre_clean_hook:
	@:
endif

# post-clean フック
# post-clean hook
ifdef HAS_POST_CLEAN
_post_clean_hook: _clean_main post-clean
else
_post_clean_hook: _clean_main
	@:
endif

# ============================================================================
# test フック
# Test hooks
# ============================================================================

.PHONY: _pre_test_hook _post_test_hook

# pre-test フック
# pre-test hook
ifdef HAS_PRE_TEST
_pre_test_hook: pre-test
else
_pre_test_hook:
	@:
endif

# post-test フック
# post-test hook
ifdef HAS_POST_TEST
_post_test_hook: _test_main post-test
else
_post_test_hook: _test_main
	@:
endif

# ============================================================================
# install ターゲット
# Install target
# ============================================================================

# install ターゲットが makelocal.mk で定義されていない場合のデフォルト
# Default install target if not defined in makelocal.mk
ifndef HAS_INSTALL
.PHONY: install
install:
	@echo "No install target defined. Define install target in makelocal.mk."
endif
