# makefw のパス制約

## 概要

makefw を使用するプロジェクトは、**プロジェクトの配置パスを ASCII 文字のみで構成**する必要があります。スペースやマルチバイト文字 (日本語など) を含むパスに配置すると、make ビルドが失敗します。

## make 共通の制約: スペースを含むパス

GNU Make はスペースを単語区切りとして扱います。パスにスペースが含まれると、`include` ディレクティブや変数展開、依存関係の解析でパスが分割され、正常に動作しません。

```text
# NG: スペースが含まれるパス
C:/Users/tetsuo/Desktop/my project/c-modernization-kit/

# OK: スペースを含まないパス
C:/Users/tetsuo/repos/c-modernization-kit/
```

この制約は GNU Make の根本的な設計上の制限であり、Linux/Windows のいずれでも同様に発生します。

## Windows 固有の制約: マルチバイト文字を含むパス

Windows では、スペースに加えてマルチバイト文字 (日本語など) を含むパスも使用できません。

```text
# NG: 日本語を含むパス
C:/Users/tetsuo/Desktop/新しいフォルダー/c-modernization-kit/

# OK: ASCII のみのパス
C:/Users/tetsuo/repos/c-modernization-kit/
```

### 技術的な原因

`prepare.mk` では `$(shell)` を使用してパスを取得しています。

- `$(shell)` が呼び出す bash(Git for Windows) は UTF-8 でパスを返す
- GNU Make(Windows ネイティブ版) は `$(shell)` の出力をシステムコードページ (CP932) として解釈する
- UTF-8 の日本語バイト列が CP932 として誤解釈され、文字化け (mojibake) が生じる
- 文字化けの結果にスペースが混入することがあり、`include` がパスを誤って分割する

### 実際のエラー例

日本語フォルダー名 `新しいフォルダー` が以下のように化けて、ファイルが見つからないエラーになります。

```text
prepare.mk:292: C:/Users/tetsuo/Desktop/譁ｰ縺励＞ 繝輔か繝ｫ繝繝ｼ/c-modernization-kit/makepart.mk: No such file or directory
make: *** No rule to make target '...'.  Stop.
```

`譁ｰ縺励＞ 繝輔か繝ｫ繝繝ｼ` は `新しいフォルダー` の UTF-8 バイト列を CP932 として読んだ結果です。

## 推奨する配置パスの例

```text
C:/repos/<project-name>/
C:/dev/<project-name>/
C:/Users/<username>/repos/<project-name>/
```
