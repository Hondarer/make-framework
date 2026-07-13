# IDENT — ソース トレーサビリティ

## 概要

IDENT (Ident) は、出荷後のバイナリ単体 (`.so` / `.dll` / `.exe`) から  
「どのコミット時点の、どの `.c` がどのバージョンの `.h` と一緒にコンパイルされたか」を  
機械的に逆引きできるようにする opt-in 機能です。

各 `.c` のコンパイル時にヘッダーの SHA-256 を `.ident` ファイルへ記録し、  
リンク時に統合して manifest を生成、バイナリへ直接埋め込みます。

## 使い方

```bash
# IDENT 有効でビルド (prod/ 配下のみ有効)
make IDENT=1

# 埋め込み文字列を取得 (Linux)
strings prod/lib/libcalc.so | grep '@(#)'

# 埋め込み文字列を取得 (Windows)
$bytes = [IO.File]::ReadAllBytes('prod\lib\libcalc.dll')
$text = [Text.Encoding]::ASCII.GetString($bytes)
[regex]::Matches($text, '@\(#\)IDENT-[^\x00\r\n]*') | ForEach-Object { $_.Value }
```

## 性能影響

一般的な構成では、`IDENT=1` を指定した場合の実行時間の増加は、  
build で 4% 程度、clean から build まで含めた場合で 3% 程度が実測の目安です。  
実際の値は、ソース数、ヘッダー依存数、ストレージ性能、並列度、ツールチェーンにより変動します。

## 確認方法

IDENT は `make IDENT=1` を指定したときだけ、`prod/` 配下の C/C++ ビルドで有効になる。  
`IDENT=0`、空文字、その他の値では有効にならない。  
確認では、以下を順に見る。

1. 各 `.c` に対応する `.ident` JSON が `obj/` 配下に生成されること
2. static lib では、後続リンクへ渡す `.ident_srcs` が `lib/` 配下に生成されること  
   (`LIB_TYPE=both` の static 側も含む)
3. shared lib / exe では、`_ident_manifest.c` と `_ident_manifest.o` / `.obj` が生成されること
4. 最終成果物から `@(#)IDENT-` 行を抽出できること

### Windows での確認例

Windows では、MSVC と GNU Make を利用できるシェルで実行する。  
この repo では `Start-VSCode-With-Env.cmd` から起動したターミナルを想定する。

```powershell
# repo ルートで実行
make -C app/calc/prod/libsrc/calcbase IDENT=1

# static lib のトレース情報
Get-ChildItem app\calc\prod\libsrc\calcbase\obj -Filter *.ident
Get-Content app\calc\prod\lib\calcbase.ident_srcs

# static lib を利用する DLL をビルド
make -C app/calc/prod/libsrc/calc IDENT=1

# DLL に埋め込まれる manifest の生成物
Get-ChildItem app\calc\prod\libsrc\calc\obj -Filter _ident_manifest.*
Get-Content app\calc\prod\libsrc\calc\obj\_ident_manifest.c

# DLL から manifest 文字列を抽出
$bytes = [IO.File]::ReadAllBytes('app\calc\prod\lib\libcalc.dll')
$text = [Text.Encoding]::ASCII.GetString($bytes)
[regex]::Matches($text, '@\(#\)IDENT-[^\x00\r\n]*') | ForEach-Object { $_.Value }
```

出力に、`IDENT-BEGIN`、`IDENT-C`、`IDENT-CH`、`IDENT-END` が含まれていれば、  
ソースとヘッダーのハッシュが最終成果物へ埋め込まれている。

exe で確認する場合は、`prod/src/cmd/` 配下のターゲットを使う。

```powershell
make -C app/calc/prod/src/cmd/calc IDENT=1
$bytes = [IO.File]::ReadAllBytes('app\calc\prod\cbin\calc.exe')
$text = [Text.Encoding]::ASCII.GetString($bytes)
[regex]::Matches($text, '@\(#\)IDENT-[^\x00\r\n]*') | ForEach-Object { $_.Value }
```

`test/` 配下では `IDENT_ENABLED` が設定されないため、同じ指定をしても IDENT の生成物は追加されない。

```powershell
make -C app/calc/test/src/main/calcTest IDENT=1
Get-ChildItem app\calc\test -Recurse -Filter *.ident
```

この確認で `.ident` が表示されないことを確認する。

### Linux での確認例

Linux では GCC を利用するビルド環境で実行する。

```bash
# repo ルートで実行
make -C app/calc/prod/libsrc/calcbase IDENT=1

# static lib のトレース情報
find app/calc/prod/libsrc/calcbase/obj -name '*.ident' -print
cat app/calc/prod/lib/calcbase.ident_srcs

# static lib を利用する shared library をビルド
make -C app/calc/prod/libsrc/calc IDENT=1

# shared library に埋め込まれる manifest の生成物
ls app/calc/prod/libsrc/calc/obj/_ident_manifest.*
sed -n '1,80p' app/calc/prod/libsrc/calc/obj/_ident_manifest.c

# shared library から manifest 文字列を抽出
strings app/calc/prod/lib/libcalc.so | grep -F '@(#)IDENT-'

# GCC では .ident セクションとしても確認できる
readelf -p .ident app/calc/prod/lib/libcalc.so
```

