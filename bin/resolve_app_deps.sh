#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

find_workspace_root() {
    local dir="$1"

    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/.workspaceRoot" ]]; then
            printf '%s\n' "$dir"
            return 0
        fi
        dir=$(dirname -- "$dir")
    done

    return 1
}

usage() {
    cat <<'EOF' >&2
Usage:
  resolve_app_deps.sh --paths <app-dir> <include|include_internal|lib>
  resolve_app_deps.sh --signature <app-dir>
  resolve_app_deps.sh --app-order
EOF
}

WORKSPACE_DIR=$(find_workspace_root "$SCRIPT_DIR") || {
    echo "workspace root not found" >&2
    exit 2
}
APP_ROOT_DIR="$WORKSPACE_DIR/app"

to_make_include_path() {
    local path="$1"

    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$path"
        return 0
    fi

    printf '%s\n' "$path"
}

lower_ext() {
    printf '%s' "${1,,}"
}

read_direct_deps() {
    local app_name="$1"
    local deps_file="$APP_ROOT_DIR/$app_name/appdeps.mk"
    local deps_makefile_path
    local tmp_makefile
    local output

    if [[ ! -f "$deps_file" ]]; then
        return 0
    fi
    deps_makefile_path=$(to_make_include_path "$deps_file")

    tmp_makefile=$(mktemp)
    {
        printf 'APP_DEPS :=\n'
        printf -- '-include %s\n' "$deps_makefile_path"
        cat <<'EOF'
print:
	@printf '%s\n' "$(APP_DEPS)"
EOF
    } > "$tmp_makefile"

    output=$(MAKEFLAGS= MFLAGS= make --no-print-directory -f "$tmp_makefile" print)
    rm -f "$tmp_makefile"

    if [[ -n "$output" ]]; then
        printf '%s\n' $output
    fi
}

list_apps() {
    find "$APP_ROOT_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort
}

resolve_root_app() {
    local app_dir="$1"
    local full_path
    local relative

    full_path=$(cd "$app_dir" && pwd -P)
    relative="${full_path#$APP_ROOT_DIR/}"

    if [[ "$relative" == "$full_path" ]]; then
        echo "app directory is outside workspace app/: $app_dir" >&2
        return 1
    fi

    printf '%s\n' "${relative%%/*}"
}

collect_app_closure() {
    local root_app="$1"
    local -A visited=()
    local -a queue=("$root_app")
    local -a ordered=()
    local app
    local dep

    while (( ${#queue[@]} > 0 )); do
        app="${queue[0]}"
        queue=("${queue[@]:1}")

        if [[ -n "${visited[$app]+x}" ]]; then
            continue
        fi
        visited["$app"]=1

        if [[ ! -d "$APP_ROOT_DIR/$app" ]]; then
            echo "ERROR: app dependency '$app' was declared but directory '$APP_ROOT_DIR/$app' does not exist." >&2
            return 1
        fi

        ordered+=("$app")

        while IFS= read -r dep; do
            if [[ -n "$dep" ]]; then
                queue+=("$dep")
            fi
        done < <(read_direct_deps "$app")
    done

    printf '%s\n' "${ordered[@]}"
}

emit_paths() {
    local app_dir="$1"
    local kind="$2"
    local suffix
    local root_app
    local app
    local path
    local -a items=()

    case "$kind" in
        include)
            suffix="prod/include"
            ;;
        include_internal)
            suffix="prod/include_internal"
            ;;
        lib)
            suffix="prod/lib"
            ;;
        *)
            usage
            return 2
            ;;
    esac

    root_app=$(resolve_root_app "$app_dir")

    if [[ "$kind" == "include_internal" ]]; then
        path="$APP_ROOT_DIR/$root_app/$suffix"
        if [[ -d "$path" ]]; then
            printf '%s\n' "$path"
        fi
        return 0
    fi

    while IFS= read -r app; do
        path="$APP_ROOT_DIR/$app/$suffix"
        if [[ -d "$path" ]]; then
            items+=("$path")
        fi
    done < <(collect_app_closure "$root_app")

    printf '%s\n' "${items[*]}"
}

