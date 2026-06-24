# Windows の make と MSVC に割り当てる並列度を解決する共通処理。
# recipe 内で評価することで、並列度の計算だけを目的とした外部プロセス起動を避ける。

ifndef _MAKEFW_PARALLEL_MK
_MAKEFW_PARALLEL_MK := 1

_MAKEFW_USER_SET_ORIGIN = $(filter command line environment environment override,$(1))
MAKEFW_HAS_USER_JOBS := $(if $(call _MAKEFW_USER_SET_ORIGIN,$(origin JOBS)),1,)
MAKEFW_HAS_USER_JOBS_EFFECTIVE := $(if $(call _MAKEFW_USER_SET_ORIGIN,$(origin JOBS_EFFECTIVE)),1,)
MAKEFW_HAS_USER_CL_MP_JOBS := $(if $(call _MAKEFW_USER_SET_ORIGIN,$(origin MAKEFW_CL_MP_JOBS)),1,)

JOBS ?= 6
JOBS_EFFECTIVE ?= $(JOBS)

MAKEFW_AUTO_DEFAULT_PARALLEL := $(if $(strip $(MAKECMDGOALS)),$(if $(filter 1,$(words $(MAKECMDGOALS))),$(if $(filter default clean,$(MAKECMDGOALS)),1,),),1)
MAKEFW_ALLOW_JOB_FALLBACK := $(or $(MAKEFW_AUTO_DEFAULT_PARALLEL),$(MAKEFW_HAS_USER_JOBS),$(MAKEFW_HAS_USER_JOBS_EFFECTIVE))

# makeflags、明示設定、自動設定の順で jobs と cl_jobs を解決する。
# Windows の自動設定では make の並列度を ceil(sqrt(CPU 数)) (上限 8)、
# MSVC の並列度を floor(CPU 数 / make 並列度) (上限 16) とする。
define _MAKEFW_RESOLVE_PARALLEL_SHELL
	makeflags="$${MAKEFLAGS:-} $${MFLAGS:-}"; \
	jobs=""; \
	cl_jobs=""; \
	has_parallel=""; \
	allow_job_fallback="$(MAKEFW_ALLOW_JOB_FALLBACK)"; \
	for arg in $$makeflags; do \
		case "$$arg" in \
			-j|--jobs) has_parallel=1 ;; \
			-j[0-9]*) has_parallel=1; jobs="$${arg#-j}" ;; \
			--jobs=[0-9]*) has_parallel=1; jobs="$${arg#--jobs=}" ;; \
			--jobserver-auth=*|--jobserver-fds=*) has_parallel=1 ;; \
		esac; \
	done; \
	if [ -z "$$jobs" ] && [ "$(MAKEFW_HAS_USER_JOBS_EFFECTIVE)" = "1" ]; then jobs="$(JOBS_EFFECTIVE)"; fi; \
	if [ -z "$$jobs" ] && [ "$(MAKEFW_HAS_USER_JOBS)" = "1" ]; then jobs="$(JOBS)"; fi; \
	cpu="$${NUMBER_OF_PROCESSORS:-6}"; \
	case "$$cpu" in ''|*[!0-9]*|0) cpu=6 ;; esac; \
	if [ -z "$$jobs" ] && [ -n "$$allow_job_fallback" ] && [ "$(OS)" = "Windows_NT" ]; then \
		jobs=1; \
		while [ $$((jobs * jobs)) -lt $$cpu ] && [ $$jobs -lt 8 ]; do jobs=$$((jobs + 1)); done; \
	fi; \
	if [ -z "$$jobs" ] && [ -n "$$allow_job_fallback" ]; then jobs="$(JOBS_EFFECTIVE)"; fi; \
	if [ -z "$$jobs" ] && [ -n "$$allow_job_fallback" ]; then jobs="$(JOBS)"; fi; \
	if [ "$(MAKEFW_HAS_USER_CL_MP_JOBS)" = "1" ]; then cl_jobs="$(MAKEFW_CL_MP_JOBS)"; fi; \
	if [ -z "$$cl_jobs" ] && [ "$(OS)" = "Windows_NT" ] && [ -n "$$jobs" ]; then \
		cl_jobs=$$((cpu / jobs)); \
		if [ $$cl_jobs -lt 1 ]; then cl_jobs=1; fi; \
		if [ $$cl_jobs -gt 16 ]; then cl_jobs=16; fi; \
	fi; \
	if [ -z "$$cl_jobs" ]; then cl_jobs="$$jobs"; fi; \
	parallel_make_args=""; \
	if [ -n "$$jobs" ]; then parallel_make_args="JOBS_EFFECTIVE=$$jobs"; fi; \
	if [ -n "$$cl_jobs" ]; then parallel_make_args="$$parallel_make_args MAKEFW_CL_MP_JOBS=$$cl_jobs"; fi; \
	if [ -z "$$has_parallel" ] && [ -n "$$jobs" ] && [ -n "$$allow_job_fallback" ]; then parallel_make_args="-j$$jobs $$parallel_make_args"; fi;
endef

endif
