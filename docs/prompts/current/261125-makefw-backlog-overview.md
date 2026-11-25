<!--
生成元: agree-before-implement スキル
文書種別: 全体管理文書 (overview)
最終更新日時: 2026-11-26 03:40:00 JST
最終更新エージェント: claude code (主セッション session_01KJc53UFydnbt2gLXTJC1ZC)
稼働 OS: Linux (WSL)
上流文書: `261120-makefw-inject-source-switch-backlog.md` (BL-001)、`../../../../../app/general/docs/prompts/current/261123-remaining-backlog-items-backlog.md` (BL-002、BL-029、BL-030)。いずれも対策元の残課題一覧です。
下流文書: `261125-makefw-backlog-discussion.md` (検討用 Markdown)、`261125-makefw-backlog-lightadr.md` (簡易 ADR)、`261125-makefw-backlog-design.md` (最終仕様)、`261125-makefw-backlog-backlog.md` (残課題一覧)。未作成の場合や、削除されている場合があります。
再開手順: このファイルを開いたエージェントは、作業の前に agree-before-implement スキルを読み込んでください。この文書と、ユーザーが編集した最新の検討用 Markdown を読み直し、作業 WBS の `← **CURRENT**` の項目から再開します。最終更新エージェントのセッション情報や稼働 OS・最終更新日時が参照可能であれば再開時のコンテキストや環境差分の把握に利用し、別エージェントや別環境・別 OS からの引き継ぎ、担当変更によりセッションが見つからない場合も異常とせず、文書の記載から継続してください。`← **CURRENT**` の項目は処理が中止された項目である場合があり、どこまで進んでいたかは文書だけでは分かりません。対象成果物の内容を確認して実施済みの範囲を特定してから、作業を再開してください。`← **CURRENT**` がなく、作業 WBS がすべて完了 (✅) であれば、この案件の合意フローは完了しています。
-->

# makefw の残課題の対策 全体管理

ファイル名: `261125-makefw-backlog-overview.md`

この文書は、案件の識別、作業 WBS、対象範囲、確認状況、経緯を管理します。質問と回答の本文は検討用 Markdown (`261125-makefw-backlog-discussion.md`) に、決定事項は簡易 ADR (`261125-makefw-backlog-lightadr.md`) に記載し、この文書には重複して記載しません。

## 案件の識別

検討 ID: `261125-makefw-backlog`

検討用 Markdown の版: 3

状態: 作業の実施中 (第 2 ゲート通過済み)

## 作業 WBS と進捗管理

