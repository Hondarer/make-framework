# app 直下 makefile テンプレート
# app/makefile で使用する標準テンプレート
# 本ファイルの直接編集は禁止する。
MAKEFW_HOME := $(strip $(MAKEFW_HOME))
ifeq ($(MAKEFW_HOME),)
    $(error MAKEFW_HOME is required. Export MAKEFW_HOME before running make)
endif
include $(MAKEFW_HOME)/makefiles/_parallel.mk

APP_ORDER_RESOLVER = $(MAKEFW_HOME)/bin/resolve_app_deps.sh
SUBDIRS := $(shell bash "$(APP_ORDER_RESOLVER)" --app-order)

# 並列実行 (-j) 時に複数 app の出力が交錯しないよう、通常はターゲット単位で出力同期する。
# ただし既定ビルドは run_ordered_subdir_target.sh が app ごとの出力を制御し、
# 進捗行を即時表示したいため、親 make では出力同期を付与しない。
# doxy は長時間処理の進行を見えるようにするため、出力同期を付与しない。
# 呼び出し側が --output-sync を明示している場合はそれを尊重する。
# GNU Make 4.0+ が前提 (本リポジトリの最低要件と一致)。
ifeq ($(strip $(MAKECMDGOALS)),)
    _MAKEFW_APP_NEEDS_OUTPUT_SYNC :=
else ifneq ($(filter default,$(MAKECMDGOALS)),)
    _MAKEFW_APP_NEEDS_OUTPUT_SYNC :=
else ifneq ($(filter doxy clean,$(MAKECMDGOALS)),)
    _MAKEFW_APP_NEEDS_OUTPUT_SYNC :=
else
    _MAKEFW_APP_NEEDS_OUTPUT_SYNC := 1
endif
ifeq ($(_MAKEFW_APP_NEEDS_OUTPUT_SYNC),1)
ifeq ($(filter --output-sync%,$(MAKEFLAGS)),)
    MAKEFLAGS += --output-sync=recurse
endif
endif

TESTFW_BANNER = $(TESTFW_HOME)/bin/banner.sh
CPP_PROPERTIES_SYNC = $(MAKEFW_HOME)/bin/sync_c_cpp_properties.sh
DOXY_WARN_FILES = $(addsuffix /doxy.warn,$(SUBDIRS)) $(foreach d,$(SUBDIRS),$(wildcard $(d)/doxy_*.warn))
MAKEFW_SUBDIR_MAKE_CMD := $(MAKE)
export MAKEFW_HOME

define APP_POST_BUILD_CHECKS
	cpp_sync_status=0; \
	printf 'INFO: Checking c_cpp_properties.json sync...\n'; \
	bash "$(CPP_PROPERTIES_SYNC)" --check || cpp_sync_status=$$?; \
	if [ $$cpp_sync_status -ne 0 ] && [ $$cpp_sync_status -ne 3 ]; then \
		exit $$cpp_sync_status; \
	fi; \
	printf 'INFO: c_cpp_properties.json sync check completed.\n'; \
	warn_files=$$(find . -type f -name '*.warn' ! -name 'doxy.warn' ! -name 'doxy_*.warn' -size +0 | sort); \
	if [ -n "$$warn_files" ]; then \
		printf '\n'; \
		bash "$(TESTFW_BANNER)" WARNING "\e[33m"; \
		printf '\n'; \
		first_warn=1; \
		for warn_file in $$warn_files; do \
			if [ $$first_warn -eq 0 ]; then \
				printf '\n'; \
			fi; \
			first_warn=0; \
			printf '\033[33m===== %s =====\033[0m\n' "$$warn_file"; \
			while IFS= read -r line || [ -n "$$line" ]; do \
				printf '\033[33m%s\033[0m\n' "$$line"; \
			done < "$$warn_file"; \
		done; \
	fi
endef

.DEFAULT_GOAL := default

.PHONY: submodule
submodule :
	@if [ ! -d "$(MAKEFW_HOME)" ] || [ ! -f "$(MAKEFW_HOME)/.git" ]; then \
		echo "ERROR: makefw submodule is not initialized."; \
		echo "Please run the following command to initialize submodules:"; \
		echo "  git submodule update --init --recursive"; \
		exit 1; \
	fi

.PHONY: default
default : submodule
	@$(call _MAKEFW_RESOLVE_PARALLEL_SHELL) \
	app_build_jobs="$$jobs"; \
	if [ -z "$$app_build_jobs" ]; then app_build_jobs=1; fi; \
	MAKEFW_SUBDIR_MAKE="$(MAKEFW_SUBDIR_MAKE_CMD)" "$(SHELL)" \
		"$(MAKEFW_HOME)/bin/run_ordered_subdir_target.sh" \
		--app-deps --silent-missing --echo-command --progress \
		"$$app_build_jobs" default $(SUBDIRS)
	@$(APP_POST_BUILD_CHECKS)

.PHONY: with-cov
with-cov : submodule
	@for dir in $(SUBDIRS); do \
		if [ -d $$dir ] && [ -f $$dir/makefile ]; then \
			if [ -f "$$dir/prod/coverity.mk" ]; then \
				echo $(MAKE) -C $$dir with-cov; \
				$(MAKE) -C $$dir with-cov || exit 1; \
			else \
				echo $(MAKE) -C $$dir; \
				$(MAKE) -C $$dir || exit 1; \
			fi; \
		fi; \
	done
	@$(APP_POST_BUILD_CHECKS)

