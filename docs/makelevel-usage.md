# MAKELEVEL 変数による再帰 make の階層判定

再帰的に make を呼び出す構成では、「トップレベルの make が完了したとき」や「各階層の make が完了したとき」に特定の処理を実行したい場面があります。GNU Make の `MAKELEVEL` 変数を使うと、現在の再帰呼び出しの深さを判定できます。

## MAKELEVEL 変数とは

`MAKELEVEL` は GNU Make が自動的に設定する変数で、再帰呼び出しの深さを示します。

- トップレベル (起点) の make では `0`
- 1 段目の再帰呼び出しでは `1`
- 2 段目の再帰呼び出しでは `2`
- 以降、呼び出しが深くなるたびに 1 ずつ増加

## トップレベルでのみ処理を実行する

起点の make が完了したときにだけ実行したい処理は、`MAKELEVEL` が `0` かどうかで判定します。

```{.makefile caption="トップレベルでのみ実行"}
.PHONY: all
all: subdirs local-build
ifeq ($(MAKELEVEL),0)
    @echo "===== トップレベルの make が完了しました ====="
    @echo "すべてのビルドが正常に終了"
endif

.PHONY: subdirs
subdirs:
    $(MAKE) -C subdir1
    $(MAKE) -C subdir2

.PHONY: local-build
local-build:
    @echo "ローカルビルド処理"
```

この例では、サブディレクトリの make が完了し、ローカルビルドも終わった後で、トップレベルの場合のみ完了メッセージを表示します。

## 各階層で処理を実行する

各階層の make が終わったときに、その階層の情報を含めて処理を実行する例です。

```{.makefile caption="各階層で終了時処理を実行"}
.PHONY: all
all: subdirs local-build
    @echo "[MAKELEVEL=$(MAKELEVEL)] この階層の処理が完了: $(CURDIR)"

.PHONY: subdirs
subdirs:
    @for dir in $(SUBDIRS); do \
        $(MAKE) -C $$dir || exit 1; \
    done

.PHONY: local-build
local-build:
    @echo "[MAKELEVEL=$(MAKELEVEL)] ローカルビルド実行中"
```

## 実用例: ビルド完了時のサマリ表示

トップレベルでのみビルド結果のサマリを表示する実用的な例です。

```{.makefile caption="ビルド完了サマリの表示"}
.PHONY: all
all: build
ifeq ($(MAKELEVEL),0)
    @echo ""
    @echo "========================================="
    @echo " ビルド完了"
    @echo " 出力ディレクトリ: $(OUTPUT_DIR)"
    @echo " 生成ファイル数: $$(find $(OUTPUT_DIR) -type f | wc -l)"
    @echo "========================================="
endif

.PHONY: build
build: $(TARGETS)
```

## 実用例: テスト実行後のレポート生成

すべてのテストが完了した後でのみレポートを生成する例です。

```{.makefile caption="テスト完了後のレポート生成"}
.PHONY: test
test: run-tests
ifeq ($(MAKELEVEL),0)
    @echo "テストレポートを生成中..."
    $(MAKE) -C report generate
    @echo "レポート生成完了: $(REPORT_DIR)/index.html"
endif

.PHONY: run-tests
run-tests:
    $(MAKE) -C test/unit
    $(MAKE) -C test/integration
```

## 注意点

- `MAKELEVEL` は文字列として比較されるため、`ifeq ($(MAKELEVEL),0)` のように記述します
- `$(MAKE)` を使わずに直接 `make` を呼び出すと、`MAKELEVEL` が正しく設定されません
- 並列ビルド (`-j` オプション) でも `MAKELEVEL` は正しく動作します

## 関連リンク

- GNU make manual - Variables/Recursion
  [https://www.gnu.org/software/make/manual/html_node/Variables_002fRecursion.html](https://www.gnu.org/software/make/manual/html_node/Variables_002fRecursion.html)
- GNU make manual - Recursion
  [https://www.gnu.org/software/make/manual/html_node/Recursion.html](https://www.gnu.org/software/make/manual/html_node/Recursion.html)
