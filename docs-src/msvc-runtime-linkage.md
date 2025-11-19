# MSVC ランタイムライブラリのリンクモデル

## はじめに

本ドキュメントは、MSVC (Microsoft Visual C++) におけるランタイムライブラリのリンクモデル (`/MT` と `/MD`) の違いと、プロジェクト全体で適切なモデルを選択する重要性について説明します。

Windows 環境で C/C++ プログラムをビルドする際、ランタイムライブラリ (C ランタイム) のリンク方法を `/MT` (静的リンク) または `/MD` (動的リンク) で指定する必要があります。この選択は、実行ファイル (.exe)、静的ライブラリ (.lib)、動的リンクライブラリ (.dll) のすべてに影響し、誤った組み合わせは実行時のクラッシュやメモリ破壊の原因となります。

## ランタイムライブラリとは

ランタイムライブラリは、プログラムの実行に必要な基本的な機能を提供するライブラリです。C ランタイムライブラリには、以下のような関数が含まれます。

- メモリ管理関数 (`malloc`, `free`, `new`, `delete`)
- 入出力関数 (`printf`, `scanf`, `fopen`, `fclose`)
- 文字列操作関数 (`strcpy`, `strlen`, `strcmp`)
- 数学関数 (`sin`, `cos`, `sqrt`)
- グローバル変数 (`errno`, `stdin`, `stdout`, `stderr`)

すべての C/C++ プログラムは、これらの関数を直接的または間接的に使用するため、ランタイムライブラリが必要です。

## ランタイムリンクモデルの種類

MSVC では、ランタイムライブラリのリンク方法として `/MT` と `/MD` の2種類が提供されています。

### /MT (静的ランタイムライブラリ)

C ランタイムライブラリのコードが、最終的な実行ファイルや DLL に直接埋め込まれます。

**使用されるライブラリファイル**

- `LIBCMT.lib` (リリースビルド)
- `LIBCMTD.lib` (デバッグビルド、`/MTd`)

**特徴**

- 実行ファイルのサイズが大きくなる (ランタイムコードが埋め込まれるため)
- 実行時に追加の DLL (`vcruntime140.dll` など) が不要
- 配布が簡単 (実行ファイル単体で動作)
- 各モジュール (exe, dll) が独立したランタイムライブラリのコピーを持つ

### /MD (動的ランタイムライブラリ)

C ランタイムライブラリのコードは実行ファイルには埋め込まれず、実行時に専用の DLL を動的にロードして使用します。

**使用されるライブラリファイル**

- `MSVCRT.lib` (インポートライブラリ、リリースビルド)
- `MSVCRTD.lib` (インポートライブラリ、デバッグビルド、`/MDd`)

**実行時に必要な DLL**

- `vcruntime140.dll` (Visual Studio 2015 以降)
- `msvcp140.dll` (C++ 標準ライブラリ、C++ プログラムの場合)
- `ucrtbase.dll` (Universal CRT)

**特徴**

- 実行ファイルのサイズが小さくなる (ランタイムコードが含まれないため)
- 実行時に上記の DLL が必要
- 複数のモジュール (exe, dll) が同じランタイムライブラリインスタンスを共有
- メモリ効率が良い (複数のプロセスで DLL を共有)

## /MT と /MD の主な違い

以下の表は、`/MT` と `/MD` の主な違いをまとめたものです。

| 項目                           | /MT (静的)           | /MD (動的)           |
|:-------------------------------|:---------------------|:---------------------|
| ランタイムコードの配置         | 実行ファイルに埋め込み | DLL として分離       |
| 実行ファイルのサイズ           | 大きい               | 小さい               |
| 配布に必要なファイル           | 実行ファイルのみ     | 実行ファイル + ランタイム DLL |
| メモリ使用量                   | 各モジュールが独立したコピーを持つため大きい | 複数モジュールで共有するため小さい |
| リンク時のライブラリファイル   | `LIBCMT.lib`         | `MSVCRT.lib` (インポートライブラリ) |
| モジュール間でのランタイム共有 | 不可 (各モジュールが独立) | 可 (同じ DLL を共有) |

## デバッグビルドの /MTd と /MDd

