# ビルド構成の指定方法

## 概要

makefw の C/C++ ビルドでは、`CONFIG` 変数でビルド構成を指定します。  
未指定の場合は `RelWithDebInfo` が使用されます。

```bash
# 既定構成 (RelWithDebInfo)
make

# デバッグ構成
make CONFIG=Debug

# リリース構成
make CONFIG=Release

# 最適化あり + デバッグ情報あり
make CONFIG=RelWithDebInfo
```

`CONFIG` は再帰 make に引き継がれるため、app 直下や prod/test 直下で指定すれば、その配下のビルドに同じ構成が適用されます。

```bash
make -C app/calc/prod CONFIG=Release
make -C app/calc/test CONFIG=Debug test
```

## 構成ごとの用途

| 構成 | 用途 | Linux の主なフラグ | MSVC の主なフラグ |
|---|---|---|---|
| `Debug` | ステップ実行とデバッグを優先 | `-O0 -g -D_DEBUG` | `/Od /RTC1 /Zi /D_DEBUG` |
| `RelWithDebInfo` | 性能と調査しやすさのバランス | `-O2 -g -fno-omit-frame-pointer -DNDEBUG` | `/O2 /Ob2 /Zi /DNDEBUG` |
| `Release` | 配布・性能測定向け | `-O2 -g -flto -DNDEBUG` | `/O2 /Ob2 /Oy /Zi /GL /DNDEBUG` |

`RelWithDebInfo` は、通常開発・テスト・性能調査の既定構成です。  
最適化を有効にしつつデバッグ情報を生成し、Linux ではフレーム ポインターを保持してスタック トレースやプロファイリングを安定させます。

`Release` は、LTO (Link Time Optimization) を有効にするため、ビルド時間やリンク時間が増える場合があります。  
Linux では `-flto` を使うため、既定の `ar` が使われている場合は `gcc-ar` に切り替えます。  
MSVC では `/GL` と `/LTCG` を組み合わせます。

## テスト ビルドでの扱い

`LINK_TEST=1` のテスト対象では、ステップ実行とカバレッジ計測を優先します。  
そのため、通常の `CONFIG` が `RelWithDebInfo` や `Release` であっても、テスト対象ソースには最適化抑制とカバレッジ用の設定が適用されます。

- Linux: `-O0 -g -coverage` を使用し、`-flto` はリンク オプションから除外する
- MSVC: `/Od /Ob0 /Zi` を使用し、`/LTCG` はリンク オプションから除外する

本番性能の確認には、`test` 配下ではなく `prod` 配下を `CONFIG=Release` でビルドした成果物を使用します。

## Windows のランタイム指定

Windows/MSVC では、`MSVC_CRT` で C ランタイムのリンク方式を指定できます。  
未指定の場合は `shared` です。

```bash
# 動的 CRT: /MD または /MDd
make CONFIG=RelWithDebInfo MSVC_CRT=shared

# 静的 CRT: /MT または /MTd
make CONFIG=RelWithDebInfo MSVC_CRT=static
```

`CONFIG=Debug` では `shared` が `/MDd`、`static` が `/MTd` になります。  
`CONFIG=Release` と `CONFIG=RelWithDebInfo` では `shared` が `/MD`、`static` が `/MT` になります。

ランタイム リンク モデルの詳細は `msvc-runtime-linkage.md` を参照してください。

## 並列ビルド

Windows ビルドには Visual Studio 2022 以降が必要です。  
MSVC のコンパイルでは複数のソース ファイルを `cl.exe` に渡し、`/MP` で並列処理します。  
ヘッダー依存関係は `/sourceDependencies` で取得します。

makefw は Linux と Windows のどちらでも、利用可能な論理 CPU 数を CPU 予算として並列度を算出します。
Linux では `nproc`、Windows では `NUMBER_OF_PROCESSORS` から CPU 予算を取得し、取得できない場合は 6 を使います。
`MAKEFW_CPU_BUDGET` に正の整数を指定すると、自動検出した CPU 予算を上書きできます。

Linux の make には CPU 予算と 16 の小さい方を割り当てます。
Windows の make には CPU 予算の平方根を切り上げた値を割り当て、上限を 8 とします。
MSVC の `/MP` と MSBuild の `-m` には、CPU 予算を make の並列度で割った値を割り当て、1 から 16 の範囲に制限します。
この配分により、GNU Make とコンパイラによる二重の並列化が CPU 予算を超えないようにします。

論理 CPU が 72 個ある場合の自動設定は次のとおりです。

| OS | make | GCC | MSVC | MSBuild |
|---|---:|---:|---:|---:|
| Linux | `-j16` | make の並列度を使用 | - | `-m:4` |
| Windows | `-j8` | - | `/MP9` | `-m:9` |

引数なし、`default`、`build`、`clean`、`rebuild`、`test` では自動設定を使用します。
`make test` は内部で 2 フェーズに分かれます。Phase 1 (ビルド フェーズ) はテスト バイナリのコンパイルとリンクのみを自動設定の並列度で実行し、Phase 2 (実行フェーズ) はテストの実行順を維持するため `-j1` で実行します。
これにより、出力順序を保ったまま、支配的なコンパイルとリンクの所要を並列化します。

コマンド ラインで指定した値は自動算出より優先されます。

```bash
# make の並列度を指定する
make JOBS=4

# make と MSVC の並列度を個別に指定する
make JOBS=4 MAKEFW_CL_MP_JOBS=8

# CPU 予算を指定する
make MAKEFW_CPU_BUDGET=12

# make と MSBuild の並列度を個別に指定する
make JOBS=4 MAKEFW_MSBUILD_JOBS=3

# GNU Make の -j も利用できる
make -j4
```

GNU Make の `-j` をジョブ数なしで指定した場合、make の並列度に上限がないため、MSVC と MSBuild の並列度は 1 とします。
`MAKEFW_CL_MP_JOBS` または `MAKEFW_MSBUILD_JOBS` を明示した場合は、その値を優先します。

## 運用上の注意

- 構成を切り替える場合、既存の `obj` や成果物が残っていると古い構成のオブジェクトと混在する場合があります。
- 特に `Release` の LTO を確認する場合は、対象モジュールで一度 `make CONFIG=Release clean` を実行してからビルドします。
- 全体 `make clean` は高コストなため、通常は変更対象の app や prod/test 直下に限定します。
- 既定構成を一時的に変えたい場合は、コマンド ラインで `CONFIG=...` を指定します。恒久的な変更が必要な場合のみ、上位の `makepart.mk` などで定義します。