.PHONY: clean
clean : submodule
	@$(call _MAKEFW_RESOLVE_PARALLEL_SHELL) \
	app_clean_jobs="$$jobs"; \
	if [ -z "$$app_clean_jobs" ]; then app_clean_jobs=1; fi; \
	MAKEFW_SUBDIR_MAKE="$(MAKEFW_SUBDIR_MAKE_CMD)" "$(SHELL)" \
		"$(MAKEFW_HOME)/bin/run_ordered_subdir_target.sh" \
		--app-deps --silent-missing --echo-command --progress \
		"$$app_clean_jobs" clean $(SUBDIRS)
	-find . -name "coverage.xml" -delete
	rm -f c_cpp_properties.warn
	rm -rf idir

.PHONY: test
test : submodule
    # 各 app の test を依存関係に従って並列ディスパッチしつつ、コンソール出力は
    # SUBDIRS の宣言順に揃える。leaf テスト実行は共有スロットで全体上限を守る。
	@$(call _MAKEFW_RESOLVE_PARALLEL_SHELL) \
	app_test_jobs=$${MAKEFW_APP_TEST_JOBS:-$$jobs}; \
	test_run_jobs=$${MAKEFW_TEST_RUN_JOBS:-$$jobs}; \
	MAKEFW_SUBDIR_MAKE="$(MAKE)" MAKEFW_TEST_RUN_JOBS="$$test_run_jobs" "$(SHELL)" \
		"$(MAKEFW_HOME)/bin/run_ordered_subdir_target.sh" \
		--app-deps --silent-missing --echo-command --progress \
		"$$app_test_jobs" test $(SUBDIRS)
    # このフォルダー以下の coverage.xml をマージする
	-python "$(TESTFW_HOME)/bin/cobertura_merge.py" . > /dev/null

.PHONY: doxy
doxy : submodule
	@for warn_file in $(DOXY_WARN_FILES); do \
		rm -f "$$warn_file"; \
	done
	@$(call _MAKEFW_RESOLVE_PARALLEL_SHELL) \
	app_doxy_jobs=$${MAKEFW_APP_DOXY_JOBS:-$$jobs}; \
	if [ -z "$$app_doxy_jobs" ]; then app_doxy_jobs=1; fi; \
	MAKEFW_SUBDIR_MAKE="$(MAKEFW_SUBDIR_MAKE_CMD)" "$(SHELL)" \
		"$(MAKEFW_HOME)/bin/run_ordered_subdir_target.sh" \
		--app-deps --silent-missing --echo-command --progress \
		"$$app_doxy_jobs" doxy $(SUBDIRS); \
	doxy_status=$$?; \
	warn_files=$$(find . -mindepth 2 -maxdepth 2 -type f \( -name 'doxy.warn' -o -name 'doxy_*.warn' \) -size +0 | sort); \
	if [ -n "$$warn_files" ]; then \
		printf '\n'; \
		bash "$(TESTFW_BANNER)" WARNING "\e[33m"; \
		printf '\n'; \
		first_warn=1; \
		for warn_file in $$warn_files; do \
			if [ $$first_warn -eq 0 ]; then \
				printf '\n'; \
			fi; \
			first_warn=0; \
			printf '\033[33m===== %s =====\033[0m\n' "$$warn_file"; \
			while IFS= read -r line || [ -n "$$line" ]; do \
				printf '\033[33m%s\033[0m\n' "$$line"; \
			done < "$$warn_file"; \
		done; \
	fi; \
	exit $$doxy_status

.PHONY: $(SUBDIRS)
$(SUBDIRS) :
	@if [ -f $@/makefile ]; then \
		if [ -n "$(filter-out $(SUBDIRS),$(MAKECMDGOALS))" ]; then \
			echo $(MAKE) -C $@ $(filter-out $(SUBDIRS),$(MAKECMDGOALS)); \
			$(MAKE) -C $@ $(filter-out $(SUBDIRS),$(MAKECMDGOALS)) || exit 1; \
		else \
			echo $(MAKE) -C $@; \
			$(MAKE) -C $@ || exit 1; \
		fi; \
	else \
		:; # echo "Skipping directory '$@' (no makefile)"; \
	fi

# app 間の依存関係 (appdeps.mk の APP_DEPS) に基づき、並列ビルド (-j) 下でも
# 依存先 app の先行完了を保証する。1 段鎖ではなく実際の依存グラフを使うため、
# 依存関係のない app 同士は並列に実行できる (com_util を経由した複数 app の同時実行など)。
# Honor per-app dependencies (appdeps.mk APP_DEPS) under parallel make (-j):
# add order-only prerequisites along the actual dep graph so independent apps
# build/test in parallel.
define _MAKEFW_LOAD_APP_DEPS
APP_DEPS :=
-include $(1)/appdeps.mk
_MAKEFW_APP_DEPS_$(1) := $$(APP_DEPS)
endef
$(foreach d,$(SUBDIRS),$(eval $(call _MAKEFW_LOAD_APP_DEPS,$(d))))
APP_DEPS :=

$(foreach d,$(SUBDIRS),\
	$(foreach dep,$(_MAKEFW_APP_DEPS_$(d)),\
		$(if $(filter $(dep),$(SUBDIRS)),$(eval $(d): | $(dep)))))
