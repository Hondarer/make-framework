# Windows における UTF-8 対応: マニフェストとコンソール出力

## はじめに

Windows の C プログラムで日本語などの非 ASCII 文字を正しく扱うには、プロセスの文字エンコーディングとコンソールの解釈コードページを UTF-8 に揃える必要があります。本ドキュメントでは、Windows 10 1903 以降で利用可能なアプリケーションマニフェストによる `activeCodePage=UTF-8` の設定と、従来から使われてきた `SetConsoleOutputCP(CP_UTF8)` の役割・関係を説明します。また、makefw の `WIN32_MANIFEST` 機能による組み込み方法も示します。

## 問題の背景

Windows は起動時のシステムロケールに応じてプロセスの ANSI コードページ (ACP) を決定します。日本語環境では通常 CP932 (Shift-JIS) が使用されます。この ACP は以下に影響します。

- **`argv`**: `main(int argc, char *argv[])` の引数は ACP でエンコードされた文字列として渡される
- **標準入出力 (`printf` など)**: ACP でエンコードされたバイト列をコンソールに送出する
- **ファイル I/O (ANSI 版関数)**: `fopen` などに渡すパス文字列は ACP として解釈される

UTF-8 ソースファイルをビルドして UTF-8 の文字列リテラルを `printf` しても、コンソールが CP932 で解釈すれば文字化けが発生します。また、`argv` 経由でファイルパスに日本語が含まれる場合も同様の問題が起きます。

## 2 つの対処方法

### 方法 A: `SetConsoleOutputCP(CP_UTF8)` (従来の方法)

```{.c caption="main 直後でコンソール出力 CP を変更する例"}
#include <stdio.h>
#ifdef _WIN32
#include <windows.h>
#endif

int main(int argc, char *argv[]) {
#ifdef _WIN32
    SetConsoleOutputCP(CP_UTF8);
#endif
    printf("こんにちは\n");
    return 0;
}
```

**`SetConsoleOutputCP(CP_UTF8)` の効果**

| 対象 | 変化 |
|:-----|:-----|
| コンソール出力 CP | CP932 → 65001 (UTF-8) |
| `printf` などの出力の解釈 | コンソールが UTF-8 として表示する |
| `argv` | **変化しない** (ACP のまま) |
| `fopen` などのパス解釈 | **変化しない** (ACP のまま) |

コンソール表示は改善されますが、`argv` に日本語が含まれる場合は依然として CP932 で届くため、UTF-8 として処理すると文字化けが発生します。

### 方法 B: アプリケーションマニフェスト `activeCodePage=UTF-8` (推奨)

Windows 10 1903 以降、アプリケーションマニフェストに `activeCodePage=UTF-8` を指定することでプロセス全体の ACP を UTF-8 に設定できます。

```{.xml caption="utf8_manifest.manifest"}
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <activeCodePage xmlns="http://schemas.microsoft.com/SMI/2019/WindowsSettings">UTF-8</activeCodePage>
    </windowsSettings>
  </application>
</assembly>
```

**`activeCodePage=UTF-8` の効果**

| 対象 | 変化 |
|:-----|:-----|
| `GetACP()` の戻り値 | 65001 (CP_UTF8) |
| `argv` | UTF-8 文字列として届く |
| `fopen` などのパス解釈 | UTF-8 として解釈される |
| コンソール出力 CP | 65001 (UTF-8) に自動設定 ※ `SetConsoleOutputCP(CP_UTF8)` 相当 |
| コンソール入力 CP | 65001 (UTF-8) に自動設定 ※ `SetConsoleCP(CP_UTF8)` 相当 |

プロセス全体が UTF-8 モードで動作するため、`argv` のエンコーディング問題も解消されます。

## 2 つの方法の比較

| 項目 | `SetConsoleOutputCP` | マニフェスト `activeCodePage` |
|:-----|:---------------------|:------------------------------|
| `argv` の UTF-8 化 | 不可 | 可 |
| `printf` のコンソール表示 | 可 | 可 |
| `fopen` 等のパス UTF-8 化 | 不可 | 可 |
| 対応 Windows バージョン | Windows 全般 | Windows 10 1903 以降 |
| 実装箇所 | ソースコード (`main` 冒頭) | ビルド設定 (マニフェスト埋め込み) |

## `SetConsoleOutputCP` はマニフェスト設定後も必要か

**技術的には不要になります**。`activeCodePage=UTF-8` はコンソール出力 CP も自動で 65001 に設定するため、`SetConsoleOutputCP(CP_UTF8)` は重複した処理になります。

ただし、Windows 10 1903 未満の環境をサポートするのであれば残しておくのが無難です。

- マニフェストが効いている環境 (Win10 1903+): 同じ値を再設定するだけなので副作用なし
- マニフェストが無視される環境 (Win10 1903 未満): `SetConsoleOutputCP` がコンソール表示の安全網になる

