SUBDIRS ?= $(wildcard */)
SUBDIRS := $(strip $(patsubst %/,%,$(SUBDIRS)))
SUBDIR_TARGETS := $(addprefix __subdir__,$(SUBDIRS))
SUBDIR_FORWARD_GOALS ?= $(filter-out $(SUBDIRS),$(MAKECMDGOALS))

.DEFAULT_GOAL := default

.PHONY: default build clean run restore rebuild
default : SUBDIR_FORWARD_GOALS =
default : $(SUBDIR_TARGETS)

build : SUBDIR_FORWARD_GOALS = build
build : $(SUBDIR_TARGETS)

clean : SUBDIR_FORWARD_GOALS = clean
clean : $(SUBDIR_TARGETS)

run : SUBDIR_FORWARD_GOALS = run
run : $(SUBDIR_TARGETS)

restore : SUBDIR_FORWARD_GOALS = restore
restore : $(SUBDIR_TARGETS)

rebuild : SUBDIR_FORWARD_GOALS = rebuild
rebuild : $(SUBDIR_TARGETS)

IS_TEST_SUBDIR := $(or $(findstring /test/,$(CURDIR)),$(filter %/test,$(CURDIR)))

ifneq (,$(IS_TEST_SUBDIR))
.PHONY: test
test : SUBDIR_FORWARD_GOALS = test
test : $(SUBDIR_TARGETS)
endif

define _make_subdir_alias
.PHONY: $(1)
$(1): __subdir__$(1)
endef

$(foreach dir,$(SUBDIRS),$(eval $(call _make_subdir_alias,$(dir))))

.PHONY: $(SUBDIR_TARGETS)
$(SUBDIR_TARGETS) :
	@dir=$(patsubst __subdir__%,%,$@); \
	if [ -f $$dir/makefile ]; then \
		if [ -n "$(SUBDIR_FORWARD_GOALS)" ]; then \
			echo $(MAKE) -C $$dir $(SUBDIR_FORWARD_GOALS); \
			$(MAKE) -C $$dir $(SUBDIR_FORWARD_GOALS) || exit 1; \
		else \
			echo $(MAKE) -C $$dir; \
			$(MAKE) -C $$dir || exit 1; \
		fi; \
	else \
		:; # echo "Skipping directory '$$dir' (no makefile)"; \
	fi