デバッグ用のランタイムは、追加の検査でバグを見つけやすくする特別版です。これをデバッグ CRT (Debug C Runtime) と呼びます。開発時の利用を想定しており、配布には使いません。

### /MTd (静的・デバッグ CRT)

デバッグ CRT を実行ファイルや DLL に静的に取り込みます。

**使用されるライブラリファイル**

- `LIBCMTD.lib` (デバッグビルド)

**特徴**

- アサートやデバッグヒープなどの追加チェックが有効になるため、問題を早期に見つけやすい
- 実行ファイルがさらに大きくなり、処理も遅くなる
- 配布用途には不適切。開発環境内での実行に限る
- `/MT` や `/MD`、`/MDd` との混在は不可

**ビルド設定例**

```{.makefile caption="デバッグ構成の例（静的）"}
CFLAGS := /W4 /Zi /TC /nologo /utf-8 /FS /MTd /Fd$(TARGETDIR)/$(TARGET_BASE).pdb /I$(WORKSPACE_FOLDER)/prod/calc/include
```

### /MDd (動的・デバッグ CRT)

デバッグ CRT を実行時に DLL として読み込みます。

**使用されるライブラリファイル**

- `MSVCRTD.lib` (インポートライブラリ、デバッグビルド)

**実行時に必要な DLL**

- `vcruntime140d.dll`
- `msvcp140d.dll` (C++ の場合)
- `ucrtbased.dll` (Universal CRT のデバッグ版)

**特徴**

- 追加チェックが有効で、実行サイズは小さめだが、実行には上記のデバッグ DLL が必要
- デバッグ DLL は Visual Studio もしくは Build Tools の一部として提供され、再頒布可能パッケージには含まれない
- 配布用途には不適切。開発環境内での実行に限る
- `/MT` や `/MD`、`/MTd` との混在は不可

**ビルド設定例**

```{.makefile caption="デバッグ構成の例（動的）"}
CFLAGS := /W4 /Zi /TC /nologo /utf-8 /FS /MDd /Fd$(TARGETDIR)/$(TARGET_BASE).pdb /I$(WORKSPACE_FOLDER)/prod/calc/include
```

### デバッグ CRT 利用時の注意

- デバッグとリリースを混在させない。プロジェクト内で、デバッグは一貫して `/MTd` または `/MDd` に統一し、リリースは `/MT` または `/MD` に統一する
- 混在時は LNK4098 の警告が `MSVCRTD` などを含む形で出ることがある。必ず原因を直す
- デバッグ CRT の挙動（イテレータ検証など）に依存したコードを書かない。リリースでは無効になる

## 混在時の問題

異なるランタイムリンクモデル (`/MT` と `/MD`) でビルドされたモジュール (実行ファイル、静的ライブラリ、DLL) を混在させると、以下の深刻な問題が発生します。

### 異なるヒープの使用によるクラッシュ

`/MT` と `/MD` では、それぞれ独立したヒープマネージャーが使用されます。一方のヒープで確保したメモリを他方で解放しようとすると、クラッシュが発生します。

```{.c caption="ヒープ不一致の例"}
// libfoo.lib (/MT でビルド) 内の関数
char* create_buffer(void) {
    return malloc(100);  // /MT のヒープで確保
}

// main.exe (/MD でビルド) 内
int main(void) {
    char* p = create_buffer();
    free(p);  // /MD のヒープで解放 → クラッシュ!
    return 0;
}
```

### グローバル変数の二重インスタンス

C ランタイムのグローバル変数 (例: `errno`, `stdin`, `stdout`) が、`/MT` と `/MD` のモジュールでそれぞれ別のインスタンスとして存在します。一方で設定した値が他方では反映されず、意図しない動作が発生します。

```{.c caption="errno の二重インスタンス"}
// libfoo.lib (/MT でビルド) 内の関数
void set_error(void) {
    errno = EINVAL;  // /MT の errno に設定
}

// main.exe (/MD でビルド) 内
int main(void) {
    set_error();
    printf("errno = %d\n", errno);  // /MD の errno を参照 → 0 (変更されていない!)
    return 0;
}
```

