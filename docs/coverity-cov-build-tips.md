# Coverity cov-build 運用ノウハウ

## 複数回の cov-build 結果をマージする

### 基本的な仕組み

`cov-build` は `--dir` で指定した中間ディレクトリ (idir) に emit ユニットを蓄積する。  
同じ idir を指定して複数回呼び出せば、結果は自動的に積み上がる。

```bash
# 1回目: モジュール A をキャプチャ
cov-build --dir ./idir make module_a

# 2回目: モジュール B を同じ idir に追加
cov-build --dir ./idir make module_b

# 解析はまとめて実行
cov-analyze --dir ./idir
```

### ログ上書きを防ぐ

デフォルトでは `idir/build-log.txt` が毎回上書きされる。  
`--append-log` を付けると上書きを防げる。

```bash
cov-build --append-log --dir ./idir make module_a
cov-build --append-log --dir ./idir make module_b
```

### make clean の扱い

`clean` を `cov-build` 経由で実行すると蓄積済みの emit ユニットが消えることがある。  
`clean` は素の `make` で行い、ビルド部分だけを `cov-build` でキャプチャする。

```bash
make module_a_clean            # coverity を通さず clean
cov-build --dir ./idir make module_a
```

### 別 idir をマージする

異なるマシンやジョブで生成した idir は `cov-manage-emit` でまとめられる。

```bash
# idir_b の emit ユニットを idir_a にコピー
cov-manage-emit --dir ./idir_a import --dir ./idir_b

cov-analyze --dir ./idir_a
```

前提: 同一バージョンの Coverity ツール、同一ソース ツリー上のビルドであること。

### まとめ

| 手法 | 概要 |
|------|------|
| 同一 idir に複数回 cov-build | 最もシンプル。同じ `--dir` を指定して順次実行する |
| `--append-log` オプション | ログが上書きされるのを防ぐ |
| `cov-manage-emit import` | 別々の idir を後からマージする |

---

## 多段 make で特定のサブメイクだけ cov-build 経由にする

### アプローチ 1: MAKE 変数を上書きする (最もシンプル)

GNU make の `$(MAKE)` 変数をトップ レベルで差し替えることで、  
対象サブディレクトリだけを選択的にキャプチャできる。

```makefile
# Makefile (トップレベル)
ifeq ($(COVERITY),1)
    SUBMAKE_A     = cov-build --dir $(COV_IDIR) $(MAKE)
    SUBMAKE_PLAIN = $(MAKE)
else
    SUBMAKE_A     = $(MAKE)
    SUBMAKE_PLAIN = $(MAKE)
endif

all:
	$(SUBMAKE_A)     -C module_a    # cov-build 経由でキャプチャ対象
	$(SUBMAKE_PLAIN) -C thirdparty  # 解析不要なので素の make
```

```bash
# 実行例
cov-build --dir ./idir make COVERITY=1 COV_IDIR=$(pwd)/idir
```

GNU make ではコマンド ラインで指定したマクロがすべてのサブメイクに伝播し、  
サブ Makefile 内の値を上書きする性質があるため、この方法が成立する。

### アプローチ 2: ラッパー スクリプトを使う

ディレクトリ名や環境変数に応じて `cov-build` を通すかどうかを動的に切り替える。

```bash
#!/bin/bash
# cov-make-wrapper.sh
COV_IDIR=${COV_IDIR:-$(pwd)/idir}

case "$PWD" in
    */module_a*)
        exec cov-build --dir "$COV_IDIR" make "$@"
        ;;
    *)
        exec make "$@"
        ;;
esac
```

```makefile
# Makefile
MAKE = $(COV_MAKE_WRAPPER)
```

```bash
# 実行例
COV_MAKE_WRAPPER=./cov-make-wrapper.sh \
COV_IDIR=$(pwd)/idir \
make all
```

### アプローチ 3: サブ Makefile の CC を差し替える

サブ Makefile を直接編集できる場合、コンパイラ呼び出し単位で差し替える方法もある。

```makefile
# module_a/Makefile
CC_ORIG = gcc
ifdef COV_IDIR
    CC = cov-build --dir $(COV_IDIR) $(CC_ORIG)
else
    CC = $(CC_ORIG)
endif
```

ただしリンク ステップとの兼ね合いに注意が必要。

### 注意点まとめ

| ポイント | 内容 |
|----------|------|
| idir の指定 | 複数サブメイクでも `--dir` を同じパスにすれば emit が蓄積される |
| `make clean` の扱い | clean は cov-build を通さず素の make で実行する |
| 同一ファイルの重複ビルド | 同じソースを複数回コンパイルしても最後の結果だけが残る |
| `--append-log` | ログ上書きを防ぎたい場合に付ける |

実際の運用では「アプローチ 1 (MAKE 変数の差し替え) + 同一 idir への蓄積」が  
最もシンプルで、Makefile への変更も最小限で済む。
