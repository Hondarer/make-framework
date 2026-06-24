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
  resolve_app_deps.sh --paths <app-dir> <include|include_internal|lib|test_include|test_lib>
  resolve_app_deps.sh --paths-all <app-dir> [test]
  resolve_app_deps.sh --signature <app-dir> [build|test]
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

# appdeps.mk から APP_DEPS の値を make 経由で取得するフォールバック。
# make 関数 ($(...)) やバッククォートを含む複雑な appdeps.mk のための保険。
read_direct_deps_via_make() {
    local app_name="$1"
    local deps_file="$APP_ROOT_DIR/$app_name/appdeps.mk"
    local deps_makefile_path
    local tmp_makefile
    local output

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

read_direct_deps() {
    local app_name="$1"
    local deps_file="$APP_ROOT_DIR/$app_name/appdeps.mk"
    local output
    local rc=0

    if [[ ! -f "$deps_file" ]]; then
        return 0
    fi

    # appdeps.mk は通常 `APP_DEPS := <names>` の自明な代入のみ。
    # make の起動 (約 600[ms]/回) を避けるため awk 1 回で直接解析する。
    # make 関数呼び出し ($(...)) やバッククォートを検出した場合は exit 9 を返し、
    # make による厳密な評価へフォールバックする。
    output=$(awk '
        BEGIN { collecting = 0; complex = 0; n = 0 }
        ($0 ~ /\$\(/ || $0 ~ /`/) { complex = 1 }
        {
            line = $0
            sub(/#.*/, "", line)
            if (collecting) {
                cont = (line ~ /\\[[:space:]]*$/)
                sub(/\\[[:space:]]*$/, "", line)
                m = split(line, a, /[[:space:]]+/)
                for (i = 1; i <= m; i++) if (a[i] != "") tok[++n] = a[i]
                if (!cont) collecting = 0
                next
            }
            if (line ~ /^[[:space:]]*APP_DEPS[[:space:]]*[:+]?=/) {
                sub(/^[[:space:]]*APP_DEPS[[:space:]]*[:+]?=/, "", line)
                cont = (line ~ /\\[[:space:]]*$/)
                sub(/\\[[:space:]]*$/, "", line)
                m = split(line, a, /[[:space:]]+/)
                for (i = 1; i <= m; i++) if (a[i] != "") tok[++n] = a[i]
                if (cont) collecting = 1
            }
        }
        END {
            if (complex) exit 9
            for (i = 1; i <= n; i++) print tok[i]
        }
    ' "$deps_file") || rc=$?

    if [[ "$rc" -eq 9 ]]; then
        read_direct_deps_via_make "$app_name"
        return 0
    fi

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
        test_include)
            suffix="test/include"
            ;;
        test_lib)
            suffix="test/lib"
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

# 依存閉包を 1 度だけ計算し、INCDIR / LIBSDIR 系のパスを全種別まとめて出力する。
# prepare.mk が --paths を種別ごとに呼ぶと bash 起動と collect_app_closure が
# 重複するため、それを 1 回の呼び出しに集約する。
# 出力は 1 行 1 トークン "KIND:path" 形式。KIND は呼び出し側 (Make) が
# $(filter)/$(patsubst) で種別ごとに展開する。
#   INCLUDE   : prod/include      (閉包全体)
#   INTERNAL  : prod/include_internal (root app のみ。emit_paths と同じ扱い)
#   LIB       : prod/lib          (閉包全体)
#   TESTINC   : test/include      (want_test=test のときのみ、閉包全体)
#   TESTLIB   : test/lib          (want_test=test のときのみ、閉包全体)
emit_paths_all() {
    local app_dir="$1"
    local want_test="${2:-}"
    local root_app
    local app
    local path
    local -a closure=()

    root_app=$(resolve_root_app "$app_dir")

    while IFS= read -r app; do
        [[ -n "$app" ]] && closure+=("$app")
    done < <(collect_app_closure "$root_app")

    for app in "${closure[@]}"; do
        path="$APP_ROOT_DIR/$app/prod/include"
        [[ -d "$path" ]] && printf 'INCLUDE:%s\n' "$path"
    done

    path="$APP_ROOT_DIR/$root_app/prod/include_internal"
    [[ -d "$path" ]] && printf 'INTERNAL:%s\n' "$path"

    for app in "${closure[@]}"; do
        path="$APP_ROOT_DIR/$app/prod/lib"
        [[ -d "$path" ]] && printf 'LIB:%s\n' "$path"
    done

    if [[ "$want_test" == "test" ]]; then
        for app in "${closure[@]}"; do
            path="$APP_ROOT_DIR/$app/test/include"
            [[ -d "$path" ]] && printf 'TESTINC:%s\n' "$path"
        done
        for app in "${closure[@]}"; do
            path="$APP_ROOT_DIR/$app/test/lib"
            [[ -d "$path" ]] && printf 'TESTLIB:%s\n' "$path"
        done
    fi

    return 0
}

emit_signature() {
    local app_dir="$1"
    local mode="${2:-build}"
    local root_app
    local app
    local tmp_entries
    local tmp_paths
    local rel
    local hash
    local digest
    local msvc_crt="${MSVC_CRT_SUBDIR:-}"
    local config="${CONFIG:-}"
    local target_arch="${TARGET_ARCH:-${MAKEFW_TARGET_ARCH:-}}"
    local cflags="${CFLAGS:-}"
    local cxxflags="${CXXFLAGS:-}"
    local ldflags="${LDFLAGS:-}"
    local defines="${DEFINES:-}"
    local libs="${LIBS:-}"

    case "$mode" in
        build|test)
            ;;
        *)
            echo "ERROR: signature mode must be build or test: $mode" >&2
            return 2
            ;;
    esac

    root_app=$(resolve_root_app "$app_dir")
    tmp_entries=$(mktemp)
    tmp_paths=$(mktemp)

    while IFS= read -r app; do
        collect_signature_files "$app" "$mode" "$root_app"
    done < <(collect_app_closure "$root_app")

    # 収集した全ファイルを 1 回の sha256sum 起動で一括ハッシュする
    # (xargs が引数長制限に応じて自動分割する)。
    # sha256sum 出力 "<64桁hash>  <abspath>" を "<rel>\t<hash>" 形式へ変換する。
    if [[ -s "$tmp_paths" ]]; then
        xargs -0 sha256sum < "$tmp_paths" \
            | awk -v ws="$WORKSPACE_DIR/" '
                {
                    hash = substr($0, 1, 64)
                    path = substr($0, 67)
                    if (substr(path, 1, length(ws)) == ws) {
                        path = substr(path, length(ws) + 1)
                    }
                    print path "\t" hash
                }' >> "$tmp_entries"
    fi
    rm -f "$tmp_paths"

    {
        printf 'MODE\t%s\n' "$mode"
        printf 'CONFIG\t%s\n' "$config"
        printf 'MSVC_CRT\t%s\n' "$msvc_crt"
        printf 'TARGET_ARCH\t%s\n' "$target_arch"
        printf 'CFLAGS\t%s\n' "$cflags"
        printf 'CXXFLAGS\t%s\n' "$cxxflags"
        printf 'LDFLAGS\t%s\n' "$ldflags"
        printf 'DEFINES\t%s\n' "$defines"
        printf 'LIBS\t%s\n' "$libs"
        LC_ALL=C sort -u "$tmp_entries"
    } > "$tmp_entries.sorted"
    mv "$tmp_entries.sorted" "$tmp_entries"

    digest=$(sha256sum "$tmp_entries" | awk '{ print $1 }')

    printf 'CLEAN=1\n'
    printf 'SIGNATURE_MODE=%s\n' "$mode"
    printf 'BUILD_SIGNATURE=v1:%s\n' "$digest"
    if [[ -n "$config" ]]; then
        printf 'CONFIG=%s\n' "$config"
    fi
    if [[ -n "$msvc_crt" ]]; then
        printf 'MSVC_CRT=%s\n' "$msvc_crt"
    fi
    if [[ -n "$target_arch" ]]; then
        printf 'TARGET_ARCH=%s\n' "$target_arch"
    fi
    if [[ -n "$cflags" ]]; then
        printf 'CFLAGS=%s\n' "$cflags"
    fi
    if [[ -n "$cxxflags" ]]; then
        printf 'CXXFLAGS=%s\n' "$cxxflags"
    fi
    if [[ -n "$ldflags" ]]; then
        printf 'LDFLAGS=%s\n' "$ldflags"
    fi
    if [[ -n "$defines" ]]; then
        printf 'DEFINES=%s\n' "$defines"
    fi
    if [[ -n "$libs" ]]; then
        printf 'LIBS=%s\n' "$libs"
    fi
    cat "$tmp_entries"
    rm -f "$tmp_entries"
}

is_signature_file() {
    local path="$1"
    local base="${path##*/}"

    case "$base" in
        makefile|makepart.mk|makechild.mk|makelocal.mk|appdeps.mk|Directory.Build.props|Directory.Build.targets|*.csproj|*.sln|*.props|*.targets|*.filter.sh|*.inject.*)
            return 0
            ;;
    esac

    case "${base,,}" in
        *.c|*.cc|*.cpp|*.cxx|*.h|*.hh|*.hpp|*.hxx|*.cs|*.mc|*.rc)
            return 0
            ;;
    esac

    return 1
}

is_excluded_signature_path() {
    local rel="$1"

    case "$rel" in
        */bin/*|bin/*|*/lib/*|lib/*|*/obj/*|obj/*|*/gcov/*|gcov/*|*/lcov/*|lcov/*|*/coverage/*|coverage/*|*/results/*|results/*|*/docs/doxybook2*|docs/doxybook2*|*/xml/*|xml/*|*/xml_org/*|xml_org/*)
            return 0
            ;;
        *.warn|make_build.stamp|make_test.stamp|make_doxy.stamp|coverage.xml)
            return 0
            ;;
    esac

    return 1
}

# 署名対象ファイルを収集する。ハッシュ計算はここでは行わず、
# 絶対パスを NUL 区切りで $tmp_paths へ追記するのみとする。
# 全ファイルを集めた後に emit_signature が一括で sha256sum する
# (ファイル 1 個ごとの sha256sum 起動を避ける)。
add_signature_file() {
    local path="$1"
    local rel

    if [[ ! -f "$path" ]]; then
        return 0
    fi

    rel="${path#$WORKSPACE_DIR/}"
    if [[ "$rel" == "$path" ]]; then
        return 0
    fi
    if is_excluded_signature_path "$rel"; then
        return 0
    fi
    if ! is_signature_file "$path"; then
        return 0
    fi

    printf '%s\0' "$path" >> "$tmp_paths"
}

collect_tree_signature_files() {
    local dir="$1"

    if [[ ! -d "$dir" ]]; then
        return 0
    fi

    # find が返す各ファイルを 1 個の awk で一括フィルターし、合格パスを
    # NUL 区切りで $tmp_paths へ追記する。ファイル単位の bash ループ
    # (add_signature_file の繰り返し呼び出し) を廃し、プロセス内反復コストを削減する。
    # フィルター条件は is_excluded_signature_path() / is_signature_file() と
    # 1 対 1 で対応させること (下記コメント参照)。find が -type f を保証するため
    # add_signature_file() の [[ -f ]] 検査は省く。
    find "$dir" \
        \( -path '*/bin' -o -path '*/lib' -o -path '*/obj' -o -path '*/gcov' -o -path '*/lcov' -o -path '*/coverage' -o -path '*/results' \) -prune \
        -o -type f -print0 \
    | awk -v ws="$WORKSPACE_DIR/" '
        BEGIN { RS = "\0"; ORS = "\0" }
        {
            path = $0
            if (path == "") next

            # ワークスペース外は対象外 (add_signature_file の rel==path 判定に相当)
            wl = length(ws)
            if (substr(path, 1, wl) != ws) next
            rel = substr(path, wl + 1)

            # is_excluded_signature_path() 相当
            #   */bin/* | bin/* | ... | */xml_org/* | xml_org/*
            if (rel ~ /(^|\/)(bin|lib|obj|gcov|lcov|coverage|results|xml|xml_org)\//) next
            #   */docs/doxybook2* | docs/doxybook2*
            if (rel ~ /(^|\/)docs\/doxybook2/) next
            #   *.warn
            if (rel ~ /\.warn$/) next
            #   make_build.stamp | make_test.stamp | make_doxy.stamp | coverage.xml (rel 完全一致)
            if (rel == "make_build.stamp" || rel == "make_test.stamp" || rel == "make_doxy.stamp" || rel == "coverage.xml") next

            # is_signature_file() 相当 (base = パス最終要素)
            n = split(path, parts, "/")
            base = parts[n]
            keep = 0
            #   固定名 (大文字小文字を区別)
            if (base == "makefile" || base == "makepart.mk" || base == "makechild.mk" || base == "makelocal.mk" || base == "appdeps.mk" || base == "Directory.Build.props" || base == "Directory.Build.targets") {
                keep = 1
            #   *.csproj | *.sln | *.props | *.targets | *.filter.sh | *.inject.*
            } else if (base ~ /\.(csproj|sln|props|targets)$/ || base ~ /\.filter\.sh$/ || base ~ /\.inject\./) {
                keep = 1
            } else {
                #   ソース拡張子は小文字化して判定: *.c|*.cc|*.cpp|*.cxx|*.h|*.hh|*.hpp|*.hxx|*.cs|*.mc|*.rc
                lb = tolower(base)
                if (lb ~ /\.(c|cc|cpp|cxx|h|hh|hpp|hxx|cs|mc|rc)$/) keep = 1
            }

            if (keep) print path
        }
    ' >> "$tmp_paths"
}

collect_signature_files() {
    local app="$1"
    local mode="$2"
    local root_app="$3"
    local app_path="$APP_ROOT_DIR/$app"
    local extra

    add_signature_file "$app_path/makefile"
    add_signature_file "$app_path/makepart.mk"
    add_signature_file "$app_path/makelocal.mk"
    add_signature_file "$app_path/appdeps.mk"
    collect_tree_signature_files "$app_path/prod"

    if [[ "$mode" == "test" ]]; then
        collect_tree_signature_files "$app_path/test"
    fi

    add_signature_file "$WORKSPACE_DIR/Directory.Build.props"
    add_signature_file "$WORKSPACE_DIR/Directory.Build.targets"

    if [[ "$mode" == "test" && "$app" == "$root_app" ]]; then
        while IFS= read -r extra; do
            [[ -z "$extra" ]] && continue
            add_signature_file "$extra"
        done < <(
            find "$app_path/test" -name makepart.mk -o -name makelocal.mk 2>/dev/null \
                | while IFS= read -r make_config; do
                    awk '
                        /^[[:space:]]*(TEST_SRCS|ADD_SRCS)[[:space:]]*[+:?]?=/ {
                            in_var = 1
                        }
                        in_var {
                            continued = ($0 ~ /\\$/)
                            gsub(/\\$/, "")
                            for (i = 1; i <= NF; i++) {
                                if ($i ~ /^\$\(MYAPP_DIR\)/ || $i ~ /^\$\(APP_DIR\)/ || $i ~ /^\$\(WORKSPACE_DIR\)/) {
                                    value = $i
                                    gsub(/\$\(MYAPP_DIR\)/, "'"$app_path"'", value)
                                    gsub(/\$\(APP_DIR\)/, "'"$APP_ROOT_DIR"'", value)
                                    gsub(/\$\(WORKSPACE_DIR\)/, "'"$WORKSPACE_DIR"'", value)
                                    print value
                                }
                            }
                            if (!continued) {
                                in_var = 0
                            }
                        }
                    ' "$make_config"
                done
        )
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
        --paths-all)
            if [[ -z "$app_dir" ]]; then
                usage
                return 2
            fi
            emit_paths_all "$app_dir" "$kind"
            ;;
        --signature)
            if [[ -z "$app_dir" ]]; then
                usage
                return 2
            fi
            emit_signature "$app_dir" "${kind:-build}"
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
