# make とコンパイラに割り当てる並列度を解決する共通処理。
# recipe 内で評価し、解決した CPU 予算を子 make へ引き継ぐ。

ifndef _MAKEFW_PARALLEL_MK
_MAKEFW_PARALLEL_MK := 1

_MAKEFW_USER_SET_ORIGIN = $(filter command line environment environment override,$(1))
MAKEFW_HAS_USER_JOBS := $(if $(call _MAKEFW_USER_SET_ORIGIN,$(origin JOBS)),1,)
MAKEFW_HAS_USER_JOBS_EFFECTIVE := $(if $(call _MAKEFW_USER_SET_ORIGIN,$(origin JOBS_EFFECTIVE)),1,)
MAKEFW_HAS_USER_CL_MP_JOBS := $(if $(call _MAKEFW_USER_SET_ORIGIN,$(origin MAKEFW_CL_MP_JOBS)),1,)
MAKEFW_HAS_USER_MSBUILD_JOBS := $(if $(call _MAKEFW_USER_SET_ORIGIN,$(origin MAKEFW_MSBUILD_JOBS)),1,)
MAKEFW_HAS_USER_CPU_BUDGET := $(if $(call _MAKEFW_USER_SET_ORIGIN,$(origin MAKEFW_CPU_BUDGET)),1,)

JOBS ?= 6
JOBS_EFFECTIVE ?= $(JOBS)

MAKEFW_AUTO_DEFAULT_PARALLEL := $(if $(strip $(MAKECMDGOALS)),$(if $(filter 1,$(words $(MAKECMDGOALS))),$(if $(filter default build clean rebuild test _test_build,$(MAKECMDGOALS)),1,),),1)
MAKEFW_ALLOW_JOB_FALLBACK := $(or $(MAKEFW_AUTO_DEFAULT_PARALLEL),$(MAKEFW_HAS_USER_JOBS),$(MAKEFW_HAS_USER_JOBS_EFFECTIVE))

# makeflags、明示設定、自動設定の順で外側と内側の並列度を解決する。
# Linux の make は CPU 数と 16 の小さい方を使う。
# Windows の make は ceil(sqrt(CPU 数)) と 8 の小さい方を使う。
# MSVC と MSBuild は floor(CPU 数 / make 並列度) を 1 から 16 の範囲で使う。
define _MAKEFW_RESOLVE_PARALLEL_SHELL
	makeflags="$${MAKEFLAGS:-} $${MFLAGS:-}"; \
	jobs=""; \
	inner_jobs=""; \
	cl_jobs=""; \
	msbuild_jobs=""; \
	has_parallel=""; \
	unlimited_parallel=""; \
	allow_job_fallback="$(MAKEFW_ALLOW_JOB_FALLBACK)"; \
	for arg in $$makeflags; do \
		case "$$arg" in \
			-j|--jobs) has_parallel=1; unlimited_parallel=1 ;; \
			-j[0-9]*) has_parallel=1; jobs="$${arg#-j}" ;; \
			--jobs=[0-9]*) has_parallel=1; jobs="$${arg#--jobs=}" ;; \
			--jobserver-auth=*|--jobserver-fds=*) has_parallel=1 ;; \
		esac; \
	done; \
	if [ -z "$$jobs" ] && [ -z "$$unlimited_parallel" ] && [ "$(MAKEFW_HAS_USER_JOBS_EFFECTIVE)" = "1" ]; then jobs="$(JOBS_EFFECTIVE)"; fi; \
	if [ -z "$$jobs" ] && [ -z "$$unlimited_parallel" ] && [ "$(MAKEFW_HAS_USER_JOBS)" = "1" ]; then jobs="$(JOBS)"; fi; \
	cpu="$(MAKEFW_CPU_BUDGET)"; \
	if [ -z "$$cpu" ] && [ "$(OS)" = "Windows_NT" ]; then cpu="$${NUMBER_OF_PROCESSORS:-}"; fi; \
	if [ -z "$$cpu" ] && [ "$(OS)" != "Windows_NT" ]; then cpu=$$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || true); fi; \
	case "$$cpu" in \
		''|*[!0-9]*|0) \
			if [ "$(MAKEFW_HAS_USER_CPU_BUDGET)" = "1" ]; then echo "ERROR: MAKEFW_CPU_BUDGET must be a positive integer: $(MAKEFW_CPU_BUDGET)" >&2; exit 2; fi; \
			cpu=6 ;; \
	esac; \
	if [ -z "$$jobs" ] && [ -z "$$unlimited_parallel" ] && [ -n "$$allow_job_fallback" ]; then \
		if [ "$(OS)" = "Windows_NT" ]; then \
			jobs=1; \
			while [ $$((jobs * jobs)) -lt $$cpu ] && [ $$jobs -lt 8 ]; do jobs=$$((jobs + 1)); done; \
		else \
			jobs=$$cpu; \
			if [ $$jobs -gt 16 ]; then jobs=16; fi; \
		fi; \
	fi; \
	if [ -z "$$jobs" ] && [ -z "$$unlimited_parallel" ] && [ -n "$$allow_job_fallback" ]; then jobs="$(JOBS_EFFECTIVE)"; fi; \
	if [ -z "$$jobs" ] && [ -z "$$unlimited_parallel" ] && [ -n "$$allow_job_fallback" ]; then jobs="$(JOBS)"; fi; \
	case "$$jobs" in '') ;; *[!0-9]*|0) echo "ERROR: make jobs must be a positive integer: $$jobs" >&2; exit 2 ;; esac; \
	if [ -n "$$unlimited_parallel" ]; then \
		inner_jobs=1; \
	elif [ -n "$$jobs" ]; then \
		inner_jobs=$$((cpu / jobs)); \
		if [ $$inner_jobs -lt 1 ]; then inner_jobs=1; fi; \
		if [ $$inner_jobs -gt 16 ]; then inner_jobs=16; fi; \
	else \
		inner_jobs=1; \
	fi; \
	if [ "$(MAKEFW_HAS_USER_CL_MP_JOBS)" = "1" ]; then cl_jobs="$(MAKEFW_CL_MP_JOBS)"; fi; \
	if [ -z "$$cl_jobs" ]; then cl_jobs="$$inner_jobs"; fi; \
	if [ "$(MAKEFW_HAS_USER_MSBUILD_JOBS)" = "1" ]; then msbuild_jobs="$(MAKEFW_MSBUILD_JOBS)"; fi; \
	if [ -z "$$msbuild_jobs" ]; then msbuild_jobs="$$inner_jobs"; fi; \
	case "$$cl_jobs" in *[!0-9]*|0|'') echo "ERROR: MAKEFW_CL_MP_JOBS must be a positive integer: $$cl_jobs" >&2; exit 2 ;; esac; \
	case "$$msbuild_jobs" in *[!0-9]*|0|'') echo "ERROR: MAKEFW_MSBUILD_JOBS must be a positive integer: $$msbuild_jobs" >&2; exit 2 ;; esac; \
	parallel_make_args="MAKEFW_CPU_BUDGET=$$cpu MAKEFW_CL_MP_JOBS=$$cl_jobs MAKEFW_MSBUILD_JOBS=$$msbuild_jobs"; \
	if [ -n "$$jobs" ]; then parallel_make_args="JOBS_EFFECTIVE=$$jobs $$parallel_make_args"; fi; \
	if [ -z "$$has_parallel" ] && [ -n "$$jobs" ] && [ -n "$$allow_job_fallback" ]; then parallel_make_args="-j$$jobs $$parallel_make_args"; fi;
endef

endif
