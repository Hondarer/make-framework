<!--
生成元: agree-before-implement スキル
文書種別: 検討用 Markdown (discussion)
最終更新日時: 2026-11-15 14:38:28 JST
最終更新エージェント: codex (Sol、案件文書の保管)
稼働 OS: Windows
下流文書: `261115-gcc-pch-resolve-probe-design.md` (最終仕様)、`261115-gcc-pch-resolve-probe-backlog.md` (残課題一覧)。未作成の場合や、削除されている場合があります。
再開手順: このファイルを開いたエージェントは、作業の前に agree-before-implement スキルを読み込んでください。ユーザーが編集した最新版を読み直し、作業 WBS の `← **CURRENT**` の項目から再開します。最終更新エージェントのセッション情報や稼働 OS・最終更新日時が参照可能であれば再開時のコンテキストや環境差分の把握に利用し、別エージェントや別環境・別 OS からの引き継ぎ、担当変更によりセッションが見つからない場合も異常とせず、文書の記載から継続してください。`← **CURRENT**` の項目は処理が中止された項目である場合があり、どこまで進んでいたかは文書だけでは分かりません。対象成果物の内容を確認して実施済みの範囲を特定してから、作業を再開してください。`← **CURRENT**` がなく、作業 WBS がすべて完了 (✅) であれば、この案件の合意フローは完了しています。
-->

# GCC 自動 PCH の include 解決プローブ (.makefw-pch-resolve-*) の Git 混入防止の検討

ファイル名: `261115-gcc-pch-resolve-probe-discussion.md`

## 検討の識別

検討 ID: gcc-pch-resolve-probe-20261115

版: 4

状態: 完了

## 作業 WBS と進捗管理

この検討用 Markdown が管理する作業 WBS です。検討用 Markdown のための情報収集と質問の実施、残懸念がないことの確認 (第 1 ゲート: 最終仕様作成への着手)、最終決定事項 (最終仕様) を記載した `261115-gcc-pch-resolve-probe-design.md` の作成、最終仕様の承認の受付 (第 2 ゲート)、承認された最終仕様に従った作業の実施、および作業完了後の成果物の承認の受付 (第 3 ゲート) に至る詳細な手順を記載します。  
具体的な作業対象を明記し、Q&A のターンごとに必要に応じて見直します。各ゲートの通過・承認および作業の進行に従って状態を更新します。見送りの決定や範囲外の気付きは、どの段階でも生じた時点で `261115-gcc-pch-resolve-probe-backlog.md` に追記します。

凡例: ⏸️ 未着手、🔄 実施中、🚫 ブロック中、⚠️ 要注意、✅ 完了。現在取り組んでいる項目の末尾に `← **CURRENT**` を付けます。