repo_is_clean_equivalent() {
    local repo="$1"
    local changed
    local path
    local ext
    local has_changes=0

    while IFS= read -r changed; do
        [[ -z "$changed" ]] && continue
        has_changes=1
        ext=".${changed##*.}"
        ext=$(lower_ext "$ext")
        case "$ext" in
            .md|.svg|.png)
                ;;
            *)
                return 1
                ;;
        esac
    done < <(git -C "$repo" diff --name-only HEAD -- 2>/dev/null || true)

    if [[ $has_changes -eq 0 ]]; then
        return 0
    fi

    return 0
}

emit_signature() {
    local app_dir="$1"
    local root_app
    local app
    local repo
    local head
    local clean=1
    local repo_clean=1
    local -A repos_seen=()
    local -a repos=()
    local -a lines=()

    root_app=$(resolve_root_app "$app_dir")

    while IFS= read -r app; do
        repo=$(git -C "$APP_ROOT_DIR/$app" rev-parse --show-toplevel 2>/dev/null || true)
        if [[ -z "$repo" ]]; then
            clean=0
            continue
        fi
        if [[ -z "${repos_seen[$repo]+x}" ]]; then
            repos_seen["$repo"]=1
            repos+=("$repo")
        fi
    done < <(collect_app_closure "$root_app")

    IFS=$'\n' repos=($(printf '%s\n' "${repos[@]}" | LC_ALL=C sort))
    unset IFS

    for repo in "${repos[@]}"; do
        head=$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)
        if [[ -z "$head" ]]; then
            clean=0
            repo_clean=0
        else
            if repo_is_clean_equivalent "$repo"; then
                repo_clean=1
            else
                clean=0
                repo_clean=0
            fi
        fi

        lines+=("$repo"$'\t'"$head"$'\t'"$repo_clean")
    done

    printf 'CLEAN=%s\n' "$clean"
    if (( ${#lines[@]} > 0 )); then
        printf '%s\n' "${lines[@]}"
    fi
}

visit_app_for_order() {
    local app="$1"
    local source_app="${2:-$1}"
    local dep
    local state_name="$3"
    local ordered_name="$4"
    local -n state_map="$state_name"
    local -n ordered_list="$ordered_name"
    local -a deps=()

    if [[ "${state_map[$app]-}" == "done" ]]; then
        return 0
    fi
    if [[ "${state_map[$app]-}" == "visiting" ]]; then
        echo "ERROR: cyclic app dependency detected at '$app'." >&2
        return 1
    fi
    if [[ ! -d "$APP_ROOT_DIR/$app" ]]; then
        echo "ERROR: app dependency '$app' was declared by '$source_app' but directory '$APP_ROOT_DIR/$app' does not exist." >&2
        return 1
    fi

    state_map["$app"]="visiting"

    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        deps+=("$dep")
    done < <(read_direct_deps "$app")

    if (( ${#deps[@]} > 0 )); then
        IFS=$'\n' deps=($(printf '%s\n' "${deps[@]}" | LC_ALL=C sort -u))
        unset IFS
        for dep in "${deps[@]}"; do
            visit_app_for_order "$dep" "$app" "$state_name" "$ordered_name" || return 1
        done
    fi

    state_map["$app"]="done"
    ordered_list+=("$app")
}

emit_app_order() {
    local app
    local -a apps=()
    local -a ordered=()
    local -A state=()

    while IFS= read -r app; do
        [[ -z "$app" ]] && continue
        apps+=("$app")
    done < <(list_apps)

    for app in "${apps[@]}"; do
        visit_app_for_order "$app" "$app" state ordered || return 1
    done

    printf '%s\n' "${ordered[*]}"
}

main() {
    local mode="${1:-}"
    local app_dir="${2:-}"
    local kind="${3:-}"

    case "$mode" in
        --paths)
            if [[ -z "$app_dir" || -z "$kind" ]]; then
                usage
                return 2
            fi
            emit_paths "$app_dir" "$kind"
            ;;
        --signature)
            if [[ -z "$app_dir" ]]; then
                usage
                return 2
            fi
            emit_signature "$app_dir"
            ;;
        --app-order)
            emit_app_order
            ;;
        *)
            usage
            return 2
            ;;
    esac
}

main "$@"
