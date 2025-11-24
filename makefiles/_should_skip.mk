# スキップ判定用のヘルパー関数
# Helper function for skip detection
#
# 使用法 / Usage:
#   $(call should_skip,$(SKIP_BUILD))
#   $(call should_skip,$(SKIP_TEST))
#
# 戻り値 / Return value:
#   "true" - スキップする / skip
#   ""     - スキップしない / do not skip
#
# 引数の指定方法 / Argument values:
#   1, BOTH, both, Both       -> 常にスキップ / always skip
#   WINDOWS, windows, Windows -> Windows のみスキップ / skip on Windows only
#   LINUX, linux, Linux       -> Linux のみスキップ / skip on Linux only
#   未定義(空) / undefined    -> スキップしない / not skip
#   その他 / other            -> スキップしない / not skip
#
# 例 / Examples:
#   make SKIP_BUILD=1          # 常にビルドをスキップ
#   make SKIP_BUILD=LINUX      # Linux でのみビルドをスキップ
#   make SKIP_TEST=WINDOWS     # Windows でのみテストをスキップ
#   make SKIP_BUILD=BOTH SKIP_TEST=BOTH  # 両方スキップ
#
define should_skip
$(strip \
    $(if $(filter 1 BOTH both Both,$(1)),true,\
        $(if $(filter WINDOWS windows Windows,$(1)),\
            $(if $(filter Windows_NT,$(OS)),true,),\
            $(if $(filter LINUX linux Linux,$(1)),\
                $(if $(filter Windows_NT,$(OS)),,true),))))
endef