exe で確認する場合は、`prod/src/cmd/` 配下のターゲットを使う。

```bash
make -C app/calc/prod/src/cmd/calc IDENT=1
strings app/calc/prod/cbin/calc | grep -F '@(#)IDENT-'
```

`test/` 配下の自動除外を確認する場合は、次のように実行する。

```bash
make -C app/calc/test/src/main/calcTest IDENT=1
find app/calc/test -name '*.ident' -print
```

この確認で `.ident` が表示されないことを確認する。

## 出力フォーマット

```text
@(#)IDENT-BEGIN target=libcalc.so rev=abc1234 arch=linux_ubuntu_x64
@(#)IDENT-C app/calc/prod/libsrc/calcbase/add.c sha256=ec84e4...
@(#)IDENT-CH  app/calc/prod/include/calc/calc_const.h sha256=667021...
@(#)IDENT-CH  app/calc/prod/include/calcbase/calcbase_spec.h sha256=e7661b...
@(#)IDENT-C app/calc/prod/libsrc/calc/calcHandler.c sha256=def456...
@(#)IDENT-CH  app/calc/prod/include/calc/calc.h sha256=111222...
@(#)IDENT-END
```

| タグ | 意味 |
| --- | --- |
| `IDENT-BEGIN` | manifest の先頭。target: 成果物名、rev: git short hash、arch: アーキテクチャー |
| `IDENT-C` | `.c` ファイルのエントリ。sha256 はコンパイル時点のソース ハッシュ |
| `IDENT-CH` | 直前の `.c` がコンパイル時に参照した `.h`。sha256 はコンパイル時点のヘッダーハッシュ |
| `IDENT-END` | manifest の末尾 |

## 仕組み

### コンパイル時 (各 .c ごと)

1. `.c` のコンパイル完了時に `.d` 依存ファイルが生成される  
   (GCC: `-MMD -MP -MF`、MSVC: `/sourceDependencies`)
2. `.d` ファイルを読んでヘッダーパスを抽出し、SHA-256 を計算
3. ソースと各ヘッダーの SHA-256 を `.ident` JSON ファイルへ保存

```json
{
  "source": "app/calc/prod/libsrc/calcbase/add.c",
  "source_sha256": "ec84e4...",
  "headers": [
    { "path": "app/calc/prod/include/calc/calc_const.h", "sha256": "667021..." }
  ]
}
```

パスはすべて `WORKSPACE_DIR` からの相対パス。  
Make の依存ファイル内で `\` としてエスケープされた空白は、実際の空白として扱う。

### static lib 完成時

`.ident_srcs` ファイルを生成し、どのディレクトリに `.ident` ファイルがあるかを記録する。  
`LIB_TYPE=both` の場合も、static 側の成果物名に対応する `.ident_srcs` を生成する (例: `libcom_util_static.lib` → `com_util_static.ident_srcs`)。

```text
[ident_dir]
/absolute/path/to/libsrc/calcbase
```

### リンク時 (shared lib / exe)

1. ローカルの `.ident` ファイルを収集
2. リンクする static lib から `.ident_srcs` を読み込み、各 ident_dir を再帰検索
3. git short hash を取得
4. すべての情報を `_ident_manifest.c` へ生成
5. `_ident_manifest.o` (.obj) へコンパイルし、リンクに自動混入

## 有効範囲

| パス | IDENT 有効? |
| --- | --- |
| `app/<name>/prod/` | ✅ `IDENT=1` で有効 |
| `app/<name>/test/` | ❌ 自動除外 |

`IDENT_ENABLED` は `prepare.mk` でパスに `/prod/` を含む場合のみセットされる。

## clean

```bash
# IDENT=1 で生成したアーティファクトを削除
make clean IDENT=1
```

`make clean` のみ (IDENT=1 指定なし) では `obj/` 配下の `.ident` ファイルは削除されるが、`lib/` 配下の `.ident_srcs` ファイルは残る。完全削除は `make clean IDENT=1` を使用すること。

## 関連ファイル

| ファイル | 役割 |
| --- | --- |
| `makefiles/_ident.mk` | make 側の ident ルール定義 |
| `bin/gen_ident_manifest.py` | source-info / combine 両モード |
| `makefiles/prepare.mk` | `IDENT_ENABLED` フラグの設定 |
| `makefiles/makelibsrc_c_cpp.mk` | `_ident.mk` の include |
| `makefiles/makesrc_c_cpp.mk` | `_ident.mk` の include |

## 既知の制限

- **LTO (`-flto`, Release ビルド)**: GCC の `__attribute__((used))` が LTO 下で有効かどうかは環境依存。  
  動作確認が必要な場合は `readelf -p .ident <file>` で .ident セクションの有無を確認すること。
- **git hash**: `.git/HEAD` の変更時のみ rev ファイルを再生成する。  
  新しいコミット後にハッシュを最新にするには `make IDENT=1` を再実行すること。
- **IDENT なし → `IDENT=1` 切り替え**: 過去に IDENT なしでビルドした場合、  
  `make clean IDENT=1 && make IDENT=1` でフル リビルドすること。
