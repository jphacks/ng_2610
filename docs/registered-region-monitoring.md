# 登録避難先の通知対象地域

ブランチ: `feat/registered-area-monitoring`。2026-10-25、main `8577b73` から作成。

## 利用手順

1. 自宅・学校の避難先を登録する。登録画面に地震・津波の地域候補が表示される。
2. 設定 → **通知対象地域**で各避難先の設定を確認・修正し、確認済みをオンにする。
3. 全ての登録先が確認済みになったら「自動監視を有効にする」をオンにし保存する。
4. 既存の接続設定でMacサーバーへ接続する。`npm run demo:server` とiPhoneの接続方法は従来と同じ。
5. 自動監視と手動デモは独立。自動監視は本番の全国WebSocketから556・552を受け、地域一致時だけ通知する。551では初動通知を出さない。

既存ユーザーにも同じ設定画面が表示される。設定追加前、未確認、地域未設定、登録先なしでは自動監視は無効。避難先の変更時は確認と有効化をやり直す。設定はhelloと5秒ごとの再同期でサーバーに反映する。

## 対応地域と根拠

単一のJSON `nigeyo-ios/Nigeyo/Resources/notification-regions-aichi.json` をNodeとiOSの双方で読む。愛知県54市町村に対応。確認日、バージョン、参照URLはJSONに保存。

- 地震: [気象庁・緊急地震速報や震度情報で用いる区域の名称](https://www.jma.go.jp/jma/kishou/know/jishin/joho/shindo-name.html)。府県予報区は **愛知**（「愛知県」ではない）、細分区域は「愛知県西部」「愛知県東部」。
- 津波: [気象庁・津波予報区の市町村対応表](https://www.jma.go.jp/jma/kishou/know/jishin/joho/tsunami-yohoku/tsunami_shichouson.pdf)。伊勢・三河湾の17市町村を明示。豊橋市・田原市は外海／湾内に分かれるため未設定とし、手動で生活圏の地域（両方も可）を選ぶ。
- 対応表に掲載されない市町村は `none`、判定できない住所・分割市町村は `unconfigured`。`none` は津波や浸水に対する安全判定ではない。必要なら確認画面で生活圏の予報区へ変更できる。
- 同名自治体を誤認しないよう、住所または自治体情報に「愛知県」が必要。市町村名は先頭・郡名直後の一致で識別し、住所内の任意部分一致はしない。住所と自治体情報が矛盾する場合は手動選択へ進む。
- [P2P公式仕様](https://github.com/p2pquake/epsp-specifications/blob/master/json-api-v2.yaml)の556 `areas[].pref/name`、552 `areas[].name/grade` に完全一致で照合。震度や震源距離による追加条件はない。

## 状態管理・配送

- サーバーは1本の全国WebSocketを利用し、installationIdごとに登録地域・地震更新番号・津波状態・未確認配送を `state/regional-monitor.json` へ原子的に保存してから送信する。
- 556は事象ID・数値の更新番号で順序を確認。対象外だった事象でも、後の更新で対象に追加されれば通知する。同一事象の2度目の通知は行わない。自宅・学校の一致は一つのコマンドの`matches`にまとめる。
- 556の新しい通知には発表後120秒・未来許容5秒の鮮度制限がある。到達予測時刻は使わない。この制限は試作の通知ポリシーで、津波警報の有効期限ではない。地震履歴は再送防止のため7日保持。
- 552は発表時刻で古い更新を除外。Watch → Warning → MajorWarningの強化で再通知。引き下げは状態更新。全域解除の `cancelled: true, areas: []` を地域照合前に処理する。地域の欠落・Unknownは不明状態とし、解除に変換しない。同時刻で内容が異なる552は、優先順位を推測せず後着分を採用しない。
- 取消・解除は新規の警報通知を出さない。明示的な取消・解除、津波の注意報への引き下げは古い警報ガイドを終了する。安全になったという通知は出さない。
- 通信断・時間経過では解除しない。アプリの設定画面には最新の受信状態を残す。`GET /api/status` の `monitoring` で接続・設定・状態・未確認数を確認できる。
- 配送は `regional-alert` / `regional-ack` の独立メッセージ。端末は状態と通知準備を原子的に保存し、通知を予約してからACKする。同じcommandIdの再送では二重予約しない。サーバーは未ACKを5秒ごとに再送する。
- sandboxや`test: true`を本番判定へ流さない。手動デモには従来の取得・fixtureフォールバックを残す。自動監視にはfixtureフォールバックを使わない。
- 通知本文は「登録先の地域」と自宅／学校・一致区域を示す。本人の現在地とは表現しない。注意報は海から上がり海岸から離れる案内、警報は沿岸・川沿いにいる場合の避難案内。

## UI担当への接続点

画面デザインの変更は不要。以下のサービスと単独のエディタを利用できる。

- `SettingsStore.region(for:)`: 登録済み地域または住所からの候補。
- `SettingsStore.notificationRegions`: 確認済み設定の保存先。slot（`home.earthquake`等）をキーにする。
- `SettingsStore.regionalMonitoringEnabled`: 利用者の有効化設定。
- `SettingsStore.regionalSubscription`: 未確認を含む場合は必ずenabled=falseになる送信用データ。
- `NotificationRegionsView`: 確認・手動変更・有効化・最新受信状態をまとめた独立画面。現在はSettingsViewからsheetで開く。
- `NotificationRegionSuggestion(site:)`: 登録画面に地域候補を表示する小さな部品。
- 保存後は `services.delivery.sendHello()` で即同期可能。定期同期も行う。
- `SessionMode.live`を追加。ガイド・Live Activityに訓練バッジを付けないため、既存UI内のモード判定のみ数か所変更。画面の配置は変更していない。

## 残る制約

既存の端末配送はデモ用WebSocketであり、APNsは追加していない。iOSがバックグラウンドで停止した状態での常時受信は保証されない。Xcode接続中の実機デモと、通常利用の常時受信を分けて扱う。

実情報の通知タイトルは `EARTHQUAKE_ALERT` / `TSUNAMI_ALERT` / `TSUNAMI_WATCH`。既存の `EARTHQUAKE_TEST` / `TSUNAMI_TEST` 用ショートカットはそのまま。実情報から壁紙も切り替える場合、iPhoneで警報用タイトルのオートメーションを追加する必要がある。注意報に警報用の避難ショートカットを割り当てない。

再接続時は保存済み未確認通知を再送するが、P2P切断中の欠落を履歴APIで回収する処理は今回含めていない。P2P自体も配信品質・再配信を保証しない。住所から施設の浸水リスクや避難場所の開設状況は判定しない。翻訳は既存3言語へ追加したが、母語話者の確認は別途必要。

## 検証

- `npm test`: 41件成功。既存デモ、地域判定、登録検証、順序・重複・取消、津波強化・解除、不明状態、再起動後の保持、実WebSocketのhello→配信→ACKを確認。
- iOSテスト34件成功。`xcodebuild -scheme Nigeyo -project nigeyo-ios/Nigeyo.xcodeproj -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO test`: 設定の移行・確認ゲート・変更時の無効化、実通知の保存・再起動・重複防止・注意報と警報の区別を確認。
