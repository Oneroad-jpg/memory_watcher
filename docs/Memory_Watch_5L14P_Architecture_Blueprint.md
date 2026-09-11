# Memory Watch 5 Layer / 14 Phase 設計図

状態：`DRAFT / NON_SSOT / NONBINDING`

`Memory Watch` は、この設計図の公開名です。既存の配布アプリとリポジトリは
引き続き `Memory Watcher` とし、この文書によってv0.3.3の名称や配布物は変更しません。

この設計図は、公開版Memory Watchの再構築だけを対象とします。Watchfulの現行設計文書を
変更、昇格、再解釈するものではありません。

## 解釈規則

5つのLayerと14個のPhase識別子を、完全な座標系として維持します。各Phaseには、
この製品で現在必要な場合に限って責務を定義します。使用しないPhaseはすべて
`UNDEFINED`のまま保持します。

この文書の`DEFINED`は、Phaseの責務が定義済みであることだけを意味します。
実装、build、実機インストール、受入、releaseの完了を意味しません。

## 5 Layerの対応表

| Layer | Phase | 定義状態 | 責務 |
|---|---|---:|---|
| L1 Foundation | F1 | DEFINED | バージョン付きMacリソース観測 |
| L1 Foundation | F2 | DEFINED | 意味状態解析ポートと決定的adapter |
| L2 Detection Core | D1 | DEFINED | 測定値から導出する注意状態 |
| L2 Detection Core | D2 | DEFINED | schema検証済み・来歴拘束済みsnapshot |
| L3 Runtime | R1 | DEFINED | 読取専用runtime projection |
| L3 Runtime | R2 | UNDEFINED | UNDEFINED |
| L3 Runtime | R3 | DEFINED | 決定的pipeline routing |
| L3 Runtime | R4 | UNDEFINED | UNDEFINED |
| L4 Product | P1 | UNDEFINED | UNDEFINED |
| L4 Product | P2 | DEFINED | MacとApple Watchへの状態表示 |
| L4 Product | P3 | DEFINED | 公開版のprivacy・機能方針 |
| L5 Platform Integration | PL1 | UNDEFINED | UNDEFINED |
| L5 Platform Integration | PL2 | DEFINED | 認証されたMac-to-Watch snapshot転送 |
| L5 Platform Integration | UI1 | DEFINED | 読取専用Apple Watch companion UI |

実行可能な表現は`MemoryWatcherArchitectureManifest.phases`です。テストでは、
Layerが正確に5個、Phase識別子が重複なく14個あること、すべての`DEFINED` Phaseに
空でない責務があること、すべての`UNDEFINED` Phaseに責務がないことを要求します。

## 責務の流れ

```text
F1 リソース観測
  -> F2 決定的な意味状態
  -> D1 測定値から導出した注意状態
  -> D2 schema・来歴の適格性確認
  -> R3 決定的route
  -> R1 読取専用projection
  -> PL2 認証済み転送
  -> P2 状態表示
  -> UI1 Watch UI

P3は公開版のprivacy・機能境界を制約する。
R2、R4、P1、PL1はUNDEFINEDのまま保持する。
```

Phaseラベルは所有と境界を示します。すべての接続が実装済みであることや、この図が
そのままruntime call stackであることは主張しません。

## 現在の契約

- `MemoryWatchResourceObservation`は、バージョン付きのF1測定値を運びます。
- `MemorySemanticAnalyzing`は、交換可能なF2 adapter境界です。
- `DeterministicMemorySemanticAnalyzer`だけを現在の解析器として結合します。
- `ResourceSemanticState`は、観測値、不確実性、来歴を保持します。
- `MemoryWatchPipeline`は、D2 snapshotを生成する前にF1入力とF2結果を検証します。
- `MemoryWatchSnapshot`は、端末間で共有する読取専用payloadです。
- `MemoryWatcherPublicEditionPolicy`は遠隔操作を禁止し、PL2がlive dataを運ぶ前に
  認証済みの転送経路を要求します。

拡張機構が生成した候補は、`MEASUREMENT_DERIVED`の権威を名乗れません。不正な
schema、割合、来歴の組合せは、snapshotを受け入れる前に拒否します。

## 現在の証拠と未解決境界

- 共有契約、決定的route、projection adapter、Watch UIのsourceは存在します。
- Swift packageのtest suiteは通過しています。
- 共有moduleとWatch UIは、watchOS SDKを直接用いたtypecheckを通過しています。
- PL2のlive transport実装と実機受入は確立していません。
- 通常のXcode Watch target buildは、ローカルXcodeがeligible watchOS destinationを
  提供していないため未観測です。

この設計図だけでは、署名、実機インストール、公開releaseの完了は成立しません。
