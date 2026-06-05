# Windows における UTF-8 対応: マニフェストとコンソール設定

## はじめに

Windows の C プログラムで UTF-8 文字列を安定して扱うには、次の 2 つを区別して考える必要があります。

- プロセスの ANSI コード ページ (ACP)
- 接続先コンソールの入力コード ページ / 出力コード ページ

Windows 10 1903 以降では、アプリケーション マニフェストの `activeCodePage=UTF-8` により、プロセスのコード ページを UTF-8 にできます。これは `argv`、CRT の narrow API、Win32 の `-A` API を UTF-8 前提で扱うための基本設定です。

一方、コンソールにはプロセス ACP とは別に入力コード ページと出力コード ページがあります。Microsoft の Console Code Pages 文書では、UTF-8 を A 系コンソール API で扱う場合、`SetConsoleCP` と `SetConsoleOutputCP` でコンソール側のコード ページを `65001` (`CP_UTF8`) に設定する、と説明されています。

このため、本リポジトリでは次の方針を採用します。

- Windows 10 1903 以降をサポート対象とし、`activeCodePage=UTF-8` マニフェストを必ず埋め込む
- `argv`、CRT narrow API、Win32 `-A` API は UTF-8 前提で扱う
- コンソール入出力については、`com_util_console_init()` で `SetConsoleCP(CP_UTF8)` / `SetConsoleOutputCP(CP_UTF8)` と VT 処理の有効化を行う

## プロセス ACP と activeCodePage

Windows 10 1903 以降では、アプリケーション マニフェストに `activeCodePage=UTF-8` を指定することで、プロセスのコード ページを UTF-8 にできます。

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

`activeCodePage=UTF-8` の主な効果は次のとおりです。

| 対象 | 効果 |
|:-----|:-----|
| `GetACP()` | `65001` (`CP_UTF8`) を返す |
| `main(int argc, char *argv[])` | UTF-8 として扱える |
| CRT narrow API | ACP を参照する API では UTF-8 前提で扱える |
| Win32 `-A` API | ANSI コード ページが UTF-8 の場合、通常 UTF-8 として動作する |

Microsoft Learn は、Windows 10 1903 以降で `activeCodePage` によりプロセスのコード ページを UTF-8 にできること、また ANSI コード ページが UTF-8 の場合は `-A` API が通常 UTF-8 として動作することを説明しています。

ただし、Windows は内部的に UTF-16 (`WCHAR`) を使います。Windows API 境界でより明示的に扱いたい場合や、`WCHAR` のみを受け付ける API を使う場合は、`MultiByteToWideChar(CP_UTF8, ...)` / `WideCharToMultiByte(CP_UTF8, ...)` で変換し、`-W` API を使います。

## コンソール コード ページ

コンソールには、入力コード ページと出力コード ページがあります。これはプロセス ACP とは別の状態です。

| 対象 | 役割 |
|:-----|:-----|
| 入力コード ページ | キーボード入力を文字値へ変換する |
| 出力コード ページ | A 系コンソール出力の文字値を表示文字へ変換する |

Microsoft Learn の Console Code Pages 文書では、UTF-8 文字列を A 系コンソール API へ送る場合、事前に `SetConsoleCP` と `SetConsoleOutputCP` でコード ページを `65001` (`CP_UTF8`) に設定する、と説明されています。

`activeCodePage=UTF-8` はプロセス ACP を UTF-8 にする設定です。公式文書では、これにより接続先コンソールの入力コード ページ / 出力コード ページも必ず UTF-8 になる、とは説明されていません。そのため、本リポジトリでは Windows 10 1903 以降に限定した場合でも、コンソール側のコード ページ設定を `com_util_console_init()` に残します。

## com_util_console_init の役割

`com_util_console_init()` は Windows で次の処理を行います。

- stdout がコンソールである場合に限り、初期化処理を行う
- コンソール入力コード ページが UTF-8 でなければ `SetConsoleCP(CP_UTF8)` を呼ぶ
- コンソール出力コード ページが UTF-8 でなければ `SetConsoleOutputCP(CP_UTF8)` を呼ぶ
- stdout / stderr の `ENABLE_VIRTUAL_TERMINAL_PROCESSING` を有効化する
- 通常終了時に、変更前のコンソール コード ページとコンソール モードを復元する

Linux では `com_util_console_init()` / `com_util_console_dispose()` は no-op です。