### リンカー警告 LNK4098

異なるランタイムライブラリが混在している場合、リンカーは以下の警告を出力します。

```text
LINK : warning LNK4098: defaultlib 'LIBCMT' conflicts with use of other libs; use /NODEFAULTLIB:library
```

この警告は、プロジェクト内でランタイムリンクモデルが統一されていないことを示しています。この警告を無視すると、上記のようなクラッシュやメモリ破壊が発生する可能性があります。

## プロジェクトでの推奨事項

### 基本原則

**プロジェクト全体で同じランタイムリンクモデルを使用する**

すべての実行ファイル、静的ライブラリ、DLL を同じモデル (`/MT` または `/MD`) でビルドする必要があります。

### /MD を推奨する理由

Microsoft 公式ドキュメントでは、特に DLL を含むプロジェクトでは `/MD` の使用を推奨しています。理由は以下の通りです。

**DLL との親和性**

DLL は複数の実行ファイルから呼び出される可能性があります。`/MD` を使用することで、すべての DLL と実行ファイルが同じランタイムライブラリインスタンスを共有し、ヒープの不一致やグローバル変数の問題を回避できます。

**メモリ効率**

複数のモジュールが同じランタイムライブラリ DLL を共有するため、メモリ使用量が削減されます。

**Microsoft の標準的な手法**

Windows のシステム DLL や多くのサードパーティライブラリは `/MD` でビルドされているため、これに合わせることで互換性の問題を減らせます。

**配布の手間**

Microsoft は Visual C++ 再頒布可能パッケージ (Visual C++ Redistributable) を提供しており、ユーザーはこれをインストールすることで、すべての `/MD` アプリケーションに必要なランタイム DLL を一度に入手できます。

### /MT を選択するケース

以下の条件を満たす場合は、`/MT` の選択も有効です。

**単一の実行ファイルのみのプロジェクト**

DLL を作成せず、単一の実行ファイルのみを配布する場合、`/MT` を使用することで配布が簡単になります (ランタイム DLL が不要)。

**DLL 境界を越えたメモリ操作がない**

DLL が整数や値型のみを受け渡し、ポインタの受け渡しやメモリの割り当て/解放を行わない場合、`/MT` でも問題は発生しません。

**配布先の環境が限定的**

配布先の環境が限定されており、ランタイム DLL のインストールが困難な場合、`/MT` を使用することで依存関係を削減できます。

### 本プロジェクトでの選択

本プロジェクト (doxygen-sample) では、以下の理由から **`/MD` を採用**しています。

**DLL を含むプロジェクト**

`calc.dll` を作成しており、これを `add.exe` がリンクしています。`/MD` を使用することで、DLL と exe が同じランタイムライブラリインスタンスを共有し、将来的な拡張 (ポインタの受け渡しなど) にも対応できます。

**複雑なプロジェクトへの拡張性**

将来、他のライブラリや機能を追加する際、`/MD` であれば互換性の問題が発生しにくくなります。

**Microsoft の推奨に従う**

標準的な Windows 開発の手法に従うことで、他の開発者やツールとの互換性を保ちます。

## ビルド設定

本プロジェクトでは、すべてのコンポーネントを `/MD` でビルドするよう設定しています。

### 静的ライブラリ (calcbase.lib)

```{.makefile caption="prod/calc/libsrc/makelibsrc-windows-poc.mk"}
CFLAGS := /W4 /Zi /TC /nologo /utf-8 /FS /MD /Fd$(TARGETDIR)/$(TARGET_BASE).pdb /I$(WORKSPACE_FOLDER)/prod/calc/include
```

### 動的リンクライブラリ (calc.dll)

```{.makefile caption="prod/calc/libsrc/makelibsrc-windows-poc.mk"}
CFLAGS := /W4 /Zi /TC /nologo /utf-8 /FS /MD /LD /Fd$(TARGETDIR)/$(TARGET_BASE).pdb /I$(WORKSPACE_FOLDER)/prod/calc/include
```

### 実行ファイル (add.exe)