- ✅ 1. 検討用 Markdown のための情報収集と質問の実施
    - ✅ 1.1. 前提条件と要求事項の調査 (`framework/makefw/bin_internal/gcc_pch.py`、`bin_test/gcc_pch_selftest.py`、`resolve_app_deps.sh`、および各 `.gitignore` の調査)
    - ✅ 1.2. 課題・論点の抽出と明確化のための確認項目 ([Q-001](#q-001-makefw-pch-resolve-の除外方式)〜[Q-003](#q-003-検証範囲と回帰テストの追加方針)) の作成
    - ✅ 1.3. Q-001 の A、Q-002 の C と補足、Q-003 の A、Q-004 の A の回答を受付・記録
    - ✅ 1.4. 回答に基づく前提・制約の検証と WBS の見直し
- ✅ 2. 前提合意と残懸念の解消 (第 1 ゲート: 最終仕様作成への着手)
    - ✅ 2.1. 全論点に対する未解決事項および質問の解消確認
    - ✅ 2.2. 方針・前提条件の合意確定
- ✅ 3. 最終決定事項 (最終仕様) の作成と承認の受付
    - ✅ 3.1. `framework/makefw/docs/prompts/past/261115-gcc-pch-resolve-probe-design.md` の作成
    - ✅ 3.2. 最終仕様における受入条件と整合性の確認
    - ✅ 3.3. 対話セッションにおける最終仕様 (`261115-gcc-pch-resolve-probe-design.md`) の承認の受付 (第 2 ゲート: 作業着手の合意)
- ✅ 4. 承認された最終仕様に従った作業の実施
    - ✅ 4.1. `framework/makefw/bin_internal/gcc_pch.py` のプローブ生成処理の更新
    - ✅ 4.2. `framework/makefw/bin_test/gcc_pch_selftest.py` への回帰テスト追加
    - ✅ 4.3. 正本ドキュメントおよびコード コメントへの永続的知見の反映
    - ✅ 4.4. 局所テスト (`gcc_pch_selftest.py`) および機械的検証 (`text_style_jp.py`) の実施
    - ✅ 4.5. 受入条件への適合確認 (全完確認)
    - ✅ 4.6. 残課題一覧 (`261115-gcc-pch-resolve-probe-backlog.md`) の再構築と整理 (残渣がない場合は作成しない)
- ✅ 5. 成果物の承認の受付 (第 3 ゲート)
    - ✅ 5.1. 成果物・検証結果・残課題の提示
    - ✅ 5.2. 対話セッションにおける成果物の承認の受付 (「承認」または「完了」の受領によるスキル完了): 対話で「承認」を受領し完了

## 対象と参照資料

対象成果物 (予定):

- `framework/makefw/bin_internal/gcc_pch.py`
- `framework/makefw/bin_test/gcc_pch_selftest.py`
- ([Q-001](#q-001-makefw-pch-resolve-の除外方式) で `.gitignore` 追加を選択した場合) ルート、各 `app/<name>`、`framework/testfw` の `.gitignore`

今回の対象範囲: Linux (GCC) の自動 PCH 準備処理 (`gcc_pch.py`) が生成する一時プローブ ファイル `.makefw-pch-resolve-<pid>.c` が、ソース ディレクトリに残存・観測された際に Git の管理対象やビルド署名へ混入する問題の対策。

書き込み可能な検討用 Markdown: この文書 (`framework/makefw/docs/prompts/past/261115-gcc-pch-resolve-probe-discussion.md`)

参照資料と版:

- `framework/makefw` HEAD (今回の照合時): `f6a1367d97f1ec99a52e64d6af4246db04e6342f` (初回調査時の記録: `49a9ed24c3e2b55dea1263cf1e995d457919910f`)
    - [gcc_pch.py](../../../bin_internal/gcc_pch.py)
    - [gcc_pch_selftest.py](../../../bin_test/gcc_pch_selftest.py)
    - [resolve_app_deps.sh](../../../bin_internal/resolve_app_deps.sh)
    - [makelibsrc_c_cpp.mk](../../../makefiles/makelibsrc_c_cpp.mk)
    - [makesrc_c_cpp.mk](../../../makefiles/makesrc_c_cpp.mk)
    - [build-configurations.md](../../build-configurations.md)
- ワークスペース ルート HEAD (今回の照合時): `c4e2d75ef57960084c91f17850672e8a0ed690cb` (初回調査時の記録: `28410ef5`)
    - [.gitignore](../../../../../.gitignore)

## 現行の合意内容

Q-001 は A、Q-003 は A の選択を確認しました。Q-002 は C と「Q-001 を受けて推奨かつ実現性のある選択肢を推奨としてユーザーに提示して」という回答を受け付けました。生成先は `objdir` 配下とし、`.gitignore` は変更しません。検証はセルフ テストへの追加と WSL での実行、および文書の表記検査で行い、全体テストは実施しません。Q-004 の A の選択も確認し、一意な空の一時ディレクトリと先頭の引用符 include の絶対パス化を採用します。探索前提が成立しない指定では通常コンパイルへ戻します。

当初、ユーザーが示した課題認識 (`.makefw-pch-resolve-*` が Git 履歴に乗ってしまうため、`obj` 配下に作成するか `.gitignore` するかの方法で除外すべき) を要件として整理し、[Q-001](#q-001-makefw-pch-resolve-の除外方式)〜[Q-003](#q-003-検証範囲と回帰テストの追加方針) で方針を確認しました。

## 観点別の確認

| 観点 | 状態 | 根拠・関連 Q |
| --- | --- | --- |
| 目的・利用者 | 確認済み | ビルド中断時や並列ビルド中に `.makefw-pch-resolve-*.c` が Git の管理対象やビルド署名に混入することを防ぐ ([Q-001](#q-001-makefw-pch-resolve-の除外方式)) |
| 範囲・境界 | 確認済み | `objdir` 配下へ移動し、各リポジトリの `.gitignore` は変更しないことを確認済み ([Q-001](#q-001-makefw-pch-resolve-の除外方式)) |
| 入力・根拠 | 確認済み | [gcc_pch.py](../../../bin_internal/gcc_pch.py#L331-L395)、[gcc_pch_selftest.py](../../../bin_test/gcc_pch_selftest.py#L311-L336)、[resolve_app_deps.sh](../../../bin_internal/resolve_app_deps.sh#L517-L718)、[.gitignore](../../../../../.gitignore#L1-L50) を確認済み |
| 整合性・依存関係 | 確認済み | `make clean`、`BUILD_SIGNATURE`、`assured.stamp`、および引用符 `#include "..."` の解決規則との整合を最終仕様の受入条件へ反映済み ([Q-001](#q-001-makefw-pch-resolve-の除外方式)、[Q-002](#q-002-objdir-配下へ移動した際の引用符-include-の探索基準の維持方法)) |
| 実現性・例外 | 確認済み | `-iquote` を追加しない代替案を一時環境で検証済み。採用は [Q-004](#q-004-探索パスを追加しないプローブ配置案の採用) の A で合意済み ([Q-002](#q-002-objdir-配下へ移動した際の引用符-include-の探索基準の維持方法)) |
| 受入条件・検証 | 確認済み | 検証範囲は局所テストと文書検査で合意済み。追加案の受入条件は [Q-004](#q-004-探索パスを追加しないプローブ配置案の採用) の A で合意済み ([Q-003](#q-003-検証範囲と回帰テストの追加方針)) |

Table: 観点別の確認状況

## 質問一覧

| Q-ID | 論点 | 状態 | 依存・関連 |
| --- | --- | --- | --- |
| [Q-001](#q-001-makefw-pch-resolve-の除外方式) | `.makefw-pch-resolve-*` の除外方式 | 回答済み (A) | なし |
| [Q-002](#q-002-objdir-配下へ移動した際の引用符-include-の探索基準の維持方法) | `objdir` 配下へ移動した際の引用符 `#include "..."` の探索基準の維持方法 | 回答済み (C) | [Q-001](#q-001-makefw-pch-resolve-の除外方式) |
| [Q-003](#q-003-検証範囲と回帰テストの追加方針) | 検証範囲と回帰テストの追加方針 | 回答済み (A) | [Q-001](#q-001-makefw-pch-resolve-の除外方式)、[Q-002](#q-002-objdir-配下へ移動した際の引用符-include-の探索基準の維持方法) |
| [Q-004](#q-004-探索パスを追加しないプローブ配置案の採用) | 探索パスを追加しないプローブ配置案 | 回答済み (A) | [Q-002](#q-002-objdir-配下へ移動した際の引用符-include-の探索基準の維持方法) |

Table: 質問一覧

## 明確化のための確認項目

### Q-001 .makefw-pch-resolve-* の除外方式

**Status**

回答済み (A)

**Question**

`.makefw-pch-resolve-<pid>.c` が Git の未追跡ファイル一覧やビルド署名に混入する問題に対し、`objdir` 配下への生成先変更と `.gitignore` への追加のどちらの方式を採用しますか。

**Context**

- **経緯と背景**:  
  [gcc_pch.py](../../../bin_internal/gcc_pch.py#L331-L372) の `_resolve_includes()` は、ソース先頭の無条件 `#include` が開くヘッダー パスを特定するため、`source_directory` 直下に `.makefw-pch-resolve-<pid>.c` を作成して `gcc -H -E -fsyntax-only` を実行しています。通常時は `finally` 節で削除されますが、`finally` が実行されない強制終了時には残存し、実行中の Git 操作では一時的に観測される可能性があります。  
  `subprocess.run()` 中の Python 例外では `finally` が実行されるため、中断すべてで残存するわけではありません。`probe.write_text()` は `try` の外にあります。  
  ルートの [.gitignore](../../../../../.gitignore#L1-L50) は `*` で全無視した後に `!*.*` でドットを含むファイルを管理対象に戻す構成であり、除外リストに `.makefw-pch-resolve-*` がないため未追跡ファイルとして表示され得ます。Git 履歴への追加には、別途ステージングとコミットが必要です。履歴に実際に混入した事例は今回確認していません。
- **二次的な影響**:  
  ソース ディレクトリ直下に `.makefw-pch-resolve-*.c` が残ると、Git への混入以外にも次の問題が生じます。
    1. [makelibsrc_c_cpp.mk](../../../makefiles/makelibsrc_c_cpp.mk#L686-L731) と [makesrc_c_cpp.mk](../../../makefiles/makesrc_c_cpp.mk#L582-L606) の `make clean` は `obj`、`gen`、引き込みソース、`*.warn` 等のみを削除するため、残存した `.makefw-pch-resolve-*.c` が削除されません。
    2. [resolve_app_deps.sh](../../../bin_internal/resolve_app_deps.sh#L660-L692) の `is_signature_file()` は拡張子 `.c` を署名対象に含め、`is_excluded_signature_path()` は `obj/*` 等を除外します。実際のツリー走査は `collect_tree_signature_files()` の `find` と `awk` で同等の条件を適用するため、走査範囲内 (`prod/`、対象となる `test/` 等) にあるプローブは、残存時だけでなく生成中にも署名へ混入し得ます。Git の無視設定はこの走査に使用されません。
- **根拠資料**:
    - [gcc_pch.py](../../../bin_internal/gcc_pch.py#L331-L372)
    - [resolve_app_deps.sh](../../../bin_internal/resolve_app_deps.sh#L660-L692)
    - [.gitignore](../../../../../.gitignore#L1-L50)
- **各案の比較**:
    - **案 A (`objdir` 配下へ生成先を変更、`.gitignore` は変更しない)**:  
      生成先に加えて `_usable_prefix()` と `_resolve_includes()` の引数・呼び出しの変更、および探索順の維持が必要です。標準の `OBJDIR` (`obj` または `obj/<構成>`) は署名走査の除外対象で、該当する `.gitignore` の `obj/` 規則と通常の `make clean` による削除対象にもなります。任意の `--objdir` に同じ効果があるとは限りません。
    - **案 B (`.gitignore` に `.makefw-pch-resolve-*` を追加)**:  
      プローブが生成されるソース ディレクトリを管理する各 Git リポジトリの `.gitignore` が変更候補です。ルートの規則はサブモジュール内部へ適用されないため、対象リポジトリの列挙が必要です。コミット操作は今回の依頼に含みません。また、異常終了時にソース ディレクトリへ残ったファイルが `make clean` で消えず、`BUILD_SIGNATURE` の `*.c` 走査に拾われる問題が残ります。
    - **案 C (案 A と案 B の両方を実施)**:  
      `objdir` 配下へ移した上で、過去の版などがソース ツリーへ生成する場合に備えて各 `.gitignore` にも追加する案です。ただし、ソースを管理する対象リポジトリごとに `.gitignore` の変更が必要です。すでに残存しているファイルの署名混入や削除漏れは、この追加だけでは解消しません。

**Answer**

選択方式: 単一選択

- [x] A: (推奨) `gcc_pch.py` のプローブ ファイル生成先を `source_directory` から `objdir` 配下へ変更し、`.gitignore` は変更しない。
- [ ] B: 生成先は `source_directory` のままとし、ルート・各 `app/<name>`・`framework/testfw` の `.gitignore` に `.makefw-pch-resolve-*` を追加する。
- [ ] C: A (`objdir` 配下への生成先変更) と B (各 `.gitignore` への `.makefw-pch-resolve-*` 追加) の両方を実施する。
- [ ] D: その他
- [ ] X: 意図不明 (詳細な質問内容に再生成すること)

その他の回答 / 補足:

**Recommendation**

推奨: A  
理由: 標準の `obj/` 配下に新規プローブを配置すれば、既存の無視・削除・署名除外の仕組みを利用できます。ただし、探索順の維持方法は [Q-002](#q-002-objdir-配下へ移動した際の引用符-include-の探索基準の維持方法) で決める必要があり、すでにソース側へ残存したプローブへの対処は別途必要です。

**Related**

- [Q-002](#q-002-objdir-配下へ移動した際の引用符-include-の探索基準の維持方法)
- [Q-003](#q-003-検証範囲と回帰テストの追加方針)

### Q-002 objdir 配下へ移動した際の引用符 include の探索基準の維持方法

**Status**

回答済み (C: 実現性を確認した推奨案の提示を依頼)

**Question**

[Q-001](#q-001-makefw-pch-resolve-の除外方式) でプローブ ファイルを `objdir` 配下へ配置する場合、ソース ディレクトリ基準の引用符 `#include "..."` の解決を、`flags` の先頭への `-iquote <source_directory>` 付与で維持してよいですか。

**Context**

- **経緯と背景**:  
  元実装が `probe` を `source_directory` に置いていた理由は、GCC が引用符形式の `#include "file"` を探索する際、「コンパイル対象ファイル (`probe`) の親ディレクトリ」を最優先で探し、次に `-iquote`、その後に `-I` を探す仕様であるためです ([GCC Search Path](https://gcc.gnu.org/onlinedocs/cpp/Search-Path.html))。  
  なお、プローブ内に `# 1 "<source_directory>/..."` (`#line`) ディレクティブを書いても、GCC は診断上の位置情報や `__FILE__`・`__LINE__` を変更しますが `#include "..."` の探索先ディレクトリは変更しません ([GCC Line Control](https://gcc.gnu.org/onlinedocs/cpp/Line-Control.html))。また、標準入力 (`-`) から渡した場合はカレント作業ディレクトリ (`cwd`) が最優先探索先になるため、`cwd` と `source_directory` が異なる呼び出しで探索先がずれます。  
  `-iquote <source_directory>` をユーザー `flags` より前に追加しても、引用符 include ではプローブ自身のディレクトリが先に探索されます。今回の WSL / GCC 8.5.0 の最小実験では、ソース側と `objdir` 側に同名の `local.h` を配置すると `objdir` 側が選択されました。したがって案 A は、そこに競合するヘッダーが存在しないことを条件とする案です。  
  初回文書にあった「一時環境で全 20 項目が通過した」という記録には、実行コマンド・変更差分・ログがなく、今回その変更版の成功は追認していません。今回実行したのは現行未変更版のセルフ テストであり、`main()` の確認呼び出しに対応する全 21 項目が通過しました。  
  また、追加した `-iquote` は読み込まれたヘッダー内部の引用符 include にも作用します。プローブを空の一時ディレクトリへ配置しても、ソース先頭の include と入れ子の include の双方で現行と同じ解決先になるか検証が必要です。
- **根拠資料**:
    - [gcc_pch.py](../../../bin_internal/gcc_pch.py#L331-L395)
    - [gcc_pch_selftest.py](../../../bin_test/gcc_pch_selftest.py#L311-L336)
- **現状のコード引用**:

```python
def _resolve_includes(
    compiler: str,
    flags: list[str],
    language: str,
    includes: list[str],
    source_directory: Path,
) -> list[Path] | None:
    """接頭辞の各 include が開くファイルを、GCC の探索順で返す。失敗時は None。"""
    probe = source_directory / f".makefw-pch-resolve-{os.getpid()}.c"
    probe.write_text("\n".join(f"#include {include}" for include in includes) + "\n", encoding="utf-8")
    header_language = "c" if language == "c" else "c++"
    command = [compiler, *flags, "-H", "-E", "-fsyntax-only", "-x", header_language, str(probe)]
```

- **各案の具体例・コード比較**:

```python
# 案 A (競合するヘッダーがないことが前提): objdir に probe を作成し、flags の先頭に -iquote <source_directory> を付与する
def _resolve_includes(
    compiler: str,
    flags: list[str],
    language: str,
    includes: list[str],
    source_directory: Path,
    objdir: Path,
) -> list[Path] | None:
    """接頭辞の各 include が開くファイルを、GCC の探索順で返す。失敗時は None。"""
    objdir.mkdir(parents=True, exist_ok=True)
    probe = objdir / f".makefw-pch-resolve-{os.getpid()}.c"
    probe.write_text("\n".join(f"#include {include}" for include in includes) + "\n", encoding="utf-8")
    header_language = "c" if language == "c" else "c++"
    command = [
        compiler,
        "-iquote",
        str(source_directory),
        *flags,
        "-H",
        "-E",
        "-fsyntax-only",
        "-x",
        header_language,
        str(probe),
    ]
```

```python
# 案 B: objdir 配下にプロセス固有の空サブディレクトリを作って probe を置く場合
# (objdir 直下のヘッダーとの競合を避ける案。入れ子の include の検証も必要)
probe_dir = objdir / f".makefw-pch-resolve-{os.getpid()}"
probe_dir.mkdir(parents=True, exist_ok=True)
# 既存ディレクトリの再利用では空である保証がない。実装時は一意で空の一時ディレクトリと後始末が必要。
probe = probe_dir / "probe.c"
```

**Answer**

選択方式: 単一選択

- [ ] A: `probe` を `objdir` 直下 (`objdir / f".makefw-pch-resolve-{os.getpid()}.c"`) に作成し、GCC 呼び出し時の `flags` の先頭に `-iquote <source_directory>` を付与する。
- [ ] B: `objdir` 配下にプロセス固有の一時サブディレクトリを作成して `probe` を配置し、`flags` の先頭に `-iquote <source_directory>` を付与する。
- [x] C: その他
- [ ] X: 意図不明 (詳細な質問内容に再生成すること)

その他の回答 / 補足: Q-001 を受けて推奨かつ実現性のある選択肢を推奨としてユーザーに提示して

**Recommendation**

初回レビュー時の推奨: B を基に探索順の同等性を検証する案。回答受付後の推奨は [Q-004](#q-004-探索パスを追加しないプローブ配置案の採用) の A  
理由: 案 A では `objdir` 内の同名ヘッダーを先に解決するためです。`decision_lock` は決定キャッシュ単位の排他制御であり、ヘッダーの配置や探索順を保証しません。`auto_*.h` の生成先は `shared_dir` で、セルフ テストのように `shared_dir == objdir` となる構成もあります。また `.lock` や `.gitignore_stamp` 等も存在し、「列挙した拡張子しか生成されない」という前提は成立しません。案 B でも `-iquote` 追加による入れ子の include への影響が残るため、採用を確定するには回帰確認が必要です。

**Related**

- [Q-001](#q-001-makefw-pch-resolve-の除外方式)

### Q-003 検証範囲と回帰テストの追加方針

**Status**

回答済み (A)

**Question**

変更後の検証は、[gcc_pch_selftest.py](../../../bin_test/gcc_pch_selftest.py) への回帰確認の追加と WSL 上での実行 (および変更文書の `text_style_jp.py` 検証) で行う方針としてよいですか。

**Context**

- **経緯と背景**:  
  [gcc_pch_selftest.py](../../../bin_test/gcc_pch_selftest.py) は Linux (WSL) 上で一時ディレクトリを使って `gcc_pch.py` の主要な動作を検証するセルフ テストです。  
  生成先を移す案を採用する場合、ここに「`_resolve_includes()` の実行時に `source_directory` 直下へ `.makefw-pch-resolve-*` が作られず、`objdir` 側で作成・削除されること」の確認を追加すれば、生成先の変更を直接検証できます。終了後の不存在確認だけでは生成中の配置先は確認できないため、GCC 呼び出し中の観測も必要です。正常終了・コンパイラ失敗時の後始末、`objdir` 内の同名ヘッダー、入れ子の引用符 include、既存 `-iquote`・`-I`、`cwd` とソース ディレクトリが異なる場合、および Git 無視・署名除外の確認を追加候補とします。
- **根拠資料**:
    - [gcc_pch_selftest.py](../../../bin_test/gcc_pch_selftest.py)

**Answer**

選択方式: 単一選択

- [x] A: (推奨) `gcc_pch_selftest.py` にプローブ配置先の確認を追加し、WSL での `gcc_pch_selftest.py` 実行と `text_style_jp.py` の確認をもって検証完了とする (全体テストは実施しない)。
- [ ] B: A に加え、指定する個別 app の Linux ビルド確認も実施する。
- [ ] C: その他
- [ ] X: 意図不明 (詳細な質問内容に再生成すること)

その他の回答 / 補足:

**Recommendation**

推奨: A  
理由: 生成先を移す案では、主なコード変更を `gcc_pch.py` に限定でき、`gcc_pch_selftest.py` で引用符 include の解決とプローブの配置・削除を局所検証できるためです。ただし、既存テストだけでは移動後の探索順や Git 無視・署名除外を保証しないため、上記の追加候補を受入条件に具体化する必要があります。

**Related**

- [Q-001](#q-001-makefw-pch-resolve-の除外方式)
- [Q-002](#q-002-objdir-配下へ移動した際の引用符-include-の探索基準の維持方法)

### Q-004 探索パスを追加しないプローブ配置案の採用

**Status**

回答済み (A)

**Question**

Q-001 の A を実現する方法として、`objdir` 配下の一意な空の一時ディレクトリへプローブを配置し、ソース ディレクトリで見つかる先頭の引用符 include だけを絶対パスで記述する案を採用しますか。

**Context**

- **回答を受けた検討**:  
  Q-002 の回答は、実現性を確認した推奨案の提示を求めるものです。追加の `-iquote` は入れ子の引用符 include にも作用するため、探索パスを追加せず、プローブの先頭 include の記述を調整する案を提示します。
- **案 A の処理**:
    1. `tempfile.TemporaryDirectory(prefix=".makefw-pch-resolve-", dir=objdir)` 相当で、一意な空のディレクトリを作成し、その中へ `probe.c` を配置します。
    2. ソース先頭から抽出した `"name.h"` について、`source_directory / "name.h"` に通常のファイルが存在すれば、その絶対パスを引用符 include としてプローブへ記述します。ファイルを指すシンボリック リンクも対象としますが、パスを実体側へ正規化して親ディレクトリを変えないようにします。
    3. ソース側に存在しない引用符 include と山括弧 include は、その記述を維持します。空のプローブ ディレクトリで見つからなければ、既存の `-iquote`・`-I` 等による GCC の探索に進みます。
    4. GCC に渡すユーザー フラグ、環境変数、作業ディレクトリは維持し、探索パスを追加しません。読み込んだヘッダー内部の引用符 include は、GCC がそのヘッダーのディレクトリと既存の探索パスで解決します。
    5. プローブの書き込みと GCC 実行を一時ディレクトリの管理範囲に含め、正常終了と Python 例外時に削除します。強制終了で残存しても標準の `obj/` 配下へ限定します。
- **一時環境での検証結果**:  
  WSL / GCC 8.5.0 において `gcc_pch.py` の一時コピーへ上記の配置・書き換え処理と引数の受け渡しを追加し、既存セルフ テストの全 21 項目が通過しました。警告確認項目は `.warn` に `pch-marker` が残ることを検証しています。  
  追加の独立実験では C と C++ の双方で、ソース側と `objdir` 側の同名ヘッダー、入れ子の引用符 include、既存 `-iquote`・`-I` へのフォールバック、山括弧 include、およびソースと異なる作業ディレクトリを組み合わせ、現行配置と新配置の `-H` 出力の include 経路が一致しました。一時ディレクトリの削除も確認しました。  
  最初の追加実験は、同じガード付きヘッダーを入れ子と先頭の両方から読み込み、先頭 include 数とトレース数を一致させる既存条件に抵触して失敗しました。重複しないヘッダーへ修正した実験が上記の結果です。
- **実装時の受入条件と限界**:  
  上記は実現性の確認であり、製品コードへの反映や全条件の検証は未実施です。実装後は生成中の配置先、ソース側へ生成しないこと、正常終了・GCC 失敗・書き込み失敗時の削除、上記の探索条件、および標準 `obj/` の Git 無視と署名除外を局所確認します。  
  現在ファイルのディレクトリ探索を抑止する `-I-` 等、上記の探索前提が成立しない指定は、誤った PCH を作らず通常コンパイルへ戻す対象とする案です。特殊指定やファイル更新との競合まで含めた一般的な同等性を、今回の実験だけで保証するものではありません。  
  すでにソース側へ残存しているファイルは自動削除しません。新たな生成先の変更と、既存ファイルの削除を分けて扱います。

**Answer**

選択方式: 単一選択

- [x] A: (推奨) 上記の一時ディレクトリ配置と先頭の引用符 include の書き換えを採用し、探索前提が成立しない指定は通常コンパイルへ戻す。
- [ ] B: その他の方式を希望する (補足へ記入)。
- [ ] X: 意図不明 (詳細な質問内容に再生成すること)。

その他の回答 / 補足:

**Recommendation**

推奨: A  
理由: Q-001 の生成先変更を満たしつつ、追加 `-iquote` による入れ子の探索順変更と `objdir` 直下の同名ヘッダーの優先を避けられます。既存 21 項目と C／C++ の追加実験で実現性を確認できました。

**Related**

- [Q-001](#q-001-makefw-pch-resolve-の除外方式)
- [Q-002](#q-002-objdir-配下へ移動した際の引用符-include-の探索基準の維持方法)
- [Q-003](#q-003-検証範囲と回帰テストの追加方針)

## 対象成果物と合意版

最終決定事項 (最終仕様) の設計書: `framework/makefw/docs/prompts/past/261115-gcc-pch-resolve-probe-design.md`

検討用 Markdown の合意版 (第 1 ゲート): 4 (Q-001〜Q-004 の回答を検証し、未解決の質問なし)

最終仕様 (design.md) の合意版 (第 2 ゲート): 1 (承認済み)

更新予定の成果物: `gcc_pch.py` と `gcc_pch_selftest.py`。`.gitignore` は対象外です。具体的な変更と知見の反映先は最終仕様の版 1 に記載しました。

受入条件: Q-004 の A に基づき、最終仕様の版 1 に記載しました。最終仕様の版 1 は承認済みで、成果物も対話で承認済みです。

## 反映と検証の記録

最終仕様 (`261115-gcc-pch-resolve-probe-design.md` 版 1) の承認を受け、実装、回帰テスト追加、コメント反映、および局所検証を完了しました。対話で成果物の「承認」を受領し、第 3 ゲートを通過しました。WBS の全項目が完了しています。

- [gcc_pch.py](../../../bin_internal/gcc_pch.py): `prepare()` の `objdir` を `_usable_prefix()` 経由で `_resolve_includes()` へ渡し、`objdir` 配下に `tempfile.TemporaryDirectory(prefix=".makefw-pch-resolve-", dir=objdir)` を作成して `probe.c` を配置しました。`_probe_include_line()` でソース側に通常ファイル (symlink 含む) が存在する場合のみ `resolve()` せず絶対パス化し、元のフラグ・環境変数・作業ディレクトリを維持しました。`-I-` / `["-I", "-"]` / `--include-barrier` / `-Wp,-I-` 等の探索前提不成立フラグを検出し、通常コンパイルへ戻すよう `_split_flags()` と `_flags_disable_pch()` を更新しました。`GCC Search Path` と `GCC Line Control` の `see:` URL をコメントに残しました。
- [gcc_pch_selftest.py](../../../bin_test/gcc_pch_selftest.py): 既存 21 項目に加え、プローブ配置先観測と正常・GCC 失敗・書き込み例外時の後始末、C／C++ での `objdir` 同名ヘッダーおよび入れ子引用符 include、既存 `-iquote` ／`-I`・山括弧・異なる `cwd` での探索一致 (相対トレースを `runner` 基準で絶対化し具体的な 4 パスとも照合)、symlink の親ディレクトリ維持、`-I-` 等の無効化、標準 `obj/` の `resolve_app_deps.sh` 署名除外および `git check-ignore` による Git 無視確認の 7 つの PASS 出力 (全 28 件 PASS) を追加・分離しました。Git 無視確認は `.gitignore` または `git` が無い環境では `SKIP` を出力し、対照確認は `returncode == 1` のみを未無視と判定します。
- WSL (`OracleLinux8-Dev` / GCC 8.5.0 / Python 3.12.15) で `PYTHONDONTWRITEBYTECODE=1 PYTHONSAFEPATH=1 PYTHONWARNDEFAULTENCODING=1 PYTHONWARNINGS=error::EncodingWarning python3 -X warn_default_encoding -W error::EncodingWarning framework/makefw/bin_test/gcc_pch_selftest.py` を実行し、全 28 項目が `PASS` しました (`SKIP` なし)。
- 警告確認では、`check_warning` による `.warn` ファイル数 (`1`) と `"pch-marker"` 包含の自動検証に加え、WSL の一時ディレクトリで `check_warning` を単体実行して生成された `auto_*.warn` 全文を確認し、`common.h:2:2: 警告: #warning pch-marker [-Wcpp]` の 1 行のみが記録されていることを確認しました。
- `python3 app/general/bin/check-python-import-path.py framework/makefw/bin_internal/gcc_pch.py framework/makefw/bin_test/gcc_pch_selftest.py` を実行し、2 ファイルとも `OK` でした。
- 残課題一覧 (`backlog.md`) に記録すべき未解決残渣はありません。