この案件の作業 WBS です。範囲の Q ([Q-001](261125-makefw-backlog-discussion.md#q-001-今回の案件で対策する残課題の範囲)) の回答により、対象外になる課題の項目 (4.1 から 4.4 は BL-001、4.5 と 4.6 は BL-029、4.7 は BL-030、4.8 は BL-002) は、見送りとして扱い、対策元の残課題一覧と当該案件の残課題一覧を更新します。

凡例: ⏸️ 未着手、🔄 実施中、🚫 ブロック中、⚠️ 要注意、✅ 完了。現在取り組んでいる項目の末尾に `← **CURRENT**` を付けます。

- 🔄 1. 検討用 Markdown のための情報収集と質問の実施
    - ✅ 1.1. 前提条件と要求事項の調査 (対策元 `261120-makefw-inject-source-switch-backlog.md` の BL-001、`261123-remaining-backlog-items-backlog.md` の BL-002、BL-029、BL-030 を「検討中」へ更新し、継続案件の開始を記録)
    - ✅ 1.2. 課題・論点の抽出と明確化のための確認項目 ([Q-001](261125-makefw-backlog-discussion.md#q-001-今回の案件で対策する残課題の範囲) から [Q-008](261125-makefw-backlog-discussion.md#q-008-bl-002-の対策の到達点)) の作成
    - ✅ 1.3. Q&A ターンごとのユーザー回答の受付と記録 (Q-001 から Q-008 の回答。回答者 Tetsuo Honda、2026-11-25 20:44:45 JST)
    - ✅ 1.4. 回答に基づく前提・制約の検証、簡易 ADR (`261125-makefw-backlog-lightadr.md` の LADR-001 から LADR-007) への決定事項の反映、対策元 2 件の `backlog.md` への合意方針の反映、この案件の `261125-makefw-backlog-backlog.md` の作成 (BL-001: `errors="replace"` の除去の見送り)
    - ✅ 1.5. 主エージェント経由の確認の実施
        - ✅ 1.5.1. BL-001 の make による再現確認 (事前再現 (a) から (d)、追加の実測 (e) から (h)、Q-002 の B の試作)
        - ✅ 1.5.2. BL-002 の Windows 側での再現 (「Windows 側への依頼手順 (BL-002)」の手順。2026-11-25 21:00 頃に主エージェントが依頼し、22:10 頃に結果を受領。再現せず。結果は、最終仕様の BL-002 の節への追記として 4.8.2 で扱う)
    - ✅ 1.6. 追加の確認項目 [Q-009](261125-makefw-backlog-discussion.md#q-009-逆向きの切り替わりで残る古いコピーの扱いの再確認) (逆向きの切り替わりの扱いの再確認) のユーザー回答の受付と記録 (選択肢 C。回答者 Tetsuo Honda、2026-11-25 21:01:31 JST。LADR-008 に記録し、Q-003 も解決済み)
- ✅ 2. 前提合意と残懸念の解消 (第 1 ゲート: 最終仕様作成への着手)
    - ✅ 2.1. 全論点に対する未解決事項および質問の解消確認 (Q-001 から Q-009 が解決済み。BL-002 の原因の特定は、Q-008 の回答で合意した手順と分岐で扱い、具体的な修正は Windows 側の結果の受領後に最終仕様へ追記する)
    - ✅ 2.2. 方針・前提条件の合意確定 (簡易 ADR の決定事項と、根拠となった解決済み Q の回答またはユーザーの明示的な指示との一致を確認し、懸念がないことをもってフェーズ 2 へ着手)
- ✅ 3. 最終決定事項 (最終仕様) の作成と承認の受付
    - ✅ 3.1. `261125-makefw-backlog-design.md` の作成 (対策元 `backlog.md` の確定方針・状態を随時反映。BL-001、BL-002、BL-029、BL-030 を「対応中」へ更新)
    - ✅ 3.2. 最終仕様における受入条件と整合性の確認 (LADR-001 から LADR-008 との一致、受入条件 AC-1 から AC-8 と検証手順の対応)
    - ✅ 3.3. 対話セッションにおける最終仕様 (design.md) の承認の受付 (第 2 ゲート: 作業着手の合意) (2026-11-25 21:48 頃のユーザーの指示「ユーザーの確認なく継続的に自走すること」「6. は他の案件同様 main へのコミットを事前許可する」により承認済みとして扱う。BL-002 の具体的な修正は承認の対象外で、Windows 側の結果の受領後に WBS 4.8.2 で追記して別途承認を受ける)
- 🔄 4. 承認された最終仕様に従った作業の実施
    - ✅ 4.1. `framework/makefw/makefiles/_collect_srcs.mk` の分類の変更 (外部のソースと同名のローカル実体の両 OS 共通の除外、置き換えを強制する名前の一覧の算出。BL-001、LADR-002、LADR-008)
    - ✅ 4.2. `framework/makefw/makefiles/makesrc_c_cpp.mk` の `generate_link_src_rule` と `generate_cp_src_rule` の変更 (BL-001)
    - ✅ 4.3. `framework/makefw/makefiles/makelibsrc_c_cpp.mk` の `generate_link_src_rule` と `generate_cp_src_rule` へ同じ変更 (BL-001)
    - ✅ 4.4. `framework/makefw/bin_test/source_classification_selftest.py` の期待値の変更と、切り替わりの確認 `check_source_switch` の追加 (BL-001、LADR-003)、`framework/makefw/docs/makeparts.md` の分類の節の更新 (LADR-008)
    - ✅ 4.5. `framework/makefw/bin_test/app_paths_selftest.py` (71、72、143 行目) の `encoding="utf-8"` の追加 (BL-029)
    - ✅ 4.6. `framework/makefw/bin_test/test_path_spaces.py` (123、156、174 行目) の `encoding="utf-8"` の追加 (BL-029、LADR-004。`errors="replace"` は残す)
    - ✅ 4.7. `framework/makefw/bin_test/test_path_spaces.py` の `test_environment_sync_preserves_paths` の飛ばす処理の追加 (BL-030、LADR-005)
    - ✅ 4.8. BL-002 の原因の特定と対策 (LADR-007)
        - ✅ 4.8.1. Windows 側の再現結果の受領と、仮説 H1 から H5 への当てはめ (再現せず。分岐「なし」)
        - ✅ 4.8.2. 最終仕様の BL-002 の節への具体的な修正内容の追記と、その節の承認の受付 (「確定した修正」に「コードは変更しない」を追記。分岐「なし」の扱いはユーザー確認だが、2026-11-25 21:48 頃のユーザーの指示「決定した最終仕様が実現できない場合は、ユーザーに問い合わせることなく backlog に送る」により、再発時の調査に残す残課題として BL-003 へ送った)
        - ✅ 4.8.3. 承認された修正と、`framework/makefw/bin_test/msvc_pch_selftest.ps1` への再現テストの追加 (Windows 側の Claude Code が実施し、主エージェントが結果を確認) (修正がないため対象外)
    - ✅ 4.9. 正本ドキュメントおよびコード コメントへの永続的知見の反映
    - ✅ 4.10. 局所テストおよび機械的検証 (最終仕様の「検証手順」の Linux の手順、Windows 側への依頼、`text_style_jp.py`) の実施
    - ✅ 4.11. 受入条件への適合確認 (全作業の完了確認) (AC-1 から AC-6、AC-8 に適合。AC-7 は修正がないため対象外。AC-2・AC-4 の Windows 側は、Windows 側の Claude Code の確認 (依頼 4) で適合)
    - ✅ 4.12. 簡易 ADR (`261125-makefw-backlog-lightadr.md`) の最終確認 (各決定が案件終了時点の決定を示し、経緯が時系列にそろっていることの確認)
    - ✅ 4.13. 残課題一覧 (`261125-makefw-backlog-backlog.md`) の再構築と整理 (今回対策しなかった項目の転記、対策元 2 件の最終状態・転記先の確定) (BL-001 から BL-003 の 3 件を残課題とし、整理済みにした。対策元: `261120-makefw-inject-source-switch-backlog.md` の BL-001 は対応済み、`261123-remaining-backlog-items-backlog.md` の BL-029、BL-030 は対応済み、BL-002 は転記済み)
- 🔄 5. 成果物の承認の受付 (第 3 ゲート)
    - 🔄 5.1. 成果物・検証結果・残課題の提示 ← **CURRENT**
    - ⏸️ 5.2. 対話セッションにおける成果物の承認の受付 (「承認」または「完了」の受領によるスキル完了)

## 対象と参照資料

依頼の源泉: ユーザーの指示 (2026-11-25 の対話)

> 消化可能なバックログを消化していきたい、各 prompt/current で対応可能な backlog を agree-before-implement スキルで推進します。サブエージェントには Sonnet を使用してください。また、Windows 側に Claude Code が待機しているので、疎通を取って連携して進めてください。

対象成果物: `framework/makefw` (独立した Git リポジトリのサブモジュール) の Make テンプレート、`bin_test` のテスト、補助スクリプト、文書

今回の対象範囲: 範囲の Q ([Q-001](261125-makefw-backlog-discussion.md#q-001-今回の案件で対策する残課題の範囲)) の回答で確定します。候補は次の 4 件です。

- BL-001: リンクからコピーへの切り替えで古いリンクが残り、`cp` が失敗する (`framework/makefw/makefiles/makesrc_c_cpp.mk`、`makelibsrc_c_cpp.mk`、`_collect_srcs.mk`)
- BL-029: `framework/makefw/bin_test` の Python の文字コード指定漏れ
- BL-030: `framework/makefw/bin_test/test_path_spaces.py` が統合ワークスペースの外で動かない
- BL-002: mock ヘッダー変更後の MSVC の差分ビルドで古いオブジェクトが残る (`framework/makefw/bin_internal/msvc_compile.ps1`、`find_dirty_srcs.sh`。Windows 側で調査・検証)

書き込み可能な検討文書: この文書、検討用 Markdown (`261125-makefw-backlog-discussion.md`)、簡易 ADR (`261125-makefw-backlog-lightadr.md`)、および対策元の残課題一覧 2 件 (状態、経緯、メタ情報の更新に限る)

参照資料と版 (2026-11-25 時点の作業ツリー、HEAD `9d37dce0`):

- `framework/makefw/docs/prompts/current/261120-makefw-inject-source-switch-backlog.md` (BL-001)
- `app/general/docs/prompts/current/261123-remaining-backlog-items-backlog.md` (BL-002、BL-029、BL-030)
- `framework/makefw/makefiles/_collect_srcs.mk`、`makesrc_c_cpp.mk`、`makelibsrc_c_cpp.mk`、`_path_functions.mk`、`_msvc_compile.mk`
- `framework/makefw/bin_internal/msvc_compile.ps1`、`_msvc_pch.ps1`、`find_dirty_srcs.sh`
- `framework/makefw/bin_test/` の Python テストと PowerShell テスト
- `app/general/docs/python-text-encoding-guideline.md` (Python の文字コード指定規範)
- `framework/makefw/docs/makeparts.md` (分類の節)
- `framework/makefw/AGENTS.md` (`bin_test` の規則)

事前再現の結果 (2026-11-25、主エージェントの依頼で、セッションの一時ディレクトリに makefw の `makefiles` と `bin_internal` を複製し、`ADD_SRCS` で外部のソース 1 本を引き込む合成のライブラリで確認。リポジトリは変更していません):

- (a) リンクで引き込んだ後に inject ファイルを追加すると、`cp: ... are the same file` で失敗します (`makelibsrc_c_cpp.mk:663`、終了コード 2)。
- (b) 古いリンクが残ったまま、inject の追加後にコピー元を編集すると、コピーの規則が起動せず、gcc と ar だけが走って成功します。引き込んだソースはリンクのままで、inject は注入されません。リンクの先の更新時刻がコピー元と同じになるためです。
- (c) 古いリンクが残ったままフィルター ファイル (`a.c.filter.sh`) を追加すると、`cat ... | sh a.c.filter.sh > a.c` のリダイレクトがリンクを辿り、コピー元 (`prod` 配下に相当する実体) が 0 バイトになります。make は警告なしで成功します。
- (d) inject ファイルを削除してコピーからリンクへ戻すと、古いコピーが `DIRECT_SRCS` として使われ続けます。その後にコピー元を編集しても反映されず、`make` は「行うべき事はありません」で終わります。

[Q-002](261125-makefw-backlog-discussion.md#q-002-bl-001-古いリンクへの対処方式) と [Q-003](261125-makefw-backlog-discussion.md#q-003-bl-001-の逆向きの切り替わりコピーからリンクの扱い) の **Context** で「読解による推定」としていた事象は、(b) から (d) のとおり実際に起きます。

追加の実測 (2026-11-25、Opus のサブエージェントが、セッションの一時ディレクトリに makefw の `makefiles` と `bin_internal` を複製し、テスト ディレクトリ `app/probe/test/src/probeTest/aTest` へ `TEST_SRCS` で外部の `a.c` と `b.c` を引き込む構成で確認。リポジトリは変更していません):

- (e) フィルター ファイルを削除してコピーからリンクへ戻すと、フィルターを通した古いコピーが使われ続け、コピー元を編集しても `make` は「'default' に対して行うべき事はありません」で終わります。
- (f) `TEST_SRCS` の inject ファイルを削除すると、古いコピーに残る `#include "a.inject.c"` のため、コンパイルが `fatal error: a.inject.c: No such file or directory` で失敗します。
- (g) `make clean` は、外部のソースと同名のファイルを分類によらず削除します。利用者が意図して置いた同名の実ファイルも削除されます。リポジトリには、外部のソースと同名の実ファイルをテスト ディレクトリで Git 管理している例はありません。
- (h) Q-002 の B の方式 (解析時の古いリンクの検出、再生成の強制、レシピの先頭の削除) を試作し、(a) から (c) が起きないこと、続けてのビルドで再生成が繰り返されないこと、`make -n` でファイルが変わらないことを確認しました。逆向きの切り替わりを Windows と同じ扱い (外部のソースと同名のローカル実体をリンクへ置き換える) にする試作も、動作を確認しました。

### Windows 側への依頼手順 (BL-002)

主エージェントが Windows 側の Claude Code へ依頼する手順です。対象成果物は変更せず、ヘッダーの一時的な変更は手順の最後に元へ戻します。Git の書き込み操作は行いません。ほかの `make` を同時に実行しないでください。

1. 前提をそろえる: 統合リポジトリを `9d37dce0` 以降、`framework/makefw` を `a278234` 以降にし、Git Bash でリポジトリのルートに移動します。
2. 基準を作る: `make -C app/cplat clean` の後に `make -C app/cplat` を実行し、成功を確認します。
3. 変更前を記録する: 次を保存します。
    - `app/cplat/test/libsrc/mock_cplat/obj/` の一覧 (オブジェクトのディレクトリ名の確認。以下では `obj/md` と仮定)
    - `app/cplat/test/libsrc/mock_cplat/obj/md/mock_cplat_expand_format.d` と `mock_cplat_expand_format.cc.json`
    - `find app/cplat -name 'auto_*.pch*'` の結果と、`mock_cplat_expand_format.cc` が使う PCH の `.pch.deps.json` と `.pch.json`
    - `ls -l --time-style=full-iso` による、`app/cplat/test/include/mock_cplat.h`、`mock_cplat_expand_format.obj`、`.d`、`.pch` の更新時刻
    - `make -C app/cplat/test/libsrc/mock_cplat --eval 'makefw-print-ws: ; @echo $(WORKSPACE_DIR)' makefw-print-ws` の出力 (`WORKSPACE_DIR` の表記)
4. 更新時刻だけを進める (H1 から H4): `touch app/cplat/test/include/mock_cplat.h` の後、`app/cplat/test/libsrc/mock_cplat` で `bash ../../../../../framework/makefw/bin_internal/find_dirty_srcs.sh "mock_cplat.cc mock_cplat_expand_format.cc" obj/md "<手順 3 の WORKSPACE_DIR>"` を実行し、出力を保存します。続けて `make -C app/cplat/test/libsrc/mock_cplat -n` と `make -C app/cplat` の出力を保存し、手順 3 の更新時刻を取り直します。
5. 内容を変えて元の事象を再現する (H5): `mock_cplat.h` を一時ディレクトリへ複製して控え、Windows 専用の `MOCK_CPLAT_LINK_IMPL(...)` の並びの末尾に `MOCK_CPLAT_LINK_IMPL(makefw_bl002_probe)` を 1 行加えます。`make -C app/cplat` を実行すると、作り直されたオブジェクトが `/INCLUDE:_mock_impl_makefw_bl002_probe` を持つため、`LNK2001` で失敗するのが期待どおりです。
6. 元に戻して確認する: 控えたファイルで `mock_cplat.h` を戻し (`cmp` で一致を確認)、`make -C app/cplat` を実行します。`_mock_impl_makefw_bl002_probe` の `LNK2001` が残れば BL-002 の再現です。その場合は `grep -l -a _mock_impl_makefw_bl002_probe $(find app/cplat -name '*.obj' -o -name '*.pch')` で、古いまま残ったファイルを特定します。手順 3 の記録も取り直します。
7. 後始末: 成功しない場合は `make -C app/cplat clean` の後に `make -C app/cplat` を実行し、成功を確認します。

持ち帰るデータ: 手順 3、4、6 の各ファイルの内容と更新時刻、`find_dirty_srcs.sh` の出力、`make -n` と `make` の出力 (再コンパイルされたソースの一覧と `LNK2001` の有無)、手順 6 の `grep` の結果。

## 観点別の確認

| 観点 | 状態 | 根拠・関連 Q |
| --- | --- | --- |
| 目的・利用者 | 確認済み | [Q-001](261125-makefw-backlog-discussion.md#q-001-今回の案件で対策する残課題の範囲) (4 件すべてを対策) |
| 範囲・境界 | 確認済み | [Q-009](261125-makefw-backlog-discussion.md#q-009-逆向きの切り替わりで残る古いコピーの扱いの再確認) (逆向きの切り替わりも makefw で扱う)。Windows の逆向きの切り替わりは範囲外として残課題一覧の BL-002 に記録。[Q-005](261125-makefw-backlog-discussion.md#q-005-bl-029-で-errorsreplace-の指定も直すか)、[Q-006](261125-makefw-backlog-discussion.md#q-006-bl-030-の-bin_test-を単独の作業ツリーでどう扱うか) は確認済み |
| 入力・根拠 | 確認済み | 対策元の残課題一覧 2 件、`makefiles/` と `bin_internal/` のソース、`bin_test` の静的走査、規範、一時ディレクトリでの実測 (a) から (h)。BL-002 の原因は Windows 側の調査で特定する方針 ([Q-008](261125-makefw-backlog-discussion.md#q-008-bl-002-の対策の到達点)) |
| 整合性・依存関係 | 確認済み | [Q-009](261125-makefw-backlog-discussion.md#q-009-逆向きの切り替わりで残る古いコピーの扱いの再確認) (外部のソースと同名のローカル実体の判定を両 OS で共通化)。[Q-002](261125-makefw-backlog-discussion.md#q-002-bl-001-古いリンクへの対処方式) (ドライ ランの無副作用)、[Q-005](261125-makefw-backlog-discussion.md#q-005-bl-029-で-errorsreplace-の指定も直すか) (規範との関係) は確認済み |
| 実現性・例外 | 確認済み | [Q-002](261125-makefw-backlog-discussion.md#q-002-bl-001-古いリンクへの対処方式) の B と、Q-009 の案 C を試作で確認 (実測 (h))。BL-002 は Windows 側でのみ検証でき、修正の規模が大きい場合は報告時に範囲を再確認する ([Q-008](261125-makefw-backlog-discussion.md#q-008-bl-002-の対策の到達点)) |
| 受入条件・検証 | 確認済み | [Q-004](261125-makefw-backlog-discussion.md#q-004-bl-001-の再現テストの置き場所)、[Q-007](261125-makefw-backlog-discussion.md#q-007-bl-029-と-bl-030-の受入検証の範囲)、[Q-009](261125-makefw-backlog-discussion.md#q-009-逆向きの切り替わりで残る古いコピーの扱いの再確認)。BL-002 の受入条件は、最終仕様の分岐ごとの条件で定める |

## 質問一覧

各 Q の本文は検討用 Markdown にあります。Q-ID には検討用 Markdown の該当見出しへのリンクを設けます。

| Q-ID | 論点 | 状態 | 依存・関連 | 反映先の決定 |
| --- | --- | --- | --- | --- |
| [Q-001](261125-makefw-backlog-discussion.md#q-001-今回の案件で対策する残課題の範囲) | 今回の案件で対策する残課題の範囲 | 解決済み | Q-002、Q-005、Q-006、Q-008 | LADR-001 |
| [Q-002](261125-makefw-backlog-discussion.md#q-002-bl-001-古いリンクへの対処方式) | BL-001 古いリンクへの対処方式 | 解決済み | Q-001、Q-003、Q-004 | LADR-002 |
| [Q-003](261125-makefw-backlog-discussion.md#q-003-bl-001-の逆向きの切り替わりコピーからリンクの扱い) | BL-001 の逆向きの切り替わり (コピーからリンク) の扱い | 解決済み (Q-009 で決着) | Q-002、Q-004、Q-009 | LADR-008 |
| [Q-004](261125-makefw-backlog-discussion.md#q-004-bl-001-の再現テストの置き場所) | BL-001 の再現テストの置き場所 | 解決済み | Q-002、Q-003、Q-009 | LADR-003 |
| [Q-005](261125-makefw-backlog-discussion.md#q-005-bl-029-で-errorsreplace-の指定も直すか) | BL-029 で errors="replace" の指定も直すか | 解決済み | Q-001、Q-007 | LADR-004 |
| [Q-006](261125-makefw-backlog-discussion.md#q-006-bl-030-の-bin_test-を単独の作業ツリーでどう扱うか) | BL-030 の bin_test を単独の作業ツリーでどう扱うか | 解決済み | Q-001、Q-007 | LADR-005 |
| [Q-007](261125-makefw-backlog-discussion.md#q-007-bl-029-と-bl-030-の受入検証の範囲) | BL-029 と BL-030 の受入検証の範囲 | 解決済み | Q-005、Q-006 | LADR-006 |
| [Q-008](261125-makefw-backlog-discussion.md#q-008-bl-002-の対策の到達点) | BL-002 の対策の到達点 | 解決済み | Q-001 | LADR-007 |
| [Q-009](261125-makefw-backlog-discussion.md#q-009-逆向きの切り替わりで残る古いコピーの扱いの再確認) | 逆向きの切り替わりで残る古いコピーの扱いの再確認 | 解決済み | Q-002、Q-003、Q-004 | LADR-008 |

## 対象成果物と合意版

最終決定事項 (最終仕様) の設計書: `261125-makefw-backlog-design.md`

検討用 Markdown の合意版 (第 1 ゲート): 版 3 (Q-001 から Q-009 が解決済み。2026-11-25 に確定)

最終仕様 (design.md) の合意版 (第 2 ゲート): 承認済み (2026-11-25 21:48 頃のユーザーの指示による。BL-002 の具体的な修正は承認の対象外)

更新予定の成果物: 最終仕様 (`261125-makefw-backlog-design.md`) の「変更対象」に記載します。

受入条件: 最終仕様の「受入条件」に記載します。

## 経緯

案件の進行上の出来事 (案件の開始、ゲートの通過、最終仕様の否決と差し戻し、方針の変更、作業 WBS の見直し、作業の中断と再開など) を、発生順に末尾へ追記します。個々の決定の内容は簡易 ADR に記載し、ここには出来事と参照先だけを記載します。

| 日時 (JST) | 出来事 | 内容・参照先 |
| --- | --- | --- |
| 2026-11-25 20:50 | 案件の開始 | 全体管理文書と検討用 Markdown (Q-001 から Q-008) を作成。対策元の BL-001、BL-002、BL-029、BL-030 を「検討中」へ更新 |
| 2026-11-25 20:42 | 事前再現の実施 | 一時ディレクトリでの make による再現 (a) から (d) を「対象と参照資料」に記録。Q の定義は変更していません |
| 2026-11-25 20:44 | ユーザーの回答の保存 | Q-001 から Q-008 の回答 (検討用 Markdown の保存時刻) |
| 2026-11-25 20:59 | 回答の検証と追加の確認項目 | Opus のサブエージェントが回答を検証し、LADR-001 から LADR-007 を記録。対策元 2 件の残課題一覧へ方針を反映し、この案件の残課題一覧 (BL-001) を作成。追加の実測 (e) から (h) を記録。Q-003 の Context が実測の結果を十分に伝えていなかったため、ユーザーの指示 (2026-11-25 の対話「Sonnet の掘り下げが浅いものは、書き直したり再質問をユーザーに行ってもよいです」) に基づき Q-009 を追加し、検討用 Markdown を版 2 に更新 |
| 2026-11-25 21:00 | Windows 側への依頼 | 主エージェントが BL-002 の再現を Windows 側へ依頼 (WBS 1.5.2) |
| 2026-11-25 21:01 | ユーザーの回答の保存 | Q-009 の回答 (検討用 Markdown の保存時刻) |
| 2026-11-25 21:05 | 第 1 ゲートの通過 | Q-009 の回答を検証して LADR-008 を記録し、Q-003 を解決済みに更新 (検討用 Markdown 版 3)。BL-002 の具体的な修正は Windows 側の結果の受領後に最終仕様へ追記する扱いとし、作業 WBS の 4.8 を 3 項目に分割。Windows の逆向きの切り替わりの懸念を、この案件の残課題一覧の BL-002 に記録 |
| 2026-11-25 21:07 | 最終仕様の作成 | `261125-makefw-backlog-design.md` を作成し、対策元の BL-001、BL-002、BL-029、BL-030 を「対応中」へ更新。第 2 ゲートの承認待ち |
| 2026-11-25 21:48 | 第 2 ゲートの通過 | ユーザーの指示「ユーザーの確認なく継続的に自走すること」「6. は他の案件同様 main へのコミットを事前許可する」により、最終仕様を承認されたものとして扱い、作業 WBS 4 へ着手 (BL-002 の具体的な修正は対象外) |
| 2026-11-26 01:15 | BL-001、BL-029、BL-030 の実施の完了 | WBS 4.1 から 4.7、4.9、4.10 を完了。BL-002 (WBS 4.8) は Windows 側の再現結果の待ちのため着手せず、4.8 と 4.11 以降は未着手のまま (Sonnet サブエージェントの実施) |
| 2026-11-26 01:35 | BL-002 の扱いの確定 | Windows 側の再現結果 (2026-11-25 22:10 頃に受領) を仮説に当てはめ、再現しないと判定。最終仕様の「確定した修正」に追記し、自走の指示により再発時の調査に残す残課題 (BL-003) へ送った。対策元の BL-002 を「転記済み」へ更新 |
| 2026-11-26 02:05 | Windows の確認での不適合と修正 | Windows 側の確認 (依頼 4) で、`source_classification_selftest.py` が、同名のローカル実体がコピーへ置き換わることの確認で失敗。Windows ではコピーした実体と区別できず、置き換えの強制は最終仕様でも Linux だけのため、テストの Windows の期待値 (外部のソースの更新後に置き換わる) と `makeparts.md` と最終仕様の文面を直した。Linux で再実行して成功 |
| 2026-11-26 03:40 | Windows 側の確認の完了 | 依頼 4 の結果: `make -C app/cplat` と `make -C app/cplat test` が成功 (gtest の失敗 0 件、成功 2,115 件、所要約 2 時間 10 分)、内容のある `.warn` は 0 件 (makefw d08551f)。`source_classification_selftest.py` は ad04f21 で成功し、`check_source_switch` は `SKIP:`。WBS 4.11 を完了 |

## 反映と検証の記録

### 対応箇所 (BL-001、BL-029、BL-030)

- `framework/makefw/makefiles/_collect_srcs.mk`: 外部のソースと同名のローカル実体を `DIRECT_SRCS` から外す分類 (`EXTERNAL_SRCS`) を両 OS 共通にし、Linux の `_MAKEFW_FORCED_COPY_TARGETS` と `_MAKEFW_FORCED_LINK_TARGETS` を追加。走査結果の変数は `_SOURCE_LINK_NAMES` へ改名
- `framework/makefw/makefiles/makesrc_c_cpp.mk`、`makelibsrc_c_cpp.mk`: `_makefw_force_placement` の追加、`generate_link_src_rule` と `generate_cp_src_rule` の前提条件の追加、コピーの規則の先頭への `@rm -f $(1)`
- `framework/makefw/bin_test/source_classification_selftest.py`: ローカル実体の期待値の変更、`check_source_switch` (段階 1 から 8、ライブラリと実行体) の追加
- `framework/makefw/docs/makeparts.md`: 外部ソースの節、分類の表、切り替わりの追記
- `framework/makefw/bin_test/app_paths_selftest.py` (3 か所)、`test_path_spaces.py` (3 か所): `encoding="utf-8"` の追加。`test_path_spaces.py` に、統合ワークスペースのファイルがない場合の `skipTest` と、定数 `SYNC_SCRIPT`、`SYNC_VSCODE_FILES` を追加

### 検証結果 (Linux)

- `source_classification_selftest.py`: 成功 (`check_source_switch` の段階 1 から 8 が、ライブラリと実行体の両方で成功。AC-1 から AC-3)
- `framework/makefw/bin_test/*.py` の全 17 本: `python3 -X warn_default_encoding -W error::EncodingWarning` で成功。構文木の走査で、`encoding` のないテキスト入出力は 0 件 (AC-5)
- `test_path_spaces.py`: 統合ワークスペースでは `test_environment_sync_preserves_paths` が成功 (飛ばされるのは Windows 専用の 1 件だけ)。`framework/makefw` だけを複製した場所では、理由付きで飛ばされる (AC-6)
- `make -C app/cplat`: 成功、内容のある `.warn` なし
- `make -C app/cplat test`: 初回は `socketTest` のリンクが失敗 (`Mock_eventfd` が未定義。`framework/testfw/lib/linux_el8_x64/libmock_libc.a` が古かったため。`make -C framework/testfw` で再生成して解消)。次に、`cryptoTest`、`randomTest`、`symLoaderInitTest` のモックが効かず失敗 (`libmock_openssl.a` と `libmock_cjson.a` が古かったため。`make -C app/cjson` と `make -C app/openssl` で再生成して解消し、3 件の個別実行が成功)。いずれも提供元の成果物が古かったことが原因で、この変更とは無関係 (AC-4 の Linux 側)
- `text_style_jp.py --dry-run`: `makeparts.md` は指摘なし (AC-8)

### 検証結果 (Windows)

- `source_classification_selftest.py` (ad04f21): 成功。分類は `DIRECT=0 COPY=80 LINK=0`、`check_source_switch` は `SKIP:` (AC-2)
- `make -C app/cplat` と `make -C app/cplat test` (d08551f): 成功。gtest の失敗 0 件、内容のある `.warn` 0 件 (AC-4)

### 未完了項目

- BL-002 (WBS 4.8): 再現しなかったため、修正はなし。この案件の残課題一覧の BL-003 へ送った
- WBS 4.11 以降
