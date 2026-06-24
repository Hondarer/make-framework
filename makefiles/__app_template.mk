# app 直下 makefile テンプレート
# app/makefile で使用する標準テンプレート
# 本ファイルの直接編集は禁止する。
MAKEFW_HOME := $(strip $(MAKEFW_HOME))
ifeq ($(MAKEFW_HOME),)
    $(error MAKEFW_HOME is required. Export MAKEFW_HOME before running make)
endif

APP_ORDER_RESOLVER = $(MAKEFW_HOME)/bin/resolve_app_deps.sh
SUBDIRS := $(shell bash "$(APP_ORDER_RESOLVER)" --app-order)

TESTFW_BANNER = $(TESTFW_HOME)/bin/banner.sh
CPP_PROPERTIES_SYNC = $(MAKEFW_HOME)/bin/sync_c_cpp_properties.sh
DOXY_WARN_FILES = $(addsuffix /doxy.warn,$(SUBDIRS)) $(foreach d,$(SUBDIRS),$(wildcard $(d)/doxy_*.warn))
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
default : submodule $(SUBDIRS)
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
clean : submodule $(SUBDIRS)
	-find . -name "coverage.xml" -delete
	rm -f c_cpp_properties.warn
	rm -rf idir

.PHONY: test
test : submodule
    # テスト実行 (各 app の test ターゲットが内部で prod 最新化を担保する)
	@for dir in $(SUBDIRS); do \
		if [ -d $$dir ] && [ -f $$dir/makefile ]; then \
			echo $(MAKE) -C $$dir test; \
			$(MAKE) -C $$dir test || exit 1; \
		fi; \
	done
    # このフォルダー以下の coverage.xml をマージする
	-python "$(TESTFW_HOME)/bin/cobertura_merge.py" . > /dev/null

.PHONY: doxy
doxy : submodule
	@for warn_file in $(DOXY_WARN_FILES); do \
		rm -f "$$warn_file"; \
	done
	@doxy_status=0; \
	for dir in $(SUBDIRS); do \
		if [ -d $$dir ] && [ -f $$dir/makefile ]; then \
			echo $(MAKE) -C $$dir doxy; \
			SUPPRESS_DOXY_WARN_PRINT=1 $(MAKE) -C $$dir doxy || { doxy_status=$$?; break; }; \
		fi; \
	done; \
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

# app 間の依存順 (--app-order) を並列ビルド (-j) 下でも維持する。
# 各 app を直前の app へ order-only 依存させ、default/clean の並列プリレキジット
# でも依存元 app が先行ビルドされるようにする (test/doxy/with-cov は直列 for ループ)。
# Keep the resolved app-order under parallel make (-j): chain each app after the
# previous via order-only prerequisites.
_MAKEFW_PREV_APP :=
$(foreach d,$(SUBDIRS),\
	$(if $(_MAKEFW_PREV_APP),$(eval $(d): | $(_MAKEFW_PREV_APP)))\
	$(eval _MAKEFW_PREV_APP := $(d)))