この関数は、UTF-8 マニフェストを置き換えるものではありません。UTF-8 マニフェストはプロセス ACP を UTF-8 にするために必要であり、`com_util_console_init()` は接続先コンソールの状態をアプリケーションの前提に合わせるための補助処理です。

## makefw での使い方

makefw は `WIN32_MANIFEST` 変数を使ったマニフェスト埋め込み機能を提供します。MSVC の `link.exe` に `/MANIFEST:EMBED /MANIFESTINPUT:` オプションを渡してリンク時に直接 EXE へ埋め込みます。

`makepart.mk` に以下を追加します。

```{.makefile caption="makepart.mk への追加例"}
# Windows EXE に activeCodePage=UTF-8 マニフェストを埋め込む
WIN32_MANIFEST = utf8
```

`utf8` キーワードを指定すると、makefw 付属の `makefiles/utf8_manifest.manifest` が自動的に使用されます。独自のマニフェスト ファイルを使う場合はパスを直接指定します。

```{.makefile caption="カスタムマニフェストを指定する場合"}
WIN32_MANIFEST = path/to/custom.manifest
```

`makepart.mk` を配置するディレクトリ以下のすべての EXE に継承されます。Linux 環境では、Windows 専用のリンク オプションは追加されません。

Windows ビルド時に `_flags.mk` が LDFLAGS を以下のように拡張します。

```text
link.exe /NOLOGO /SUBSYSTEM:CONSOLE /MANIFEST:EMBED /MANIFESTINPUT:C:\...\utf8_manifest.manifest ...
```

`/MANIFEST:EMBED` を使うと、`link.exe` は自動生成する互換性マニフェストと `/MANIFESTINPUT:` のファイルをマージして EXE に埋め込みます。

## 埋め込み確認方法

ビルド後に以下のコマンドでマニフェストが正しく埋め込まれているか確認できます。

```{.bat caption="mt.exe でマニフェストを抽出して確認"}
mt.exe -inputresource:send.exe;#1
```

または:

```{.bat caption="dumpbin でマニフェストリソースを確認"}
dumpbin /MANIFESTRESOURCE send.exe
```

出力に `activeCodePage` と `UTF-8` が含まれていれば成功です。

## まとめ

| 対処 | 役割 |
|:-----|:-----|
| `activeCodePage=UTF-8` マニフェスト | プロセス ACP を UTF-8 にし、`argv`、CRT narrow API、Win32 `-A` API を UTF-8 前提で扱えるようにする |
| `SetConsoleCP(CP_UTF8)` | 接続先コンソールの入力コード ページを UTF-8 にする |
| `SetConsoleOutputCP(CP_UTF8)` | 接続先コンソールの出力コード ページを UTF-8 にする |
| `ENABLE_VIRTUAL_TERMINAL_PROCESSING` | ANSI エスケープ シーケンスによる色やカーソル制御を有効化する |

推奨構成は、`WIN32_MANIFEST = utf8` で UTF-8 マニフェストを埋め込み、コンソール アプリケーションの開始時に `com_util_console_init()` を呼び出すことです。

## 参考リンク

- Microsoft Learn: Use UTF-8 code pages in Windows apps  
  https://learn.microsoft.com/en-us/windows/apps/design/globalizing/use-utf8-code-page  
  確認日: 2026-06-01。Windows 10 1903 以降の `activeCodePage=UTF-8`、`-A` / `-W` API、UTF-8 と UTF-16 の変換について確認。
- Microsoft Learn: Console Code Pages  
  https://learn.microsoft.com/en-us/windows/console/console-code-pages  
  確認日: 2026-06-01。コンソールの入力コード ページ / 出力コード ページと、`SetConsoleCP` / `SetConsoleOutputCP` による `CP_UTF8` 設定について確認。
- Microsoft Learn: SetConsoleOutputCP function  
  https://learn.microsoft.com/en-us/windows/console/setconsoleoutputcp  
  確認日: 2026-06-01。呼び出しプロセスに関連付けられたコンソールの出力コード ページを設定する API であることを確認。
- Microsoft Learn: Application manifests  
  https://learn.microsoft.com/en-us/windows/win32/sbscs/application-manifests  
  確認日: 2026-06-01。アプリケーション マニフェストの `activeCodePage` 要素と、マニフェスト埋め込みの前提を確認。
