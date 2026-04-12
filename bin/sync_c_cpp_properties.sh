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
    cat <<'EOF'
Usage:
  sync_c_cpp_properties.sh --check
  sync_c_cpp_properties.sh --write
EOF
}

WORKSPACE_DIR=$(find_workspace_root "$SCRIPT_DIR") || {
    echo "workspace root not found" >&2
    exit 2
}
APP_DIR="$WORKSPACE_DIR/app"
VSCODE_FILE="$WORKSPACE_DIR/.vscode/c_cpp_properties.json"
WARN_FILE="$APP_DIR/c_cpp_properties.warn"
# --check では「設定差分あり」を warning として扱うため、内部エラーとは別の終了コードを使う
SYNC_WARN_EXIT=3

if [[ -d "$WORKSPACE_DIR/framework/testfw" ]]; then
    TESTFW_DIR="$WORKSPACE_DIR/framework/testfw"
elif [[ -d "$WORKSPACE_DIR/testfw" ]]; then
    TESTFW_DIR="$WORKSPACE_DIR/testfw"
else
    TESTFW_DIR="$WORKSPACE_DIR/framework/testfw"
fi

MODE="${1:-}"
case "$MODE" in
    --check|--write)
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

mapfile -t APPS < <(
    awk '
        /^SUBDIRS =/ { in_subdirs=1; next }
        in_subdirs {
            line=$0
            sub(/#.*/, "", line)
            gsub(/\\/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line == "") {
                exit
            }
            print line
        }
    ' "$APP_DIR/makefile" | while IFS= read -r app; do
        if [[ -f "$APP_DIR/$app/makepart.mk" ]]; then
            printf '%s\n' "$app"
        fi
    done
)

normalize_path() {
    local path="$1"

    # Resolve .. segments to get a clean absolute path
    if [[ "$path" == /* ]]; then
        path="$(realpath -m "$path")"
    fi

    if [[ "$path" == "$WORKSPACE_DIR"* ]]; then
        printf '%s\n' '${workspaceFolder}'"${path#$WORKSPACE_DIR}"
    else
        printf '%s\n' "$path"
    fi
}

normalize_define() {
    local define="$1"
    local key
    local value

    if [[ "$define" != *=* ]]; then
        printf '%s\n' "$define"
        return 0
    fi

    key="${define%%=*}"
    value="${define#*=}"

    if [[ "$value" == \'*\' ]]; then
        value="${value:1:${#value}-2}"
    fi

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"

    printf '%s=%s\n' "$key" "$value"
}

to_make_include_path() {
    local make_platform="$1"
    local path="$2"

    if [[ "$make_platform" == "Windows" ]] && command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$path"
        return 0
    fi

    printf '%s\n' "$path"
}

write_sync_makepart_includes() {
    local app="$1"
    local make_platform="$2"

    printf '%s\n' "-include $(to_make_include_path "$make_platform" "$WORKSPACE_DIR/makepart.mk")"
    printf '%s\n' "-include $(to_make_include_path "$make_platform" "$APP_DIR/makepart.mk")"
    printf '%s\n' "include $(to_make_include_path "$make_platform" "$APP_DIR/$app/makepart.mk")"
}

eval_makepart_var() {
    local app="$1"
    local config_name="$2"
    local var_name="$3"
    local make_platform
    local platform_flag
    local target_arch
    local tmp_makefile
    local tmp_output
    local value
    local marker_begin="__CMK_SYNC_BEGIN__"
    local marker_end="__CMK_SYNC_END__"

    if [[ "$config_name" == "Linux" ]]; then
        make_platform="Linux"
        platform_flag="PLATFORM_LINUX := 1"
        target_arch="linux-sync-x64"
    else
        make_platform="Windows"
        platform_flag="PLATFORM_WINDOWS := 1"
        target_arch="windows-sync-x64"
    fi

    tmp_makefile=$(mktemp)
    {
        cat <<EOF
WORKSPACE_DIR := $WORKSPACE_DIR
MYAPP_DIR := $APP_DIR/$app
TESTFW_DIR := $TESTFW_DIR
PLATFORM := $make_platform
$platform_flag
TARGET_ARCH := $target_arch
INCDIR :=
DEFINES :=
EOF
        write_sync_makepart_includes "$app" "$make_platform"
        cat <<'EOF'
print:
	@: $(info $(MARKER_BEGIN))$(info $($(PRINT_VAR)))$(info $(MARKER_END))
EOF
    } > "$tmp_makefile"

    tmp_output=$(mktemp)
    if ! make --no-print-directory -f "$tmp_makefile" \
        print \
        PRINT_VAR="$var_name" \
        MARKER_BEGIN="$marker_begin" \
        MARKER_END="$marker_end" \
        > "$tmp_output"; then
        rm -f "$tmp_makefile" "$tmp_output"
        return 1
    fi

    value=$(awk -v marker_begin="$marker_begin" -v marker_end="$marker_end" '
        $0 == marker_begin { capture = 1; next }
        $0 == marker_end { capture = 0; exit }
        capture { print }
    ' "$tmp_output")
    rm -f "$tmp_makefile" "$tmp_output"

    printf '%s\n' "$value"
}

collect_expected() {
    local platform="$1"
    local var_name="$2"
    local app
    local raw
    local item
    local normalized
    local -A seen=()
    local -a items=()

    for app in "${APPS[@]}"; do
        raw=$(eval_makepart_var "$app" "$platform" "$var_name")
        for item in $raw; do
            if [[ "$var_name" == "INCDIR" ]]; then
                normalized=$(normalize_path "$item")
            else
                normalized=$(normalize_define "$item")
            fi

            if [[ -z "$normalized" ]]; then
                continue
            fi

            if [[ -z "${seen[$normalized]+x}" ]]; then
                seen["$normalized"]=1
                items+=("$normalized")
            fi
        done
    done

    if (( ${#items[@]} > 0 )); then
        printf '%s\n' "${items[@]}" | LC_ALL=C sort
    fi
}

build_expected_defines() {
    local platform="$1"
    local tmp_file
    local define
    local -A seen=()
    local -a items=()

    tmp_file=$(mktemp)
    collect_expected "$platform" DEFINES > "$tmp_file"

    while IFS= read -r define; do
        if [[ -z "$define" ]]; then
            continue
        fi

        if [[ "$define" == TARGET_ARCH=* ]]; then
            continue
        fi

        if [[ -z "${seen[$define]+x}" ]]; then
            seen["$define"]=1
            items+=("$define")
        fi
    done < "$tmp_file"
    rm -f "$tmp_file"

    printf '%s\n' 'TARGET_ARCH=\"\"'
    if (( ${#items[@]} > 0 )); then
        printf '%s\n' "${items[@]}" | LC_ALL=C sort
    fi
}

define_comment() {
    local define="$1"

    case "$define" in
        'TARGET_ARCH=\"\"')
            printf '%s' ' // framework/makefw/makefiles/prepare.mk で定義される TARGET_ARCH をインテリセンスで模擬するため (コンパイル時には環境に応じて適切な値が渡される)'
            ;;
        *)
            ;;
    esac
}

read_current_array() {
    local config_name="$1"
    local key_name="$2"

    awk -v config_name="$config_name" -v key_name="$key_name" '
        BEGIN {
            in_config = 0
            in_array = 0
        }

        !in_config && $0 ~ "\"name\":[[:space:]]*\"" config_name "\"" {
            in_config = 1
            next
        }

        in_config && $0 ~ "\"" key_name "\":[[:space:]]*\\[" {
            in_array = 1
            next
        }

        in_array {
            line = $0
            sub(/\/\/.*/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            if (line ~ /^\],?$/) {
                exit
            }
            sub(/,$/, "", line)
            if (line == "") {
                next
            }
            gsub(/^"/, "", line)
            gsub(/"$/, "", line)
            print line
        }
    ' "$VSCODE_FILE"
}

write_array_block() {
    local key_name="$1"
    local src_file="$2"
    local dst_file="$3"
    local -a lines=()
    local i
    local comment

    mapfile -t lines < "$src_file"

    {
        printf '            "%s": [\n' "$key_name"
        for ((i = 0; i < ${#lines[@]}; i++)); do
            comment=""
            if [[ "$key_name" == "defines" ]]; then
                comment=$(define_comment "${lines[$i]}")
            fi
            if (( i + 1 < ${#lines[@]} )); then
                printf '                "%s",%s\n' "${lines[$i]}" "$comment"
            else
                printf '                "%s"%s\n' "${lines[$i]}" "$comment"
            fi
        done
        printf '            ],\n'
    } > "$dst_file"
}

compare_and_write_warn() {
    local diff_found=0
    local diff_file
    local section_file
    local tmp_files=("$@")

    section_file=$(mktemp)

    {
        printf 'c_cpp_properties.json is out of sync with makepart.mk, app/makepart.mk, and app/*/makepart.mk.\n'
        printf 'Run from workspace root:\n'
        printf '  bash framework/makefw/bin/sync_c_cpp_properties.sh --write\n'
        printf '\n'
    } > "$section_file"

    diff_file=$(mktemp)
    if ! diff -u "${tmp_files[0]}" "${tmp_files[1]}" > "$diff_file"; then
        diff_found=1
        {
            printf '[Linux includePath]\n'
            cat "$diff_file"
            printf '\n'
        } >> "$section_file"
    fi

    : > "$diff_file"
    if ! diff -u "${tmp_files[2]}" "${tmp_files[3]}" > "$diff_file"; then
        diff_found=1
        {
            printf '[Linux defines]\n'
            cat "$diff_file"
            printf '\n'
        } >> "$section_file"
    fi

    : > "$diff_file"
    if ! diff -u "${tmp_files[4]}" "${tmp_files[5]}" > "$diff_file"; then
        diff_found=1
        {
            printf '[Win32 includePath]\n'
            cat "$diff_file"
            printf '\n'
        } >> "$section_file"
    fi

    : > "$diff_file"
    if ! diff -u "${tmp_files[6]}" "${tmp_files[7]}" > "$diff_file"; then
        diff_found=1
        {
            printf '[Win32 defines]\n'
            cat "$diff_file"
        } >> "$section_file"
    fi

    rm -f "$diff_file"

    if (( diff_found )); then
        mv "$section_file" "$WARN_FILE"
        return "$SYNC_WARN_EXIT"
    fi

    rm -f "$section_file" "$WARN_FILE"
    return 0
}

if [[ ! -f "$VSCODE_FILE" ]]; then
    echo "$VSCODE_FILE not found" >&2
    exit 2
fi

tmp_linux_inc_expected=$(mktemp)
tmp_linux_def_expected=$(mktemp)
tmp_win_inc_expected=$(mktemp)
tmp_win_def_expected=$(mktemp)
tmp_linux_inc_current=$(mktemp)
tmp_linux_def_current=$(mktemp)
tmp_win_inc_current=$(mktemp)
tmp_win_def_current=$(mktemp)
tmp_linux_inc_block=""
tmp_linux_def_block=""
tmp_win_inc_block=""
tmp_win_def_block=""
tmp_vscode_out=""

trap 'rm -f "$tmp_linux_inc_expected" "$tmp_linux_def_expected" "$tmp_win_inc_expected" "$tmp_win_def_expected" "$tmp_linux_inc_current" "$tmp_linux_def_current" "$tmp_win_inc_current" "$tmp_win_def_current" "$tmp_linux_inc_block" "$tmp_linux_def_block" "$tmp_win_inc_block" "$tmp_win_def_block" "$tmp_vscode_out"' EXIT

collect_expected Linux INCDIR > "$tmp_linux_inc_expected"
build_expected_defines Linux > "$tmp_linux_def_expected"
collect_expected Win32 INCDIR > "$tmp_win_inc_expected"
build_expected_defines Win32 > "$tmp_win_def_expected"

read_current_array Linux includePath > "$tmp_linux_inc_current"
read_current_array Linux defines > "$tmp_linux_def_current"
read_current_array Win32 includePath > "$tmp_win_inc_current"
read_current_array Win32 defines > "$tmp_win_def_current"

if [[ "$MODE" == "--check" ]]; then
    compare_and_write_warn \
        "$tmp_linux_inc_current" "$tmp_linux_inc_expected" \
        "$tmp_linux_def_current" "$tmp_linux_def_expected" \
        "$tmp_win_inc_current" "$tmp_win_inc_expected" \
        "$tmp_win_def_current" "$tmp_win_def_expected"
    exit $?
fi

tmp_linux_inc_block=$(mktemp)
tmp_linux_def_block=$(mktemp)
tmp_win_inc_block=$(mktemp)
tmp_win_def_block=$(mktemp)
tmp_vscode_out=$(mktemp)

write_array_block includePath "$tmp_linux_inc_expected" "$tmp_linux_inc_block"
write_array_block defines "$tmp_linux_def_expected" "$tmp_linux_def_block"
write_array_block includePath "$tmp_win_inc_expected" "$tmp_win_inc_block"
write_array_block defines "$tmp_win_def_expected" "$tmp_win_def_block"

awk \
    -v linux_inc_block="$tmp_linux_inc_block" \
    -v linux_def_block="$tmp_linux_def_block" \
    -v win_inc_block="$tmp_win_inc_block" \
    -v win_def_block="$tmp_win_def_block" '
    function print_file(path, line) {
        while ((getline line < path) > 0) {
            print line
        }
        close(path)
    }

    BEGIN {
        config_name = ""
        skip_array = 0
    }

    {
        if ($0 ~ /"name":[[:space:]]*"Linux"/) {
            config_name = "Linux"
        } else if ($0 ~ /"name":[[:space:]]*"Win32"/) {
            config_name = "Win32"
        }

        if (skip_array) {
            if ($0 ~ /^[[:space:]]*\],?$/) {
                skip_array = 0
            }
            next
        }

        if (config_name == "Linux" && $0 ~ /"includePath":[[:space:]]*\[/) {
            print_file(linux_inc_block)
            skip_array = 1
            next
        }

        if (config_name == "Linux" && $0 ~ /"defines":[[:space:]]*\[/) {
            print_file(linux_def_block)
            skip_array = 1
            next
        }

        if (config_name == "Win32" && $0 ~ /"includePath":[[:space:]]*\[/) {
            print_file(win_inc_block)
            skip_array = 1
            next
        }

        if (config_name == "Win32" && $0 ~ /"defines":[[:space:]]*\[/) {
            print_file(win_def_block)
            skip_array = 1
            next
        }

        print
    }
' "$VSCODE_FILE" > "$tmp_vscode_out"

mv "$tmp_vscode_out" "$VSCODE_FILE"
rm -f "$WARN_FILE"

printf 'Updated %s\n' "$VSCODE_FILE"