```{.c caption="推奨パターン: 両方を併用してより広い互換性を確保"}
#ifdef _WIN32
    /* activeCodePage=UTF-8 マニフェストがある場合は冗長だが無害 */
    /* Win10 1903 未満ではマニフェストが無視されるため、これがコンソール表示の安全網になる */
    SetConsoleOutputCP(CP_UTF8);
#endif
```

## makefw での使い方

makefw は `WIN32_MANIFEST` 変数を使ったマニフェスト埋め込み機能を提供します。MSVC の `link.exe` に `/MANIFEST:EMBED /MANIFESTINPUT:` オプションを渡してリンク時に直接 EXE へ埋め込みます。追加ツール (`mt.exe` など) は不要です。

### 組み込み方法

`makepart.mk` に以下を追加します。

```{.makefile caption="makepart.mk への追加例"}
# Windows EXE に activeCodePage=UTF-8 マニフェストを埋め込む
WIN32_MANIFEST = utf8
```

`utf8` キーワードを指定すると、makefw 付属の `makefiles/utf8_manifest.manifest` が自動的に使用されます。独自のマニフェストファイルを使う場合はパスを直接指定します。

```{.makefile caption="カスタムマニフェストを指定する場合"}
WIN32_MANIFEST = path/to/custom.manifest
```

### 効果の範囲

`makepart.mk` を配置するディレクトリ以下のすべての EXE に継承されます。例えば `app/porter/prod/src/makepart.mk` に設定すれば `send`、`recv`、`tcpServer` のすべてが対象になります。

Linux 環境ではビルドシステムが `ifeq ($(OS),Windows_NT)` で保護しているため、`WIN32_MANIFEST` の設定は無視されます。

### リンクコマンドへの反映

Windows ビルド時に `_flags.mk` が LDFLAGS を以下のように拡張します。

```text
link.exe /NOLOGO /SUBSYSTEM:CONSOLE /MANIFEST:EMBED /MANIFESTINPUT:C:\...\utf8_manifest.manifest ...
```

`/MANIFEST:EMBED` を使うと `link.exe` は自動生成する互換性マニフェスト (CRT バージョン情報など) と `/MANIFESTINPUT:` ファイルをマージして EXE に埋め込みます。既存の互換性情報は維持されます。

### 埋め込み確認方法

ビルド後に以下のコマンドでマニフェストが正しく埋め込まれているか確認できます。

```{.bat caption="mt.exe でマニフェストを抽出して確認"}
mt.exe -inputresource:send.exe;#1
```

または

```{.bat caption="dumpbin でマニフェストリソースを確認"}
dumpbin /MANIFESTRESOURCE send.exe
```

出力に `activeCodePage` と `UTF-8` が含まれていれば成功です。

## まとめ

| 対処 | 解決できる問題 | 対応環境 |
|:-----|:--------------|:---------|
| `SetConsoleOutputCP(CP_UTF8)` | コンソール出力の文字化け | Windows 全般 |
| マニフェスト `activeCodePage=UTF-8` | `argv`・`fopen` パス・コンソール出力すべて | Win10 1903 以降 |
| 両方を併用 | Win10 1903 未満でも最低限コンソール出力を保護しつつ、1903 以降では完全対応 | 全環境 |

**推奨**: `makepart.mk` に `WIN32_MANIFEST = utf8` を設定してマニフェストを埋め込み、ソースコードにも `SetConsoleOutputCP(CP_UTF8)` を残す。これにより `argv` の UTF-8 化 (Win10 1903+) と広い互換性の両立が図れます。

## 参考リンク

- Microsoft Docs: UTF-8 コード ページの使用
  [https://learn.microsoft.com/ja-jp/windows/apps/design/globalizing/use-utf8-code-page](https://learn.microsoft.com/ja-jp/windows/apps/design/globalizing/use-utf8-code-page)

- Microsoft Docs: アプリケーション マニフェストの windowsSettings 要素
  [https://learn.microsoft.com/ja-jp/windows/win32/sbscs/application-manifests](https://learn.microsoft.com/ja-jp/windows/win32/sbscs/application-manifests)

- Microsoft Docs: SetConsoleOutputCP 関数
  [https://learn.microsoft.com/ja-jp/windows/console/setconsoleoutputcp](https://learn.microsoft.com/ja-jp/windows/console/setconsoleoutputcp)

- Microsoft Docs: /MANIFEST (side-by-side アセンブリ マニフェストの作成)
  [https://learn.microsoft.com/ja-jp/cpp/build/reference/manifest-create-side-by-side-assembly-manifest](https://learn.microsoft.com/ja-jp/cpp/build/reference/manifest-create-side-by-side-assembly-manifest)
