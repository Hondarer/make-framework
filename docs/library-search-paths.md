# ライブラリ探索パスの扱い (Linux)

## 概要

Linux のリンクでは、`LIBSDIR` に設定したディレクトリを `-L` と `-rpath-link` の両方へ与えます。  
`-L` だけでは共有ライブラリの間接依存を解決できず、リンクの成否が実行環境の `LD_LIBRARY_PATH` に左右されるためです。

生成されるフラグは次の形です。

```text
-L<dir1> -L<dir2> -Wl,-rpath-link,<dir1> -Wl,-rpath-link,<dir2>
```

## 直接依存と間接依存

リンカーが探索するライブラリには 2 種類あります。

| 種別 | 例 | 探索に使われるもの |
|---|---|---|
| 直接依存 | コマンド ラインの `-lfoo` | `-L`、既定の探索パス |
| 間接依存 | `libfoo.so` が `DT_NEEDED` に持つ `libbar.so` | `-rpath-link`、`-rpath`、`LD_LIBRARY_PATH`、`DT_RUNPATH`、既定の探索パス |

`-L` は直接依存にしか使われません。  
`libfoo.so` を `-lfoo` でリンクするとき、`libfoo.so` 自身が要求する `libbar.so` は `-L` では見つからず、次の診断でリンクが失敗します。

```text
/usr/bin/ld: warning: libbar.so, needed by .../libfoo.so, not found (try using -rpath or -rpath-link)
.../libfoo.so: `bar_func' に対する定義されていない参照です
```

`-rpath-link` を与えていない場合、この解決は `LD_LIBRARY_PATH` に頼ることになります。  
対話環境では `LD_LIBRARY_PATH` が設定済みであることが多く、CI のようにビルド段階で設定していない環境でだけ失敗します。  
`-L` と同じディレクトリを `-rpath-link` にも与えることで、この環境差をなくします。

see: https://sourceware.org/binutils/docs/ld/Options.html (`-rpath-link`)

## 生成物への影響

`-rpath-link` はリンク時の探索にのみ使われ、生成物には記録されません。  
`RPATH` / `RUNPATH` を制御するのは `-rpath` であり、必要な場合は末端の `makepart.mk` で `LDFLAGS` へ明示的に指定します。

```makefile
ifdef PLATFORM_LINUX
    # 実行ファイルと同じディレクトリへ配置した共有ライブラリを実行時に解決する。
    LDFLAGS += -Wl,-z,origin -Wl,-rpath,'$$ORIGIN'
endif
```

`$ORIGIN` は動的リンカーが実行時に展開する記法であり、リンク時の探索先としては機能しません。  
実行時に `$ORIGIN` で解決する構成であっても、リンク時の解決は `-rpath-link` が担います。

## Windows での扱い

MSVC はインポート ライブラリを介してリンクするため、間接依存を探索する仕組みがありません。  
`LIBSDIR` は `/LIBPATH:` にのみ展開し、`-rpath-link` に相当する指定は行いません。

## 実行時パスとの関係

`-rpath-link` が解決するのはリンク時だけです。  
`RPATH` / `RUNPATH` を持たない実行体を動かすには、実行時に `LD_LIBRARY_PATH` が必要です。  
ビルドと実行でパス設定の目的が異なる点に注意してください。

## 関連ドキュメント

- [ビルド構成の指定方法](build-configurations.md)
- [makepart.mk / makechild.mk / makelocal.mk の役割](makeparts.md)
