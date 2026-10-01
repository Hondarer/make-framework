# GNU Make の単語用関数はバックスラッシュで保護した空白も分割する。
# 単一パスは関数の内部だけ空白を符号化し、include の構文では空白をエスケープする。
# see: https://www.gnu.org/software/make/manual/html_node/File-Name-Functions.html
# see: https://www.gnu.org/software/make/manual/html_node/Include.html
_makefw_empty :=
_makefw_space := $(_makefw_empty) $(_makefw_empty)
_makefw_encode_path = $(subst $(_makefw_space),__MAKEFW_SPACE__,$(1))
_makefw_decode_path = $(subst __MAKEFW_SPACE__,$(_makefw_space),$(1))
_makefw_escape_path = $(subst $(_makefw_space),\$(_makefw_space),$(1))
_makefw_path_dir = $(call _makefw_decode_path,$(dir $(call _makefw_encode_path,$(1))))
_makefw_path_notdir = $(call _makefw_decode_path,$(notdir $(call _makefw_encode_path,$(1))))
_makefw_path_abspath = $(call _makefw_decode_path,$(abspath $(call _makefw_encode_path,$(subst \,/,$(1)))))
_makefw_path_exists = $(wildcard $(call _makefw_escape_path,$(1)))

# 設定ファイルで \ により保護した空白を、パス リストの分割前に符号化する。
# 保護のない空白は make が読み込んだ時点で区切りと区別できないため、検出できない。
_makefw_encode_escaped_spaces = $(subst \$(_makefw_space),__MAKEFW_SPACE__,$(1))
_makefw_unescape_path = $(subst \$(_makefw_space),$(_makefw_space),$(1))

# 符号化済みのパスを、CURDIR からの相対パスへ make の関数だけで変換する。
# 解析のたびに bash と realpath を起動すると、Windows では 1 回あたり 0.5 [s] 前後かかる。
# 相対パスにするのはワークスペース内のパスだけとし、外のパスは絶対パスのまま返す。
# 先頭の要素が CURDIR と一致しない場合 (別ドライブなど) も絶対パスのまま返す。
# 要素の比較は区切り文字 | で囲んだ完全一致とし、filter の % の解釈を避ける。
_makefw_path_same_head = $(and $(firstword $(1)),$(firstword $(2)),$(findstring |$(firstword $(1))|,|$(firstword $(2))|))
_makefw_path_rest = $(wordlist 2,$(words $(1)),$(1))
_makefw_path_rest_base = $(if $(call _makefw_path_same_head,$(1),$(2)),$(call _makefw_path_rest_base,$(call _makefw_path_rest,$(1)),$(call _makefw_path_rest,$(2))),$(1))
_makefw_path_rest_target = $(if $(call _makefw_path_same_head,$(1),$(2)),$(call _makefw_path_rest_target,$(call _makefw_path_rest,$(1)),$(call _makefw_path_rest,$(2))),$(2))
_makefw_path_join_relative = $(or $(subst $(_makefw_space),/,$(strip $(patsubst %,..,$(1)) $(2))),.)
_makefw_path_relative_from = $(if $(call _makefw_path_same_head,$(1),$(2)),$(call _makefw_path_join_relative,$(call _makefw_path_rest_base,$(1),$(2)),$(call _makefw_path_rest_target,$(1),$(2))),$(3))
_makefw_path_relative_abs = $(call _makefw_path_relative_from,$(subst /, ,$(call _makefw_encode_path,$(CURDIR))),$(subst /, ,$(1)),$(1))
_makefw_path_in_workspace = $(or $(if $(WORKSPACE_DIR),,1),$(filter $(call _makefw_encode_path,$(WORKSPACE_DIR))/%,$(1)/))
_makefw_path_relative_in_workspace = $(if $(call _makefw_path_in_workspace,$(1)),$(call _makefw_path_relative_abs,$(1)),$(1))
_makefw_path_is_absolute = $(or $(filter /%,$(1)),$(findstring :/,$(1)))
_makefw_path_encoded_abspath = $(abspath $(if $(call _makefw_path_is_absolute,$(1)),$(1),$(call _makefw_encode_path,$(CURDIR))/$(1)))

# 正規化後も空白が残るパスは、ビルド グラフやコマンドで分割されるため使えない。
# Windows では 8.3 形式の短い名前を試す。短い名前はボリュームの設定で生成されない場合があり、
# 存在しないパスにも付かないため、得られなければ Linux と同じく停止する。
# see: https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/fsutil-8dot3name
_makefw_path_space_error = $(error $(if $(2),$(2): )path contains spaces$(if $(PLATFORM_WINDOWS), and no 8.3 short name is available): $(call _makefw_decode_path,$(1)). Spaces are supported only in the workspace location. See framework/makefw/docs/makeparts.md)
_makefw_path_checked_short_name = $(if $(and $(1),$(if $(findstring __MAKEFW_SPACE__,$(1)),,1)),$(1),$(call _makefw_path_space_error,$(2),$(3)))
_makefw_path_short_name = $(call _makefw_path_checked_short_name,$(call _makefw_encode_path,$(shell cygpath -s -m "$(call _makefw_decode_path,$(call _makefw_path_encoded_abspath,$(1)))" 2>/dev/null)),$(1),$(2))
_makefw_path_without_space = $(if $(findstring __MAKEFW_SPACE__,$(1)),$(if $(PLATFORM_WINDOWS),$(call _makefw_path_short_name,$(1),$(2)),$(call _makefw_path_space_error,$(1),$(2))),$(1))

# Windows で MSYS 形式 (/d/...) が明示された場合だけ、cygpath を使う補助スクリプトへ委ねる。
# $(1): 符号化済みのパス 1 つ、$(2): エラー表示用の変数名 (省略可)
_makefw_normalize_encoded_path = $(call _makefw_path_without_space,$(if $(and $(PLATFORM_WINDOWS),$(filter /%,$(1))),$(call _makefw_encode_path,$(shell bash "$(MAKEFW_NORMALIZE_PATHS)" --relative "$(call _makefw_decode_path,$(1))")),$(call _makefw_path_relative_in_workspace,$(call _makefw_path_encoded_abspath,$(subst \,/,$(1))))),$(2))
# $(1): 単一のパス (空白は保護の有無を問わない)、$(2): エラー表示用の変数名 (省略可)
_makefw_normalize_path = $(call _makefw_decode_path,$(call _makefw_normalize_encoded_path,$(call _makefw_encode_path,$(call _makefw_unescape_path,$(strip $(1)))),$(2)))
