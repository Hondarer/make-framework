# リンク成功時の入力一覧を保存し、ソース削除による入力の減少も検出する。
# Make 4.0 でも外部プロセスなしで読めるよう、保存形式は変数定義とする。
# サブディレクトリのコンパイル後にも、既存のリンク レシピ内で一覧を確認する。

ifndef NO_LINK

# 失敗したリンクが成果物を途中まで更新しても、次回は必ず作り直す。
.DELETE_ON_ERROR:

MAKEFW_LINK_TARGETS := $(OUTPUT_DIR)/$(TARGET) $(if $(filter both,$(LIB_TYPE)),$(OUTPUT_DIR)/$(TARGET_STATIC))
MAKEFW_STATIC_TARGETS := $(if $(filter static,$(LIB_TYPE)),$(TARGET),$(if $(filter both,$(LIB_TYPE)),$(TARGET_STATIC)))
_makefw_link_state = $(OBJDIR)/$(notdir $(1)).link.mk
_makefw_link_extra_inputs = $(strip $(MAKEFW_EXTRA_OBJS) $(if $(filter $(notdir $(1)),$(MAKEFW_STATIC_TARGETS)),$(RESOURCE_OBJS),$(LINK_INPUTS)))
_makefw_link_expected = $(sort $(patsubst ./%,%,$(OBJS) $(call _makefw_link_extra_inputs,$(1))))

# 保存一覧はビルド入力ではないため、MAKEFILE_LIST には残さない。
# .gitignore_stamp や IDENT が保存一覧の更新で再生成されることを防ぐ。
_MAKEFW_LINK_MAKEFILE_LIST := $(MAKEFILE_LIST)
include $(wildcard $(foreach target,$(MAKEFW_LINK_TARGETS),$(call _makefw_link_state,$(target))))
MAKEFILE_LIST := $(_MAKEFW_LINK_MAKEFILE_LIST)

.PHONY: _makefw_link_objects_changed
_makefw_link_objects_changed: ;

# Linux の末端では、入力が減るとリンク レシピ自体が実行されない。
# 変化した成果物だけに PHONY 依存を追加する。Windows は _msvc_compile で再確認する。
ifdef PLATFORM_LINUX
define _makefw_check_link_objects
ifneq ($$(abspath $(1)),$$(_MAKEFW_LINKED_OUTPUT_$(notdir $(1))))
$(1): _makefw_link_objects_changed
else ifneq ($$(call _makefw_link_expected,$(1)),$$(sort $$(_MAKEFW_LINKED_INPUTS_$(notdir $(1)))))
$(1): _makefw_link_objects_changed
endif
endef
$(foreach target,$(MAKEFW_LINK_TARGETS),$(eval $(call _makefw_check_link_objects,$(target))))
endif

# 保存一覧をレシピへ展開すると、Windows のコマンド ライン長の上限に達する。
# see: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw
define _MAKEFW_OBJLIST
objs_file="$(OBJDIR)/objs_$$$$.lst"; \
makefw_link_state="$(call _makefw_link_state,$@)"; \
trap 'rm -f "$$objs_file" "$${rsp_file:-}" "$${makefw_link_state_tmp:-}" "$${makefw_archive_tmp:-}"' EXIT; \
bash "$(MAKEFW_HOME)/bin_internal/filter_existing_source_objs.sh" $(1) all $(2) > "$$objs_file" || exit $$?; \
rebuild=0; makefw_link_inputs=""; \
while IFS= read -r obj; do \
    [ -n "$$obj" ] || continue; \
    makefw_link_inputs="$${makefw_link_inputs:+$$makefw_link_inputs }$${obj#./}"; \
    if [ "$$obj" -nt "$@" ]; then rebuild=1; fi; \
done < "$$objs_file"; \
for obj in $(call _makefw_link_extra_inputs,$@); do \
    makefw_link_inputs="$${makefw_link_inputs:+$$makefw_link_inputs }$${obj#./}"; \
done; \
makefw_saved_inputs=$$(sed -n 's/^_MAKEFW_LINKED_INPUTS_$(@F) := //p' "$$makefw_link_state" 2>/dev/null || true); \
if [ ! -f "$@" ] || [ "$@" -nt "$$makefw_link_state" ] || \
    [ "$(abspath $@)" != "$(_MAKEFW_LINKED_OUTPUT_$(@F))" ] || \
    [ "$$makefw_link_inputs" != "$$makefw_saved_inputs" ]; then rebuild=1; fi
endef

_MAKEFW_OBJLIST_LINUX = $(call _MAKEFW_OBJLIST,linux,)
_MAKEFW_OBJLIST_WINDOWS = $(call _MAKEFW_OBJLIST,windows,"$(MSVC_CRT_SUBDIR)")

# リンク成功後だけ一覧を置換する。失敗・中断時は前回の一覧を維持する。
define _MAKEFW_SAVE_LINK_OBJECTS
if [ "$$_rc" = 0 ]; then \
    makefw_link_state_tmp="$$makefw_link_state.$$$$.tmp"; \
    { printf '%s\n' '_MAKEFW_LINKED_OUTPUT_$(@F) := $(abspath $@)'; \
      printf '_MAKEFW_LINKED_INPUTS_$(@F) := %s\n' "$$makefw_link_inputs"; } > "$$makefw_link_state_tmp" \
        && mv "$$makefw_link_state_tmp" "$$makefw_link_state" || _rc=$$?; \
fi
endef

# 全入力がなくなった成果物を残すと、古いテストやライブラリを使い続けてしまう。
# Windows のリンク副産物も、同じ成果物名のものだけ削除する。
define _MAKEFW_REMOVE_EMPTY_ARTIFACT
rm -f "$@" "$$makefw_link_state" "$@.warn" \
    $(if $(PLATFORM_WINDOWS),"$(basename $@).pdb" $(if $(filter %.dll,$@),"$(basename $@).lib" "$(basename $@).exp")) || exit $$?; \
_rc=0
endef

endif