```{.makefile caption="prod/calc/src/add/Makefile.Windows-poc"}
CFLAGS := /W4 /Zi /TC /nologo /utf-8 /MD /Fd$(OBJDIR)/add.pdb /I$(WORKSPACE_FOLDER)/prod/calc/include
```

すべてのコンポーネントに `/MD` フラグが追加されており、動的ランタイムライブラリを使用します。

## 実行環境の準備

`/MD` でビルドされたプログラムを実行するには、Visual C++ 再頒布可能パッケージのインストールが必要です。

### 再頒布可能パッケージの入手

Microsoft の公式サイトから、使用している Visual Studio のバージョンに対応する再頒布可能パッケージをダウンロードします。

- Visual Studio 2015, 2017, 2019, 2022 用: [https://learn.microsoft.com/ja-jp/cpp/windows/latest-supported-vc-redist](https://learn.microsoft.com/ja-jp/cpp/windows/latest-supported-vc-redist)

### インストール

ダウンロードした再頒布可能パッケージ (例: `vc_redist.x64.exe`) を実行し、インストールします。これにより、以下の DLL がシステムにインストールされます。

- `vcruntime140.dll`
- `msvcp140.dll`
- `ucrtbase.dll`

インストール後、`/MD` でビルドされたプログラムが正常に実行できます。

### デバッグビルドの実行についての注意

- `/MDd` でビルドしたプログラムは、`vcruntime140d.dll`、`msvcp140d.dll`、`ucrtbased.dll` が必要です。これらは Visual Studio または Build Tools に含まれ、Visual C++ 再頒布可能パッケージには含まれません
- `/MTd` は DLL 依存はありませんが、デバッグ CRT を静的に含むため配布には不向きです
- いずれも配布用途ではなく、開発環境での動作確認に限って使用してください

## まとめ

MSVC におけるランタイムライブラリのリンクモデルの選択は、プロジェクト全体の安定性と保守性に大きく影響します。

### 重要なポイント

**プロジェクト全体で統一する**

すべてのモジュール (実行ファイル、静的ライブラリ、DLL) を同じモデルでビルドします。

**複雑なプロジェクトでは /MD を推奨**

DLL を含むプロジェクトや、将来的な拡張を想定する場合は、`/MD` (動的ランタイム) を使用します。

**警告を無視しない**

リンカー警告 LNK4098 が出力された場合は、ランタイムリンクモデルの不一致が発生しているため、必ず修正します。

**配布時には再頒布可能パッケージが必要**

`/MD` を使用する場合、ユーザーの環境に Visual C++ 再頒布可能パッケージがインストールされている必要があります。

本プロジェクトでは、すべてのコンポーネントを `/MD` でビルドすることで、ランタイムライブラリの統一を実現し、安定した動作を保証しています。

## 参考リンク

- Microsoft Docs: C ランタイム ライブラリのリンク
  [https://learn.microsoft.com/ja-jp/cpp/c-runtime-library/crt-library-features](https://learn.microsoft.com/ja-jp/cpp/c-runtime-library/crt-library-features)

- Microsoft Docs: /MD、/MT、/LD (ランタイム ライブラリの使用)
  [https://learn.microsoft.com/ja-jp/cpp/build/reference/md-mt-ld-use-run-time-library](https://learn.microsoft.com/ja-jp/cpp/build/reference/md-mt-ld-use-run-time-library)

- Microsoft Docs: 最新のサポートされる Visual C++ 再頒布可能パッケージのダウンロード
  [https://learn.microsoft.com/ja-jp/cpp/windows/latest-supported-vc-redist](https://learn.microsoft.com/ja-jp/cpp/windows/latest-supported-vc-redist)

- Microsoft Docs: デバッグ CRT の概要
  [https://learn.microsoft.com/ja-jp/cpp/c-runtime-library/debug-versions-of-the-crt-library](https://learn.microsoft.com/ja-jp/cpp/c-runtime-library/debug-versions-of-the-crt-library)

- Microsoft Docs: Visual C++ ファイルの再頒布（デバッグ版は再頒布不可）
  [https://learn.microsoft.com/ja-jp/cpp/windows/redistributing-visual-cpp-files](https://learn.microsoft.com/ja-jp/cpp/windows/redistributing-visual-cpp-files)
