# サブディレクトリの検出（Makefileを含むディレクトリのみ）
# Detect subdirectories containing Makefile
SUBDIRS := $(dir $(wildcard */Makefile))

# カレントディレクトリのパス判定による自動テンプレート選択
#
# ディレクトリパターン:
#   /libsrc/ を含む → ライブラリ用テンプレート (makelibsrc_*.mk)
#   /src/    を含む → 実行体用テンプレート (makesrc_*.mk)
#
# 言語判定:
#   .csproj が存在 → .NET 用テンプレート (*_dotnet.mk)
#   .csproj が無い → C/C++ 用テンプレート (*_c_cpp.mk)

# パスに /libsrc/ を含む場合はライブラリ用テンプレート
ifneq (,$(findstring /libsrc/,$(CURDIR)))
    # .csproj があれば .NET ライブラリ、なければ C/C++ ライブラリ
    ifneq ($(wildcard *.csproj),)
        include $(WORKSPACE_FOLDER)/makefw/makefiles/makelibsrc_dotnet.mk
    else
        include $(WORKSPACE_FOLDER)/makefw/makefiles/makelibsrc_c_cpp.mk
    endif
# パスに /src/ を含む場合は実行ファイル用テンプレート
else ifneq (,$(findstring /src/,$(CURDIR)))
    # .csproj があれば .NET 実行体、なければ C/C++ 実行体
    ifneq ($(wildcard *.csproj),)
        include $(WORKSPACE_FOLDER)/makefw/makefiles/makesrc_dotnet.mk
    else
        include $(WORKSPACE_FOLDER)/makefw/makefiles/makesrc_c_cpp.mk
    endif
else
    $(error Cannot auto-select Makefile template. Current path must contain /libsrc/ or /src/: $(CURDIR))
endif

# サブディレクトリの再帰的make処理
# Recursive make for subdirectories
ifneq ($(SUBDIRS),)
    .PHONY: subdirs-default subdirs-build subdirs-clean subdirs-test subdirs-run subdirs-restore subdirs-rebuild

    # デフォルトターゲットをサブディレクトリで実行
    # Execute default target in subdirectories
    subdirs-default:
	@for dir in $(SUBDIRS); do \
		echo "Making default in $$dir"; \
		$(MAKE) -C $$dir || exit 1; \
	done

    # buildターゲットをサブディレクトリで実行
    # Execute build target in subdirectories
    subdirs-build:
	@for dir in $(SUBDIRS); do \
		echo "Making build in $$dir"; \
		$(MAKE) -C $$dir build || exit 1; \
	done

    # cleanターゲットをサブディレクトリで実行
    # Execute clean target in subdirectories
    subdirs-clean:
	@for dir in $(SUBDIRS); do \
		echo "Making clean in $$dir"; \
		$(MAKE) -C $$dir clean || exit 1; \
	done

    # testターゲットをサブディレクトリで実行
    # Execute test target in subdirectories
    subdirs-test:
	@for dir in $(SUBDIRS); do \
		echo "Making test in $$dir"; \
		$(MAKE) -C $$dir test || exit 1; \
	done

    # runターゲットをサブディレクトリで実行
    # Execute run target in subdirectories
    subdirs-run:
	@for dir in $(SUBDIRS); do \
		echo "Making run in $$dir"; \
		$(MAKE) -C $$dir run || exit 1; \
	done

    # restoreターゲットをサブディレクトリで実行
    # Execute restore target in subdirectories
    subdirs-restore:
	@for dir in $(SUBDIRS); do \
		echo "Making restore in $$dir"; \
		$(MAKE) -C $$dir restore || exit 1; \
	done

    # rebuildターゲットをサブディレクトリで実行
    # Execute rebuild target in subdirectories
    subdirs-rebuild:
	@for dir in $(SUBDIRS); do \
		echo "Making rebuild in $$dir"; \
		$(MAKE) -C $$dir rebuild || exit 1; \
	done

    # 既存のターゲットに依存関係を追加（サブディレクトリを先に処理）
    # Add dependencies to existing targets (process subdirectories first)
    default: subdirs-default
    build: subdirs-build
    clean: subdirs-clean
    test: subdirs-test
    run: subdirs-run
    restore: subdirs-restore
    rebuild: subdirs-rebuild
endif
