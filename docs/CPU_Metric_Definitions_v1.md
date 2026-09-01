# Memory Watcher CPU指標定義 v1

## 目的と適用範囲

工程13では、後続工程がCPUの意味を都合よく変更しないよう、取得元、差分式、
品質、保存単位、Activity Monitorとの比較境界を実装前に固定します。

対象はMac全体と論理CPU別の使用率です。GPU、プロセス別・アプリ別CPU、
物理コア判定、高性能・高効率コアの推測は対象外です。工程13はOSカウンターを
継続保存する工程ではなく、純粋な差分計算とその試験までを扱います。

## 公開APIとカウンター

macOS SDKで公開される次のMach APIと定義を使います。

| 対象 | 取得元 | 返される単位 |
|---|---|---|
| Mac全体 | `host_statistics(HOST_CPU_LOAD_INFO)` | 起動後の累積tick |
| 論理CPU別 | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` | CPU index別の累積tick |
| 状態 | `CPU_STATE_USER`・`SYSTEM`・`IDLE`・`NICE` | 各状態の累積tick |

根拠はmacOS SDKの `<mach/host_info.h>`、`<mach/processor_info.h>`、
`<mach/machine.h>` とします。`host_processor_info`が返す領域は取得側が
`vm_deallocate`で解放します。非公開フレームワークや外部通信は使いません。

- [Apple Open Source `host_info.h`](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/host_info.h)
- [Apple Open Source `processor_info.h`](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/processor_info.h)

## 計算式 `phase-13-v1`

前回値を `p`、今回値を `c` とし、各状態の差分を次のように求めます。

```text
Δuser   = c.user   - p.user
Δsystem = c.system - p.system
Δidle   = c.idle   - p.idle
Δnice   = c.nice   - p.nice

busyTicks  = Δuser + Δsystem + Δnice
totalTicks = busyTicks + Δidle
CPU使用率  = 100 × busyTicks ÷ totalTicks
```

Mac全体には全体カウンターの差分を使います。論理CPU別には各CPU indexの
カウンターへ同じ式を独立して適用します。Mac全体値を論理CPU使用率の単純平均で
作らず、全体のtick比を使います。したがってCPU使用率はMac全体・各論理CPUとも
0〜100%であり、論理CPU数を掛けた値にはしません。

`nice`はbusyへ含めます。user・system・nice・idleの差分tickと各割合も、
後から式を再計算できる形で保存する契約とします。

## 測定区間とUNKNOWN

- 目標周期は5秒とする。
- UTCの区間開始・終了と、単調増加するsystem uptimeの開始・終了を保存する。
- 有効な連続区間は実時間1秒以上15秒以下とし、実際の長さを保存する。
- 起動直後は差分の前回値がないため `firstDeltaUnknown` とする。
- sleep、wake、再起動、時計変更、CPU topology変更、取得不能をまたぐ差分は
  それぞれ理由付きUNKNOWNとし、0や直前値で埋めない。
- いずれかの累積カウンターが減少した場合はwrapを推測せず
  `counterRegression` とする。
- 全差分が0の場合は `noTickProgress`、加算が桁あふれする場合は
  `arithmeticOverflow` とする。
- wake、再起動、topology変更後は新しい基準値を取得し、次の正常な差分から
  測定値を再開する。

連続区間の範囲判定は工程14で実測時刻とともに実装します。工程13の純粋計算は、
境界種別を受け取った場合に必ず理由付きUNKNOWNを返します。

## 論理CPU indexとtopology

- 保存する `cpuIndex` はAPIが返す配列順の0始まりとする。
- 画面名は `CPU 1` のように1を加えた中立名とし、保存indexとの対応を示す。
- 取得時の論理CPU数と、再起動をまたいで混同しないtopology epochを保存する。
- 論理CPUと物理コアを同一だと断定しない。
- 高性能・高効率コア名は公開根拠と安定した対応付けを確認できない限り表示しない。
- CPU数が変化した場合、同じindexでも旧系列と新区間を接続しない。

## Activity Monitorとの差異表

| Memory Watcher | Activity Monitorでの照合先 | 照合できること | 保証しないこと |
|---|---|---|---|
| Mac全体CPU使用率 | CPU画面の `% Idle` から得る `100 - Idle` | 安定負荷区間の範囲・平均・変化方向 | 同一瞬間の完全一致 |
| user・system比率 | CPU画面の `% User`・`% System` | 大分類の傾向 | `nice`の内部分類までの一致 |
| 論理CPU別使用率 | `ウインドウ > CPUの履歴` | CPU別の活発・静穏の順序と変化傾向 | グラフ画像からの厳密な数値一致 |
| `CPU 1`等の表示 | CPU履歴の表示順 | 同じ取得周期内のindex対応 | 物理コア番号、性能・効率種別 |
| プロセスCPU | 比較対象なし | なし | アプリ別・プロセス別解析 |

工程17の直接照合は、静穏・通常・制御高負荷の各条件を15秒安定させた後、
5秒更新で6組以上を記録します。Memory Watcherの区間終了から1秒以内に
Activity Monitorを読み、時刻差も保存します。Mac全体使用率について、
両者の観測範囲が重なるか、平均差が5パーセントポイント以内なら数値条件を
PASSとします。どちらも満たさない差は説明で丸めずHOLDとします。

Activity Monitorの更新窓と公開APIの測定窓は完全同期しないため、単一の瞬間値を
完全一致条件にはしません。論理CPU別グラフに数値目盛りがない場合は傾向照合だけを
行い、Machカウンター差分の回帰テストと保存値読戻しを数値証拠とします。

## 容量・性能条件

保持対象は生データ24時間、1分・5分集約3日です。1系列あたり、生データ
17,280件、1分集約4,320件、5分集約864件となります。32論理CPUとMac全体の
33系列では最大741,312件です。

- 1・8・16・32論理CPUのfixtureを必須とする。
- 32論理CPUのCPU追加後を含む保持DB予測を128MiB以下とする。
- 32を超える実機では系列を切り捨てず、容量結果を未検証境界として記録する。
- 1回の全体・32論理CPU取得と変換はRelease版のp95で10ms以下を目標とする。
- 3日履歴の初期表示は2秒以内、最終24時間監査のアプリ平均CPUは1%未満とする。
- CPU追加後も通知、外向き通信、クラウド保存を0のまま維持する。

容量は工程15の実SQLite fixtureで再計算します。上限を超えた場合は閾値を
書き換えて通さず、schema・index・保持処理を見直すincidentとして停止します。

## 工程13の決定的試験条件

| 条件 | 期待結果 |
|---|---|
| 前回値なし | `firstDeltaUnknown` |
| idleだけ100tick増加 | 0% |
| busy 100、idle 100tick増加 | 50% |
| busyだけ100tick増加 | 100% |
| user 40、system 20、nice 40、idle 100 | 50%、内訳20%・10%・20%・50% |
| 合計busy 100、idle 300 | 全体25%。CPU別割合の単純平均を使わない |
| いずれかのカウンター減少 | `counterRegression` |
| 全カウンター差分0 | `noTickProgress` |
| sleep等の不連続境界 | 境界理由付きUNKNOWN |
| UInt64加算の桁あふれ | `arithmeticOverflow` |

不正値を0〜100%へclampして正常値に見せる試験は作りません。入力不整合の
正解は理由付きUNKNOWNです。
