# Makefile の変数代入 "= と :=" の違い

Makefile でよく使う "=" と ":=" は、変数の値をいつ確定させるかが違います。あわせて、追記に使う "+=" の挙動も押さえておくと安全です。

## 基本の考え方

- 値を使うときに展開する方法を先に説明します。これは遅延展開です。遅延展開 (recursively expanded variable) では、"=" を使います。参照時に毎回右辺を評価します。
- 代入した時点で 1 回だけ展開して、結果の文字列を保存する方法があります。これは即時展開です。即時展開 (simply expanded variable) では、":=" を使います。後から参照先が変わっても値は変わりません。
- 既存の値に文字列を足す方法があります。これは追記です。追記 (append) では、"+=" を使います。
- 未定義のときだけ値を入れる方法があります。これは条件付き代入です。条件付き代入 (conditional assignment) では、"?=" を使います。新しく定義するときの種類は遅延展開です。

## 例で理解する

```{.makefile caption="= と := の例"}
B := one

A = $(B)      # 遅延展開 (=)。参照時に $(B) を評価する
C := $(B)     # 即時展開 (:=)。この時点の $(B)="one" を保存する

B := two

all:
    @echo A=$(A)  # two （実行時点で B=two を見る）
    @echo C=$(C)  # one （定義時点の値を保持）
```

この例では、A は実行時点の B を見るので two、C は定義時点の B を固定したので one になります。

## +=（追記）の挙動

"+=" は、変数に文字列を追加します。すでに値がある場合は、先頭に 1 つの空白をはさんでから追加します。未定義の変数に対して最初に使った場合は、"=" と同じく遅延展開の変数として定義します。

ただし、すでに変数が定義されている場合は、もとの変数の種類によって挙動が変わります。

- もとが 即時展開（":="）の場合
  - 追加するテキストを先に展開してから、既存の値に足します
  - 等価変換のイメージは次の通りです

```{.makefile caption=":= に対する += の等価変換"}
X := value
X += more
# 上と同じ意味
X := $(X) more
```

- もとが 遅延展開（"="）の場合
  - 追加するテキストは展開せず、そのまま既存の右辺に連結します（参照時にまとめて展開されます）
  - 等価変換のイメージは次の通りです

```{.makefile caption="= に対する += の等価変換のイメージ"}
X = value
X += more
# 概念的には次に近い（X は遅延展開のまま、more は未展開で足される）
# temp = value
# X = $(temp) more
```

この違いは、右辺に他の変数参照が含まれるときに重要です。次の例では、includes の定義が後から来ても保持したいので、CFLAGS は遅延展開（"="）のままにし、追記には "+=" を使います。

```{.makefile caption="CFLAGS への追記例"}
CFLAGS = $(includes) -O
# ...（あとで includes が定義されるかもしれない）
CFLAGS += -pg  # プロファイリングを有効化
```

もしここで

```{.makefile caption=":= を使ってしまった例"}
CFLAGS := $(CFLAGS) -pg
```

としてしまうと、この時点で $(CFLAGS) が展開され、includes が未定義ならその参照が消えてしまいます。結果として、後から includes を定義しても反映されません。

## ?=（条件付き代入）

まだ一度も設定されていない変数にだけ値を入れる方法です。条件付き代入（conditional assignment）では、"?=" を使います。環境変数やコマンドラインで設定済みのときも「設定済み」と見なして何もしません。新しく定義される場合の種類は遅延展開です。

```{.makefile caption="?= の基本"}
FOO ?= default
# FOO が未定義なら "default" になる。すでに設定済みなら何もしない
```

等価表現は次の通りです。

```{.makefile caption="origin 関数での等価表現"}
ifeq ($(origin FOO), undefined)
FOO = default
endif
```

即時展開のデフォルトが欲しいときは、上の等価表現で ":=" を使います。

## 使い分けの目安

- 常に最新の他変数の値を反映したいときは "=" を使う
- 定数、コマンド列、重い関数や $(shell …) の結果を何度も使うときは ":=" を使う
- 既存の変数に安全に足していきたいときは "+=" を使う。もとの変数の種類（= か :=）で評価タイミングが変わることに注意する

例として、日時などを 1 度だけ決めたい場合は ":=" が向きます。

```{.makefile caption="shell の結果を 1 回だけ確定"}
BUILD_TIME := $(shell date +%Y%m%d-%H%M%S)
```

## よくある落とし穴

- 無自覚に "=" を使うと、$(shell …) や関数展開が参照のたびに走り、ビルドが遅くなることがあります
- 逆に、":=" で値を固定すると、後から上書きした変数の変化が反映されません
- "+=" は、未定義なら遅延展開で定義し、定義済みなら元の種類に従って追加する。  
  特に "=" で定義した変数に "+=" すると、追加部分は未展開のまま後で評価される
- "?=" は未定義かどうかだけを見る。空文字でも一度設定していれば「定義済み」なので値は入らない。即時展開のデフォルトにしたい場合は origin で分岐して ":=" を使う

## 関連リンク

- GNU make manual - The Two Flavors of Variables
  [https://www.gnu.org/software/make/manual/html_node/Flavors.html](https://www.gnu.org/software/make/manual/html_node/Flavors.html)
- GNU make manual - Setting Variables
  [https://www.gnu.org/software/make/manual/html_node/Setting.html](https://www.gnu.org/software/make/manual/html_node/Setting.html)
- GNU make manual - Appending More Text to Variables
  [https://www.gnu.org/software/make/manual/html_node/Appending.html](https://www.gnu.org/software/make/manual/html_node/Appending.html)
- GNU make manual - The origin Function
  [https://www.gnu.org/software/make/manual/html_node/Origin-Function.html](https://www.gnu.org/software/make/manual/html_node/Origin-Function.html)
