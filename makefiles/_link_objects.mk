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

# % を先に保護し、Make の再読取で意味が変わらない表現へ変換する。
# strip/sort は引数内の空白やリンク順を変えるため使用しない。
_makefw_link_empty :=
_makefw_link_space := $(_makefw_link_empty) $(_makefw_link_empty)
_makefw_link_hash := \#
_makefw_link_dollar := $$
define _makefw_link_newline


endef
_makefw_link_tab := $(_makefw_link_empty)	$(_makefw_link_empty)
_makefw_link_encode = $(subst $(_makefw_link_newline),%0A,$(subst $(_makefw_link_tab),%09,$(subst $(_makefw_link_space),%20,$(subst |,%7C,$(subst ',%27,$(subst ",%22,$(subst $(_makefw_link_hash),%23,$(subst $(_makefw_link_dollar),%24,$(subst \,%5C,$(subst %,%25,$(1)))))))))))
_makefw_link_kind = $(if $(filter $(notdir $(1)),$(MAKEFW_STATIC_TARGETS)),static,$(MAKEFW_LINK_KIND))
_makefw_link_tool = $(if $(filter static,$(call _makefw_link_kind,$(1))),$(AR),$(if $(filter executable,$(MAKEFW_LINK_KIND)),$(LD),$(if $(PLATFORM_LINUX),$(CC),$(LD))))
_makefw_link_flags = $(if $(filter static,$(call _makefw_link_kind,$(1))),$(if $(PLATFORM_WINDOWS),$(LIB_LTCG)),$(LDFLAGS))
_makefw_link_libraries = $(if $(filter static,$(call _makefw_link_kind,$(1))),,$(if $(filter executable,$(MAKEFW_LINK_KIND)),$(LIBS),$(STATIC_LIBS) $(DYNAMIC_LIBS)))
_makefw_link_config = v1|kind=$(call _makefw_link_kind,$(1))|tool=$(call _makefw_link_encode,$(call _makefw_link_tool,$(1)))|flags=$(call _makefw_link_encode,$(call _makefw_link_flags,$(1)))|libs=$(call _makefw_link_encode,$(call _makefw_link_libraries,$(1)))|files=$(call _makefw_link_encode,$(if $(filter executable,$(MAKEFW_LINK_KIND)),$(LIBSFILES)))|extra=$(call _makefw_link_encode,$(MAKEFW_EXTRA_OBJS))|inputs=$(call _makefw_link_encode,$(if $(filter static,$(call _makefw_link_kind,$(1))),$(RESOURCE_OBJS),$(LINK_INPUTS)))
_makefw_link_config_changed = $(if $(and $(findstring |$(call _makefw_link_config,$(1))|,|$(_MAKEFW_LINKED_CONFIG_$(notdir $(1)))|),$(findstring |$(_MAKEFW_LINKED_CONFIG_$(notdir $(1)))|,|$(call _makefw_link_config,$(1))|)),,1)
_makefw_link_dry_run = $(findstring n,$(filter-out --%,$(firstword $(MAKEFLAGS))))
# Make 4.0 の file 関数で長い構成をシェル経由にせず渡す。-n では未作成の OBJDIR に書かない。
# see: https://www.gnu.org/software/make/manual/html_node/File-Function.html
_makefw_write_link_config = $(if $(_makefw_link_dry_run),,$(file >$(call _makefw_link_state,$(1)).expected,_MAKEFW_LINKED_CONFIG_$(notdir $(1)) := $(call _makefw_link_config,$(1))))

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
else ifneq ($$(call _makefw_link_config,$(1)),$$(_MAKEFW_LINKED_CONFIG_$(notdir $(1))))
$(1): _makefw_link_objects_changed
endif
endef
$(foreach target,$(MAKEFW_LINK_TARGETS),$(eval $(call _makefw_check_link_objects,$(target))))
endif

# Windows の both 構成では、共有出力が静的出力だけに依存する場合がある。
# 静的出力を変更しない共有リンク構成の差も、レシピを起動して確認する。
ifdef PLATFORM_WINDOWS
define _makefw_check_link_config
ifneq ($$(call _makefw_link_config,$(1)),$$(_MAKEFW_LINKED_CONFIG_$(notdir $(1))))
$(1): _makefw_link_objects_changed
endif
endef
$(foreach target,$(MAKEFW_LINK_TARGETS),$(eval $(call _makefw_check_link_config,$(target))))
endif

# 保存一覧をレシピへ展開すると、Windows のコマンド ライン長の上限に達する。
# see: https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw
define _MAKEFW_OBJLIST
$(call _makefw_write_link_config,$@)objs_file="$(OBJDIR)/objs_$$$$.lst"; \
makefw_link_state="$(call _makefw_link_state,$@)"; \
makefw_link_config_file="$$makefw_link_state.expected"; \
trap 'rm -f "$$objs_file" "$$makefw_link_config_file" "$${rsp_file:-}" "$${makefw_link_state_tmp:-}" "$${makefw_archive_tmp:-}"' EXIT; \
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
    [ '$(call _makefw_link_config_changed,$@)' = 1 ] || \
    [ "$$makefw_link_inputs" != "$$makefw_saved_inputs" ]; then rebuild=1; fi
endef

_MAKEFW_OBJLIST_LINUX = $(call _MAKEFW_OBJLIST,linux,)
_MAKEFW_OBJLIST_WINDOWS = $(call _MAKEFW_OBJLIST,windows,"$(MSVC_CRT_SUBDIR)")

# リンク成功後だけ一覧を置換する。失敗・中断時は前回の一覧を維持する。
define _MAKEFW_SAVE_LINK_OBJECTS
if [ "$$_rc" = 0 ]; then \
    makefw_link_state_tmp="$$makefw_link_state.$$$$.tmp"; \
    { printf '%s\n' '_MAKEFW_LINKED_OUTPUT_$(@F) := $(abspath $@)'; \
      printf '_MAKEFW_LINKED_INPUTS_$(@F) := %s\n' "$$makefw_link_inputs"; \
      cat "$$makefw_link_config_file"; } > "$$makefw_link_state_tmp" \
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
