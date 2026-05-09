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

## 運用上の注意

- 構成を切り替える場合、既存の `obj` や成果物が残っていると古い構成のオブジェクトと混在する場合があります。
- 特に `Release` の LTO を確認する場合は、対象モジュールで一度 `make CONFIG=Release clean` を実行してからビルドします。
- 全体 `make clean` は高コストなため、通常は変更対象の app や prod/test 直下に限定します。
- 既定構成を一時的に変えたい場合は、コマンド ラインで `CONFIG=...` を指定します。恒久的な変更が必要な場合のみ、上位の `makepart.mk` などで定義します。
