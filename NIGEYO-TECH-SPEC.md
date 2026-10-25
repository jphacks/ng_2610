# Nigeyo 技術仕様書 v1.1

> **実装差分（2026-10-25 / bundled-shortcut-onboarding）**：ロック画面の準備UIは4ステップ（通知許可・地震/津波の追加・自動実行・壁紙の手動確認）に統一。署名済みショートカット2本をiOSリソースへ同梱し、初期設定は配布URL・デモ接続・Macサーバーに依存しない。iOSのファイル受け渡し画面から利用者が追加し、対象Nigeyoの再選択と自動実行の有効化を行う。進捗は利用者の確認記録として保存する。通知起点のロック中動作は別の実機確認項目とする。

> **実装差分（2026-10-25 / local-hazard-shortcuts）**：壁紙・ショートカット・複数接続についてはこの差分と `docs/shortcuts.md` が従来の記述に優先する。地震・津波のショートカットに承認済みPNGを直接同梱する。通知実行時はローカルでデコードし、サーバーから画像を取得しない。タイトル `EARTHQUAKE_TEST` / `TSUNAMI_TEST` で通知オートメーションを分け、そのネイティブトリガーを配布ファイルのWFWorkflowTriggersに同梱する。インポート後は各自が有効化・対象アプリ確認を行う。旧共通画像URLは410。デモサーバーは複数接続を許可し、接続ごとにcontroller・run・ACK・再送・津波観測を分離する。複数接続時の操作APIは明示的なdeviceIdが必須。iPhoneの画面・共通通信JSONは変更しない。地震551の位置連動による本番自動配信はこの変更の対象に含まない。


更新日：2026-10-25（初版：2026-10-24）

改訂内容：音声案内を削除、追加可能なJSON言語パッケージ、Live Activity、津波通知・壁紙切替、ショートカット簡単導入を追加。今回の更新は仕様設計であり、これらの機能を実装・実機検証済みという意味ではない。

この文書は、Codex・Claudeなどの実装AIへ添付する実装指示書である。対象はハッカソン発表用のSwift iPhoneアプリとMac上のデモサーバー。将来の一般配布用アプリとは完成条件を分ける。本書の「実装する」は要求仕様であり、実装済みという意味ではない。

## 1. 完成条件と固定方針

### 1.1 最優先の実演

1. MacのXcodeから実機のNigeyoを起動し、デバッガー接続を維持する。
2. iPhoneをロックし、PC画面で受信側の生存報告を確認する。
3. 発表者がPCの「地震情報を取得してデモ開始」を押す。
4. サーバーが実際のP2P地震情報APIへリクエストし、取得結果をiPhoneへ送信する。API障害時は本書の自動フォールバックを適用する。
5. Swiftの受信処理が案内状態を保存し、自作アプリのローカル通知を出す。
6. 設定済みiOSショートカットが、地震用ロック画面への壁紙変更、Nigeyoを開く処理を行う。音声案内は行わない。
7. ユーザーが安全に操作できる状態でロック解除すると、アプリ内の「身を守る」画面へつながる。
8. 前景で開始したLive Activityを次のロック画面で表示し、揺れの確認→3枚の安全確認ピクトグラム→アプリ内の場所選択へつなぐ。津波通知時は津波画像・津波案内へ優先更新する。
9. 避難経路の案内はGoogle Mapsの外部リンクへ引き渡す。アプリ内ナビゲーションは実装しない。

### 1.2 本改訂で確定する方針

- iOSアプリはSwift・SwiftUIで作る。Capacitor・WebViewは完成版に使わない。
- 実装対象iOSは27.0以上。チームの基準Xcodeは27.1。Mac側はNode.js 24。
- ピクトグラムは地震時の頭の保護、周囲の安全確保、火の始末、扉を開ける、津波・高台避難の5行動を用意する。全言語で同じ行動IDの画像を共有する。
- 音声案内を廃止する。アプリ・ショートカットとも読み上げ・音声ファイル・音声プレーヤーを持たない。VoiceOver対応とOS標準の短い通知音は別扱い。
- Live ActivityをActivityKit・WidgetKit拡張・App Intentsで実装する。通常のホーム画面Widget、APNs、Firebase、PWA、ログイン、外部DB、実行時の翻訳APIは対象外。
- 初期同梱言語は英語・日本語・韓国語。言語は追加可能なJSONパッケージで管理し、コードのenumに固定しない。デフォルトは英語。
- 地図表示・場所検索・初期設定時の徒歩距離計算はMapKit。経路案内への移動はGoogle Maps URL。
- Macの1サーバーでPC操作画面、iPhone接続、壁紙・言語パッケージ・ショートカット配信を扱う。
- 現在の確認済みデモ経路を、アプリを通常起動したときの常時バックグラウンド受信として説明しない。
- アプリ内訓練は地震APIへアクセスしない。PCデモだけが本番APIを取得する。
- APIの元情報と、デモとして選ぶ展開を混同しない。実地震の時刻を書き換えない。

### 1.3 確認済みの土台

既存の検証では、実際の本番API取得、Swift側WebSocket受信、ロック中の通知、ショートカットによる背景変更が成功した。現行の検証アプリはCapacitorの器にSwift受信処理を追加したもの。完成版は純Swiftアプリで同じ試験を行う。

ショートカットの解除後の起動、新タイトルの分岐、Live Activityの開始・操作・終了は、完成版アプリとの結合試験に含める。津波専用通知からLive Activityまでの全経路も未検証として扱う。iOSの認証を省略・自動解除する処理は作らない。OSが解除や追加操作を要求した場合、それを受入試験記録に残す。

## 2. システム構成と採用技術

```text
Macの操作画面（localhost）
  → Node.jsデモサーバー
    → P2P地震情報history API
    → 失敗時は保存済みの実データ
  → WSS（Cloudflare Tunnel）
  → iPhone: URLSessionWebSocketTask
  → GuideSessionを保存
  → UNUserNotificationCenterでローカル通知
  → iOSショートカット: 災害種別の壁紙 → Nigeyoを開く（必要なロック解除はOSに従う）
  → SwiftUIの同じGuideSessionから案内
  → 前景でActivity.request → 次のロック画面でLive Activity
  → LiveActivityIntentで安全確認へ更新／アプリへディープリンク
  → 避難場所を提示 → Google Maps外部リンク
```

| 領域 | 採用 |
| --- | --- |
| UI | SwiftUI、NavigationStack、Observation |
| アプリライフサイクル | SwiftUI App、UIApplicationDelegateAdaptor |
| 通信 | Foundation URLSessionWebSocketTask、async/await |
| 通知 | UserNotifications、UNUserNotificationCenterDelegate |
| Live Activity | ActivityKit、WidgetKit拡張、SwiftUI ActivityConfiguration、LiveActivityIntent |
| 言語 | BCP 47のLanguageID、JSON言語パッケージ、検証済みローカルキャッシュ |
| 共有モデル | Foundation Codable、明示的なenum、UUID |
| 軽い設定 | UserDefaults |
| 案内状態 | Application Support内の原子的JSON保存 |
| 避難場所 | アプリ同梱の正規化JSON、専用actorで検索 |
| 位置情報 | CoreLocation、使用中のみの許可 |
| 地図 | MapKit、MKLocalSearch、MKLocalSearchCompleter、MKDirections |
| サーバー | Node.js 24 ESM、node:http、ws |
| PC画面 | HTML・CSS・標準JavaScript。フロントエンドフレームワーク不要 |
| 公開接続 | Cloudflare Tunnel、HTTPS/WSS |
| テスト | Swift Testing、必要箇所のXCTest UIテスト、node:test |

Swift側の外部パッケージは追加しない。Nodeの既存依存は再利用し、CSV変換にcsv-parseを開発用依存として追加する。バージョンはpackage-lock.jsonで固定する。新たな認証サービス・監視基盤・クラウドDBを作らない。

## 3. リポジトリと2人の担当

既存検証コードを残し、純Swiftアプリは新しいnigeyo-ios/以下に作る。既存ios/・native-test/・B1〜B4の検証を削除しない。

```text
contracts/                      共通JSON契約・サンプル・検証用JSON Schema
nigeyo-ios/Nigeyo.xcodeproj      完成版の唯一のXcodeプロジェクト
nigeyo-ios/Nigeyo/
  App/                          起動・ルーティング・依存注入
  Contracts/                    共通Codableモデル
  Delivery/                     Swift受信・通知・接続診断
  Session/                      案内状態の保存・公開
  Features/                     初期設定・ホーム・案内・設定・地図
  Services/                     MapKit・現在地・避難場所検索
  Resources/                    cards.json、Languages/*.json、画像、避難場所
nigeyo-ios/NigeyoLiveActivity/   Live Activity専用WidgetKit拡張・画像カタログ
nigeyo-ios/Shared/               ActivityAttributes、ContentState、共有行動ID
nigeyo-ios/NigeyoTests/
server/demo/                    完成版デモサーバー
public/demo/                    PC操作画面
assets/                         原本画像・言語パッケージ・共有JSON
assets/languages/               en.json、ja.json、ko.json、後から追加する言語
assets/shortcuts/               署名済みショートカット・導入manifest
fixtures/demo/                  準備済みの実APIレスポンスと取得メタデータ
scripts/                        素材検証・データ変換・デモ事前確認
docs/                           起動手順・署名・ショートカット設定・受入試験
```

### 3.1 担当境界

| 担当A：通知まで | 担当B：アプリとその後 |
| --- | --- |
| server/demo/、public/demo/ | App/、Features/、Services/ |
| API取得、フォールバック、ログ | 初期設定、言語、避難場所、地図 |
| Delivery/のSwift通信・通知 | Session/と案内ルーティング |
| 接続、heartbeat、ACK、重複防止 | cards.json・Languages/*.json・行動画像・Live Activityの管理 |
| アセット配信のHTTP処理 | ショートカット設定手順と素材の受け渡し |
| 通信と通知のテスト | 画面遷移・検索・保存のテスト |

- 最初に共通モデルとcontracts/を確定する。契約の変更は相手側の利用箇所・テスト・文書と同時に更新する。
- AはBが提供するSessionStoreのインターフェースを呼ぶ。画面ファイルを直接操作しない。
- Bは受信完了を待たず、契約に準拠したローカルのMockDeliveryServiceで画面を開発する。
- Xcodeプロジェクト作成とプロジェクト設定ファイルの所有者はB。AはDelivery/を担当し、プロジェクト全体を別に生成しない。
- フォルダはXcodeのファイルシステム同期グループを使用し、新規Swiftファイルごとのプロジェクト編集を減らす。
- 2人は別ブランチ・別Macで作業する。短い単位で統合し、毎回相手側でビルドする。
- 開発中はそれぞれのMacでサーバーを起動できる。1台のサーバーに複数のiPhoneを同時接続し、接続別のdeviceIdで送信先を指定できる。
- 発表用のMac・iPhone・Bundle ID・ショートカットを固定し、その端末で最終リハーサルする。

### 3.2 署名

基準Bundle IDはjp.nigeyo.hackathon。開発者ごとの接尾辞をLocal.xcconfigで付けられる構造とする。署名チームと開発者別Bundle IDはGit管理しない。Local.xcconfig.exampleは同梱し、両Macで設定できるようにする。発表用Bundle IDは初回のショートカット設定前に固定する。再インストール・Bundle ID変更後は通知対象を再設定する。

## 4. ドメインモデルと不変条件（契約v2）

### 4.1 最小限のモデル

- LanguageID：BCP 47文字列を包むCodable型。利用可能な言語はLanguageRegistryから取得。初期値en・ja・ko、新言語追加でSwiftコードを変更しない。
- SessionMode：demo、training、manualのみ。実災害の本番自動配信モードは実装しない。
- DemoSource：live-api、last-good、fixture、local、manual。
- Scenario：earthquake、earthquake-tsunami。後者はデモ・訓練の演出指定であり、APIから推測しない。
- GuidePhase：protect、safety-checks、tsunami-evacuate、choose-place、show-destination、completed。safety-checksは安全確保・火の始末・扉の確保を同時表示する単一状態。
- Hazard：earthquake、tsunami。
- PlaceContext：home、university、other。

GuideSessionはsessionId、mode、source、language、scenario、quake、phase、hazard、startedAt、updatedAt、completedAt、selectedPlaceContext、candidateDestinationIds、selectedDestinationId、notificationScheduledFor、languagePackageVersion、languageSnapshot、stateRevision、lastHazardRevision、lastTsunamiEventId、tsunami、evacuationDecision（undecided／going）、liveActivityId、liveActivityStatusを持つ。言語スナップショットは開始時の検証済みパッケージの必要文言を保存する。sessionIdはPCのrunIdと同じUUID。quakeはAPI由来の元情報であり、アプリ内訓練と手動開始ではnullにする。開始時の選択値はnull、候補IDは空配列。選択した公開施設IDとphaseを同時に保存し、再起動でshow-destinationへ戻ったときにも施設を再表示できるようにする。現在地の座標はセッションに永続化しない。

地震開始はphase=protect、hazard=earthquake。津波はユーザーの揺れ確認とは独立したhazard-updateで、同じsessionIdをhazard=tsunami、phase=tsunami-evacuateへ優先更新する。揺れ確認ボタンを待たない。scenario=earthquake-tsunamiは訓練用の別津波イベント投入を予約する設定であり、地震APIから津波発生を推測する値ではない。独立の津波訓練開始では最初からtsunami-evacuateとし、未開始のLive Activityは次の前景化で開始する。

### 4.2 QuakeSummary

```json
{
  "sourceEventId": "6adc2a51e88ee598246bf418",
  "code": 551,
  "occurredAt": "2026-10-24T12:44:00+09:00",
  "issuedAt": "2026-10-24T12:47:28+09:00",
  "hypocenterName": "陸奥湾",
  "magnitude": 2.9,
  "maxScale": 10
}
```

これは実取得情報に基づく形式例であり、毎回この地震を使用する指示ではない。APIの時刻は日本時間として厳格に解釈し、ISO 8601に正規化する。未知のマグニチュード・最大震度はnull。最大震度の有効値は10、20、30、40、45、50、55、60、70。0や-1を震度0として表示しない。原文の震源名は翻訳せず表示できるようにする。

### 4.3 不変条件

- ピクトグラムは行動IDで選び、全言語で図柄を共有する。津波状態を地震状態に戻す遷移を自動実行しない。
- 通知、壁紙、アプリ、Live Activityは同じsessionId・hazard・stateRevisionに対応させる。津波が来た場合は最新の津波状態が優先。
- サーバーは画像を準備してから通知指示を送り、端末はGuideSessionを保存してから通知を予約する。Live Activityも保存済み状態から更新する。
- ショートカットからアプリを開いたとき、未完了セッションがあるならホームを挟まずそのセッションを表示する。
- 各セッションの言語とパッケージ版は開始時に固定する。設定変更・パッケージ更新は次回開始へ反映し、同一セッション内でアプリ・通知・Live Activityの言語を混在させない。
- 通常の再描画、前景復帰、同じrunIdの再受信でphaseをprotectへ戻さない。
- API失敗時もソースを偽装しない。観客向け画面は一貫した訓練表示、運営用画面・ログは取得元を正確に記録する。

## 5. Macサーバーと一つの公開URL

### 5.1 起動

完成版のポートは8788。既存検証サーバーとは同時起動しない。コマンドは次に統一する。

```sh
npm ci
npm run demo:prepare
npm run demo:server
```

別ターミナル：

```sh
npm exec --cache /private/tmp/nigeyo-npm-cache --yes --package cloudflared -- cloudflared tunnel --protocol http2 --url http://127.0.0.1:8788
```

接続先はhttp://127.0.0.1:8788。1本のトンネルでWSS・画像・言語JSON・ショートカットを配信する。サーバーは127.0.0.1にバインドする。公開アセットに個人情報を含めない。

### 5.2 ローカル専用HTTP

| メソッドとパス | 役割 |
| --- | --- |
| GET / | PC操作画面 |
| GET /api/status | 端末状態、素材状態、直近実行、APIの取得元 |
| POST /api/config | トンネルのHTTPS originを登録 |
| POST /api/pairing/rotate | 接続用トークンを更新し、既存接続を切断 |
| POST /api/demo/run | API取得から訓練送信までを開始 |
| POST /api/demo/tsunami | 同じセッションへ別の津波訓練イベントを投入 |
| POST /api/tsunami/observe | 本番552の観測を開始・停止。訓練候補採用も明示設定 |
| POST /api/demo/reset | 実行中でない場合にPC表示を初期化 |

ローカル専用APIはHostがlocalhostまたは127.0.0.1のときだけ許可する。Cloudflare経由を示す転送ヘッダーがある場合も拒否する。POSTはOriginがローカル画面のoriginと一致することを検証する。本文上限は8KB。localhost画面にトークンを表示しても、公開側から取得できないことをテストする。

### 5.3 公開HTTP・WebSocket

| パス | 役割 |
| --- | --- |
| GET /public/health | バージョンと稼働のみ。トークン・地震履歴・端末情報は返さない |
| WSS /public/device | 認証済みのiPhone接続 |
| GET /public/assets/wallpaper.png | 最新の災害状態の壁紙。キャッシュ無効 |
| GET /public/assets/wallpapers/earthquake.png | 地震用の固定パス |
| GET /public/assets/wallpapers/tsunami.png | 津波用の固定パス |
| GET /public/languages/manifest.json | 検証済み言語パッケージの一覧とSHA-256 |
| GET /public/languages/{languageId}.json | manifestに載る言語だけ配信 |
| GET /public/shortcuts/manifest.json | 地震・津波・バックアップ版の導入情報 |
| GET /public/shortcuts/setup | 一括簡単導入ページ |
| GET /public/shortcuts/{approvedFile}.shortcut | 配布用署名済みファイル |
| GET /public/shortcuts/bundle.zip | 2種と説明・manifestの一括取得用。自動インストールではない |
| GET /public/assets/manifest.json | 素材バージョン・ファイル名・SHA-256 |

静的配信はこの許可リストのみ。任意パス・任意URLの代理取得を実装しない。PNGはimage/png、JSONはapplication/json。動的壁紙はCache-Control: no-store, no-cache, must-revalidate, max-age=0。言語・署名済み素材は版とチェックサムで検証する。Mac内部のファイルパスは返さない。

接続用トークンは起動時に32バイトの暗号学的乱数を生成する。ペアリング文字列はwss://公開ホスト/public/device?token=...。アプリは入力時にトークンを取り出し、実際のWebSocket接続ではAuthorization: Bearerトークンを使用する。トークンはKeychainに保存し、URL全体をログに出さない。WSSのみ許可し、証明書検証を無効化しない。

別のiPhoneが既に接続中なら新接続を拒否し、PCから切断してペアリングし直す。後からの接続で既存端末を無言で置き換えない。

## 6. 本番API取得・津波イベント・自動フォールバック

### 6.1 接続先・判定

取得先は `https://api.p2pquake.net/v2/history?codes=551&limit=1` に固定する。1回のデモ開始で1回だけ取得し、タイムアウトは本文受信を含め3秒。公開本番APIからの取得はコード551の発生後情報。緊急地震速報556と称さない。

HTTP 200、JSON配列、先頭要素code=551、空でないid、有効な地震発生時刻と発表時刻を必須とする。本文上限1MB。震源名欠落は言語に依存しない内部値nullにし、表示時に「不明」を翻訳する。未知の震度・Mはnull。壊れたJSON、空配列、異なるcode、日時不正、HTTPエラー、タイムアウトは取得失敗。

過去の地震が最新に返ることは正常。過去であることを理由にデモ再送を拒否せず、通知を訓練として扱う。取得日時と地震の発表日時を別に保存する。

### 6.2 フォールバックの優先順位

デモ開始後、次の順序で、追加の確認ダイアログなしに使用データを確定する。

1. 本番APIから3秒以内に取得・検証できた実データ：source=live-api。
2. 取得失敗時、ディスクに保存した直近の正常な実データ：source=last-good。
3. それもない場合、準備済みの実APIデータ：source=fixture。

正常取得時は原本と取得時刻・取得URL・SHA-256を保存する。last-goodはサーバー再起動後も読み込む。fixtureも実際の取得原本を使い、発生時刻を書き換えない。fixtures/demo/quake551.jsonとmetadata.jsonをリポジトリに同梱する。metadataには取得元、取得時刻、チェックサムを記録する。

demo:prepareはlive取得を試みる。オフラインで既存の有効なfixtureがある場合はそれを検証して成功とし、fixtureがなくAPIにも接続できない場合は失敗して不足を明示する。架空の実地震を自動生成して成功扱いしない。

### 6.3 観客向けと運営向けの表示

- 観客向けの通知・アプリ画面は、どのソースでも「訓練」として同じ体験を行う。API障害のエラー画面で案内を中断しない。
- PCの通常表示は「準備中／送信中／端末で通知予約済み／端末の応答なし」。技術詳細は折りたたんだ運営用欄に表示する。
- 運営用欄・JSONLにはlive-api／last-good／fixture、API失敗理由、元情報ID、元発表時刻を必ず残す。
- fixture使用時に「たった今のAPI取得成功」と表示・記録しない。発表で事実を説明する場合は、実取得と準備済みデータを区別する。
- このフォールバックがカバーするのは外部地震APIの失敗。iPhone未接続、端末の通知拒否、ショートカットの実行失敗までは隠して成功にしない。

### 6.4 同じP2P APIの津波情報を使う

同じ提供元を利用できるが、地震551と津波552は別の情報形式。津波history取得は `https://api.p2pquake.net/v2/history?codes=552&limit=1`、新規配信の購読は `wss://api.p2pquake.net/v2/ws` とする。常時購読はPC画面で明示的に開始する「本番API観測」に限定し、デモ用以外の実災害自動配信は今回の完成条件に含めない。接続、受信、判定、訓練への採用、通知予約を別記録にする。

- code=552、空でないid、正しいissue.time、cancelledのboolean、areasを検証し、原本と出典メタデータを保存する。重複は原文idで除去する。
- 対象の津波予報区名はデモ設定に明示する。所在地未設定の端末を全国の警報に一律一致させない。住所や現在地をサーバーに送らず、公開の予報区識別値だけを使う。
- cancelled=falseかつ対象区のgradeがMajorWarning／Warning／Watchなら候補。Unknown・区域欠落・対象外は訓練用の自動採用から除外する。これらのgradeは津波の発生確定を意味せず、文言で断定しない。
- cancelled=trueは解除情報。新たな「津波がきます」通知の起点にしない。既存避難案内の解除・終了・安全宣言にも自動変換しない。
- 観測から新規候補として採用できるのは発表後5分未満、未来許容5秒以内の情報に限定する（デモの試験値、本番推奨値ではない）。期限切れは履歴として表示し、勝手に現在の警報へ変換しない。
- 履歴の訓練再送はこの新規判定と別経路。古い時刻のままmode=demo、sourceを正しく付け「訓練・過去情報」として使う。APIが空配列なら「最新の津波履歴なし」であり、「津波の危険なし」ではない。
- 津波訓練のフォールバックもlive-api → 有効な津波last-good → 出典付き津波fixture。地震551を津波552として流用しない。どれもなければ、明示的なlocal訓練シナリオを選べるようにし、実API取得成功とは扱わない。

### 6.5 津波イベントから通知まで

対象津波情報または明示的な津波訓練イベント → サーバーで津波画像を原子的に選択・検証 → hazard-update送信 → 端末が同一セッションの津波状態を保存 → TSUNAMI_TEST通知 → ショートカットで津波壁紙 → 既存Live Activityを津波案内へ更新。サーバーの切替は通知受信を待たず送信前に完了させる。ショートカットや通知タイトルからサーバーの災害判定を行わない。

同じセッションの津波優先更新はsession-busyで拒否しない。別のsessionIdを上書きしない。元地震IDと津波情報IDに因果関係が保証されると考えず、デモ上の紐づけを明示する。

## 7. PC操作と実行状態

### 7.1 操作画面

操作画面は「接続準備」「デモ開始」「運営用詳細」の3領域にする。

- 接続準備：HTTPS origin入力、ペアリング文字列コピー、接続先の端末名、言語、heartbeat時刻、素材バージョン確認。
- デモ開始：earthquake／earthquake-tsunamiの選択、1個の開始ボタン、現在の実行状態。後者はprotect表示後に別の津波訓練イベントを投入する。投入は運営用の「津波訓練通知を送る」で明示的に行い、揺れ確認ボタンには連動させない。
- 運営用詳細：API情報、フォールバック理由、runId、イベントID、通信・通知予約の各時刻、受信時のiOS状態、試験結果のメモ。

API応答原文は運営用詳細の中で閲覧可能にする。生存報告が15秒以上ないとき、端末未接続時、実行中は開始ボタンを無効にする。津波シナリオの選択は「津波訓練の展開を追加」と表示し、実APIの津波警報と混同させない。

### 7.2 POST /api/demo/run

```json
{
  "scenario": "earthquake"
}
```

言語は接続中iPhoneのhelloで受信した設定を使う。PCから言語を上書きしない。サーバーはrunIdを生成し、202とrunIdを返して非同期処理を開始する。実行中の二重開始は409。端末未接続・heartbeat期限切れも409、入力不正は400。

状態はpreparing → acquiring → sending → scheduled。送信後5秒でACKがない場合は1回だけ同じrunIdで再送する。さらに5秒でACKがなければack-unknownを終了状態とし、「予約成否不明」と表示する。端末から明示的に失敗応答があった場合はfailed。成否不明を「通知されなかった」と断定せず、別runIdでの自動再実行はしない。遅れて同じrunIdの成功ACKが届いた場合はscheduledへ更新する。送信APIの202は、端末への到着や通知表示の証明ではない。

通信後の1秒の通知予約を目安とし、デモ開始から通知までの実機目標時間は8秒以内。これは受入試験の目標であり、OSの表示時刻の保証ではない。

## 8. WebSocket契約 v2

すべてUTF-8のJSONテキスト。1メッセージ上限16KB。schemaVersion=2。未知のtype・不正な必須値はエラー応答し、通知を出さない。生のAPI原文はMacに残し、iPhoneへは正規化した最小情報だけを送る。

### 8.1 hello：iPhone → Mac

```json
{
  "schemaVersion": 2,
  "type": "hello",
  "installationId": "6c43c859-d9af-47da-a627-685f0096547d",
  "appVersion": "1.0.0",
  "preferredLanguage": "en",
  "languagePackageVersion": 1,
  "resourceVersion": 2,
  "liveActivitiesEnabled": true,
  "notificationAuthorization": "authorized"
}
```

installationIdはアプリ初回起動時に生成するランダムUUID。端末固有ID・メール・住所は送らない。notificationAuthorizationはnot-determined、denied、authorized、provisionalのいずれか。実演のready条件はauthorized、resourceVersionとlanguagePackageVersion一致、必要言語の検証済みパッケージあり、未完了セッションなし、15秒以内のheartbeatとする。provisionalは通知表示条件をそろえるためreadyとせず、通知許可設定を案内する。設定言語の変更・前景復帰時は通知許可を確認し、新しいhelloを送る。

### 8.2 start-guide：Mac → iPhone

```json
{
  "schemaVersion": 2,
  "type": "start-guide",
  "runId": "7b79b216-37a3-4ce9-9bc4-2a47bd76270c",
  "mode": "demo",
  "source": "live-api",
  "language": "en",
  "scenario": "earthquake",
  "languagePackageVersion": 1,
  "stateRevision": 1,
  "hazard": "earthquake",
  "sentAt": "2026-10-24T06:54:34Z",
  "expiresAt": "2026-10-24T06:54:54Z",
  "quake": {
    "sourceEventId": "6adc2a51e88ee598246bf418",
    "code": 551,
    "occurredAt": "2026-10-24T12:44:00+09:00",
    "issuedAt": "2026-10-24T12:47:28+09:00",
    "hypocenterName": "陸奥湾",
    "magnitude": 2.9,
    "maxScale": 10
  }
}
```

expiresAtは通信指示の有効期限であり、地震の発表時刻ではない。sentAtから20秒後を設定する。端末はexpiresAt超過を拒否する。sentAtが端末時刻より5秒以上未来の場合はclock-skewで拒否し、PCとiPhoneの自動時刻設定を案内する。APIの古い発表時刻と通信の期限を同じ判定にしない。

### 8.3 通知予約ACK：iPhone → Mac

```json
{
  "schemaVersion": 2,
  "type": "notification-ack",
  "runId": "7b79b216-37a3-4ce9-9bc4-2a47bd76270c",
  "status": "scheduled",
  "receivedAt": "2026-10-24T06:54:34.200Z",
  "scheduledAt": "2026-10-24T06:54:35.250Z",
  "appState": "background",
  "protectedDataAvailable": false
}
```

statusはscheduled、duplicate、rejected、failed。拒否・失敗時はerrorCodeを付ける。有効なerrorCodeはunsupported-version、invalid-payload、expired-command、clock-skew、notifications-denied、storage-failed、notification-failed、session-busy、language-mismatch、language-package-missing、stale-revision。duplicateは同じrunIdを通知済み・予約済みとして扱った結果であり、二重通知を出していないことを意味する。

heartbeatは5秒間隔。schemaVersion、type=heartbeat、installationId、appState、protectedDataAvailable、currentSessionIdを送る。ロック状態をappStateやprotectedDataAvailableから断定しない。PCは受信時刻を独自に付けて判定する。

### 8.4 hazard-update：Mac → iPhone

schemaVersion=2、type=hazard-update、commandId（新しいUUID）、sessionId（元runId）、hazardRevision（サーバーのセッション内単調増加値）、hazard=tsunami、mode、source、language、languagePackageVersion、sentAt、expiresAt、tsunami（TsunamiSummary）を送る。SummaryはsourceEventId、code=552、issuedAt、cancelled、対象予報区とgradeだけを持つ。合成訓練の場合はtsunami=null、source=localであり、架空のsourceEventIdを実API由来として付けない。

ACKはcommandId・sessionId・hazardRevisionと、保存後のstateRevisionに対応させ、予約済み重複と古いhazardRevisionを区別する。stateRevisionは端末のSessionStoreだけが採番し、ローカル操作と外部更新の双方で増加する。外部イベントはlastHazardRevisionで順序判定するため、端末の確認操作が先行しても新しい津波情報を誤って捨てない。同じセッションへの正当な津波更新はprotect／safety-checks／choose-place／show-destinationより優先する。evacuationDecision=goingでLive Activityを終了済みなら、通知と保存状態は更新してもロック中にActivityを勝手に再開しない。次の前景で最新状態を表示し、必要な継続操作を提示する。

## 9. Swift受信・保存・通知

### 9.1 クラス構成

- DeliveryService protocol：connect、disconnect、接続状態、正規化イベントの受信。
- WebSocketDeliveryService actor：通信と再接続。ビューやWebViewに依存させない。
- NotificationService：通知許可確認、予約、取消、通知タップ処理。
- SessionStore actor：GuideSession・受信記録の保存、読み出し、進行更新。
- AppModel：@MainActor @Observable。SessionStoreの状態をUIへ公開する。
- AppRouter：起動経路を一か所で処理する。
- LanguageRegistry／LocalizationService：パッケージの検証・登録・スナップショット作成。
- LiveActivityCoordinator：同じSessionStoreからActivityの開始・更新・終了・復元を直列化する。拡張は受信サーバーにならない。

ネットワーク・JSONの読み書き・全国避難場所の検索をメインスレッドで行わない。SwiftUIの状態更新だけをMainActorへ戻す。

担当間の保存インターフェースはSessionStoreProtocol: Sendableとし、prepare(_ session: GuideSession) async throws、markNotificationScheduled(sessionId: UUID, fireAt: Date) async throws、snapshot() async throws -> GuideSession?、transition(sessionId: UUID, expectedRevision: Int, to: GuidePhase) async throws、complete(sessionId: UUID) async throws、receipt(for runId: UUID) async throws -> NotificationReceipt?を提供する。津波用にapplyHazardUpdate(sessionId:commandId:revision:summary:)、避難開始用にconfirmEvacuation(sessionId:expectedRevision:)も持つ。保存前の検証とsession-busy判定はprepare内でも行い、競合する二つの呼び出しを同時受理しない。モデルとエラー型はContracts/に置き、UI側独自の同名モデルを作らない。

場所選択用にselectPlace(sessionId: UUID, context: PlaceContext, candidateIds: [String]) async throwsとselectDestination(sessionId: UUID, destinationId: String) async throwsを提供する。画面への変更通知はchanges() async -> AsyncStream<GuideSession?>で公開し、AppModelは起動時に一つの購読を維持する。NotificationReceiptはrunId、state（prepared／scheduled／failed）、receivedAt、fireAt、errorCodeを持つ。Keychainの接続情報はafterFirstUnlockThisDeviceOnlyで保存する。

### 9.2 受信の処理順

1. JSON、バージョン、モード、言語パッケージの存在・版、期限を検証する。
2. runIdの受信記録を確認する。同じrunIdの予約済み記録があれば二重通知せずduplicateを返す。
3. 新しいセッションを原子的に保存する。保存に失敗したら通知を出さずstorage-failed。
4. UNUserNotificationCenterへ1秒後の通知を予約する。
5. 予約成功を記録してscheduledのACKを返す。
6. AppModelへ状態を通知する。既にアプリが開かれている場合も同じセッション画面へ進める。

受信記録は直近100件を保持する。原本地震情報IDではなくrunIdで重複判定する。同じ過去地震のデモを別runIdで繰り返せるようにする。

アクティブな案内があるとき、別runIdの開始で進行中の案内を無言で上書きせずsession-busyを返す。同一セッションへの新しい津波hazard-updateは例外として優先保存し、通知・Live Activityを更新する。アプリのデモ用設定から「案内を終了してリセット」で終了できるようにする。

### 9.3 保存形式とロック中アクセス

設定はUserDefaults。GuideSessionと受信記録はApplication Supportの単一ファイルsession-state.jsonへ一時ファイルから原子的に書き換える。ロック中に受信・保存できるよう、対象ファイルの保護はcompleteUntilFirstUserAuthenticationを設定する。端末起動後に少なくとも一度ロック解除してからデモを行う。

地震開始の通知identifierは`nigeyo.{runId}`、津波更新は`nigeyo.{sessionId}.{commandId}`で固定する。再送では同じidentifierを用い、開始通知と津波更新を別記録として照合する。保存後・通知予約後の途中終了から復帰したときは、保存記録とpending／delivered通知を照合し、同じ実行の通知を無条件に作り直さない。厳密な「表示を一度だけ保証」とは記述しない。

### 9.4 通知内容

- titleは地震=EARTHQUAKE_TEST、津波=TSUNAMI_TEST。全言語で固定し、ショートカットの種別条件に使う。案内本文は選択言語。
- bodyはセッションの言語スナップショットで生成する。地震は訓練・過去情報、発生時刻、震源、最大震度。津波訓練は訓練表示、元発表時刻、対象区、警報種別を示す。表示長は200文字以内。
- userInfoはsessionId、commandId、stateRevision、hazard、mode、sourceEventIdのみ。音声案内は含めない。OS標準の短い通知音だけを使い、ガイド音声・読み上げは実装しない。
- バナー・通知センター・サウンドの許可をユーザーに求める。前景時もwillPresentでbanner・list・soundを指定する。
- scheduled ACKはOSへの予約成功であり、実際に画面が点灯したことや壁紙が変わったことの証明ではない。
- アプリからショートカットURLを自動実行する処理は作らない。通知を契機とした実行はユーザー設定済みのオートメーションが担当する。

### 9.5 接続状態

disconnected → connecting → connected → reconnecting／disconnected。接続失敗時の再試行は1秒、2秒、4秒、8秒、以後15秒で、最大30秒まで続ける。ユーザーが切断した場合は再接続しない。停止中に実行保証はない。端末を開き直したときは接続状態を再確認する。

## 10. アプリ起動・案内引き継ぎ

- ローカル状態に未完了のGuideSessionがあれば、通常起動・通知タップ・ショートカットの「Appを開く」のいずれでも、そのphaseへ直接進む。
- 未完了セッションは開始後30分以内を自動復帰対象とする。それより古い場合は「前の訓練を続ける／終了する」を表示する。
- NotificationServiceのdidReceiveはsessionIdに対応する保存状態を開く。対応する記録がない通知では、ホームに「案内の記録が見つかりません」を表示し、訓練と手動開始を利用可能にする。
- 独自URLはnigeyo://guide、nigeyo://home、nigeyo://evacuation?sessionId=UUID、nigeyo://shortcuts/setup。evacuationは保存済みの同一未完了セッションを確認してchoose-placeへ進む。URLのhazardや本文で状態を上書きせず、任意の画像URL・ファイルパスは受け取らない。
- SwiftUIのonOpenURLで処理し、複数箇所に遷移判断を書かない。
- 前景で案内状態を読み込んだ直後、LiveActivityCoordinatorがそのsessionIdのActivityを開始または既存のものに同期する。scenePhaseがbackgroundへ変わった瞬間に新規requestする設計にしない。
- 接続済みデモで受信する前に初期設定を完了させる。初期設定未完了時の通知は設定確認画面へ進み、完了後に保存済み案内へ戻る。

## 11. ピクトグラム・壁紙・ショートカットの簡単導入

### 11.1 行動ごとの素材

protect-head、check-surroundings、check-fire、secure-exit、tsunami-evacuateの5行動の図柄を用意する。アプリ・Live Activityでは透明背景の正方形素材、壁紙では地震用earthquake.pngと津波用tsunami.pngを使う。安全確認の3枚は別画像として一画面に同時表示し、頭を守る画像を他行動の意味に流用しない。Live Activity拡張の画像は拡張のAsset Catalogにも同梱する。

壁紙は承認済みの縦長PNG（現在853×1844px）を使用する。時計や通知が重なる上30%と下20%に主要図柄を置かず、35〜70%の高さを中心に配置する。画像自体に特定言語の文字を埋め込まず、アプリ・Live Activityの文言を言語パッケージで表示する。

### 11.2 音声案内の削除

音声ファイル、音声URL、audioFileキー、音声合成・再生・読み上げアクションを仕様・素材・事前確認・配布物から削除する。ショートカットも「壁紙変更→アプリを開く」だけにする。OSの通知音とアクセシビリティのVoiceOverは音声案内機能とは区別して維持する。

### 11.3 壁紙の切り替え順と競合

サーバーは災害種別を決定し、固定PNGの存在・形式・チェックサムを検証してから通知指示を送る。ショートカットは端末内に同梱した画像をデコードし、通知種別に対応する壁紙を設定する。共有画像の参照・URL・サーバー上の「現在の画像」は持たない。旧共通URLは410を返し、誤った画像へのフォールバックをしない。

### 11.4 2種類のショートカット

| 種類 | 通知条件 | 同梱する画像 | その後 |
| --- | --- | --- | --- |
| 地震 | Nigeyo／EARTHQUAKE_TEST | earthquake.png（端末内） | 壁紙設定→Nigeyoを開く |
| 津波 | Nigeyo／TSUNAMI_TEST | tsunami.png（端末内） | 壁紙設定→Nigeyoを開く |

画像取得は「ショートカット同梱PNGのBase64テキスト→デコード→入力から画像を取得→壁紙の写真を設定」。プレビューをオフ。解除が必要ならOSの要求に従い、認証を回避しない。通知時にアプリの保存状態を参照して案内を開き、ショートカットから新規セッション・新規通知を作らない。言語別のショートカットは作らず、言語はアプリに任せる。

### 11.5 一括簡単ダウンロード／導入

設定画面に「地震・津波のショートカットをまとめて設定」を追加する。1つのセットアップページで、2種の署名済み.shortcutまたは正式なiCloud共有リンク、バージョン、必要権限、壁紙対象、画像の端末内保存をまとめて案内する。manifestにはid、version、minimumOSVersion、triggerTitle、downloadURLまたはiCloudURL、SHA-256、importQuestions、手順版を持つ。

一括取得用ZIPには2種・説明・manifestをまとめ、導入画面には地震→津波の追加を順に進めるステップを用意する。ただしZIPの取得だけでインストールや有効化が完了したことにはしない。通知条件を含むトリガーを配布ファイルへ同梱し、別途の自動化新規作成を不要にする。OSの追加確認、対象Nigeyoの照合・必要な選び直し、通知トリガー有効化、ロック中実行、初回権限はユーザー操作。アプリがこれらを無断で自動登録する機能は設計しない。オートメーション入りの共有形式は対象iOS 27で実機検証し、使えなければ2つの基本ショートカット＋通知条件設定の案内を同じ画面で提供する。

配布用ファイルはAppleの正式な共有・署名手順を用いる。配布物に接続トークン・秘密鍵・個人のBundle IDを埋め込まない。壁紙取得URLの入力は不要で、インポート質問は空配列とする。画像はダウンロードしたショートカット内に保存される。架空のiCloudリンクを生成しない。「両方追加した」「両方の自動実行をテストした」をユーザーが確認して完了とする。言語追加だけで再インストールを求めない。

### 11.6 設定ガイド・バックアップ

通知許可→テスト用ロック画面選択→一括導入ページ→2種を追加→対象アプリ・タイトル条件設定→手動実行で権限許可→ロック中実行確認→地震・津波の実機試験、の順。追加操作の実数を受入記録へ残す。OSから設定済みか自動検出できる前提を置かない。再インストール・Bundle ID変更時は通知対象アプリを再選択する。origin変更だけならショートカット側の設定変更は不要。

地震用・津波用PNGをFilesにも保存できる。標準の2種は初めから画像を内部に保持するためFilesやiCloudは実行の前提にしない。オフライン手動実行とロック中自動実行を実機で確認する。

## 12. 追加可能なJSON言語パッケージ

### 12.1 採用方式とディレクトリ

行動定義cards.jsonと翻訳文を分離し、翻訳は1言語1ファイルの `assets/languages/{languageId}.json` へ集約する。初期同梱はen.json、ja.json、ko.json。LanguageIDはBCP 47形式の文字列で、固定enum・固定3要素配列・switchによる言語分岐を禁止する。Resourceフォルダを探索するLanguageRegistryから設定画面の言語一覧を作る。

```json
{
  "schemaVersion": 1,
  "packageVersion": 1,
  "languageId": "ja",
  "displayName": "Japanese",
  "nativeName": "日本語",
  "direction": "ltr",
  "strings": {
    "guide.protect.title": "地震です、頭を守ってください",
    "guide.protect.body": "低い姿勢で、頭を守ってください。",
    "guide.shakingQuestion": "揺れがおさまりましたか",
    "guide.surroundings.title": "安全確保",
    "guide.fire.title": "火を消す",
    "guide.exit.title": "扉を開ける",
    "guide.unsafeButton": "安全でないと感じたら",
    "guide.tsunami.title": "津波がきます、高台へ",
    "guide.tsunami.body": "津波の危険があります。高台などへ避難してください。",
    "guide.goToDestination": "この避難場所へ向かう",
    "training.badge": "訓練"
  }
}
```

このJSONは構造例で、完成パッケージではない。contracts/language-package.schema.jsonとrequired-string-keys.jsonで、アプリUI・設定・通知・エラー・Live Activity・ボタン・VoiceOverの全必須キーを管理する。日時・施設名・震度は型付きプレースホルダーにし、3言語でキー・変数名・型が一致することを検証する。cards.jsonには行動ID、画像ID、タイトル・本文・ボタンの文字列キーだけを置き、翻訳辞書や音声キーを重複保持しない。

### 12.2 追加と反映

1. 同じスキーマの言語JSONを1ファイル追加し、翻訳レビューを行う。
2. `npm run languages:validate` でBCP 47、重複ID、必須キー、空文字、プレースホルダー、方向、版を検証する。
3. `npm run languages:prepare` がファイルを探索し、公開manifestを自動生成。手作業でsupportedLanguagesを更新しない。
4. ビルド時は検証済みJSONをアプリResources/Languagesへコピーし、コード変更なしで言語一覧へ反映する。
5. インストール済みアプリは設定の「言語パッケージを更新」で、同じ設定済みHTTPS originのmanifestと追加JSONを取得できる。検証後、Application Support/Languagesへ原子的に保存し、再ビルドなしで一覧へ追加する。これは翻訳APIではなく静的JSONの配布。

更新は設定画面での操作時だけ行い、災害通知・案内中にはネット取得しない。相対ファイル名はmanifestの許可リストと同一originに限定し、サイズ上限256KB、リダイレクト先も同一origin、SHA-256・スキーマ・全必須キーを検証。不適合な新パッケージは登録せず、直前の正常版を保持する。チェックサムだけで配信元の信頼性が保証されるとは考えず、設定済みoriginとTLSを信頼境界にする。

### 12.3 フォールバックと一貫性

LocalizationServiceがバンドル＋検証済みキャッシュを読み、未知言語はenへ正規化する。追加パッケージに必須キー不足があれば全体を不採用とし、部分的な誤訳・言語混在を避ける。同梱パッケージの欠落はビルド失敗。実行時破損では正常キャッシュ／同梱enへパッケージ単位で戻し、診断を残す。OSの権限ダイアログなどアプリ管理外の文言は端末言語に従い、JSON追加だけで変わるとは説明しない。

セッション開始時にlanguageId・packageVersionと必要文言をlanguageSnapshotへ固定する。通知・アプリ・Live Activityは同じSnapshotを使用する。Live ActivityのContentStateにはその画面で必要な短い表示文だけを渡し、パッケージ全体は含めない。新言語・長文・将来RTLについてもレイアウトを検証し、危険な文意の翻訳はレビュー表へ残す。

### 12.4 行動定義とオフライン

| 行動ID | ピクトグラム | 日本語の意味 |
| --- | --- | --- |
| protect | protect-head | 地震です、頭を守ってください（低い姿勢） |
| check-surroundings | check-surroundings | 安全確保。ガラス・家具・落下物・足元に注意 |
| check-fire | check-fire | 揺れがおさまり、安全にできる場合だけ火を消す。危険な場所へ戻らない |
| secure-exit | secure-exit | 安全にできる場合は扉を開け、出口を確保 |
| tsunami | tsunami-evacuate | 津波がきます、高台へ。訓練表示または元情報の警報種別を併記 |

登録済み文言、保存済み避難場所、全国データの距離検索、Live Activity操作はオフラインで動く。新言語の取得、MapKit検索・徒歩距離・未キャッシュ地図・外部Google Maps・PC通信・Web画像はネット接続が必要。音声パッケージは作らない。

## 13. 画面遷移とLive Activity

### 13.1 初期設定・ホーム

初期表示は英語。LanguageRegistryに登録された言語をnativeNameで列挙し、初期はEnglish／日本語／한국어。自宅・大学を検索またはピンで一時指定し、自宅×地震、自宅×津波、大学×地震、大学×津波の4枠を確認・保存して元座標を破棄する。候補なしも保存可能。津波非対応施設を津波用へ流用しない。

ショートカット一括導入と地震・津波通知テスト、Live Activity設定・テストへの案内後にホームへ進む。ホームは訓練、揺れを感じました、設定。未完了セッションの案内を優先し、明示的な終了確認でホームへ戻る。デモ接続とパッケージ更新は設定に置く。

### 13.2 通常の地震：壁紙からアプリ、Live Activityへ

1. 地震通知を受信し、ショートカットが地震壁紙に変更する。
2. OSが要求する認証を行ってアプリが一度前景になる。protect画面には「地震です、頭を守ってください」のピクトグラムと「揺れがおさまりましたか」ボタンを表示する。
3. その前景中にLive Activityを開始する。次にロック画面へ戻ると、頭を守る指示・同じ確認ボタンが表示される。背景化後に初めて開始する設計ではない。
4. 確認ボタンのユーザー操作でphase=safety-checksへ進み、同じLive Activity内に安全確保・火を消す・扉を開けるの3枚を同時表示し、「安全でないと感じたら」ボタンを置く。
5. そのボタンから必要なロック解除を経てアプリを開き、choose-placeの家／学校／その他を表示する。
6. 候補の避難場所を表示し、ユーザーが「この避難場所へ向かう」を明示的に選ぶとevacuationDecision=goingを保存し、Live Activityを即時終了・非表示にする。単に家／学校／その他を選んだだけでは終了しない。地図表示・Google Mapsへの引き渡しはその後も利用できる。

アプリ側の同じ確認ボタンでも同じ状態遷移を行う。個別確認が必要な本文はアプリで補足できるが、Live Activityで3枚を順送りにせず一画面に表示する。

### 13.3 津波への優先切り替え

552の対象候補または明示的な津波訓練イベントを受け、サーバーで津波壁紙を選択してからTSUNAMI_TESTを送る。通知をトリガーに津波ショートカットが津波壁紙へ変更する。同時にアプリは保存状態をhazard=tsunami、phase=tsunami-evacuateへ優先更新し、既存Live Activityに設定言語の「津波がきます、高台へ」に対応する指示・津波ピクトグラムを表示する。揺れの確認や火の始末の操作を待たない。

訓練には訓練表示、実データ参照には元発表時刻・警報種別を付け、津波到達を断定しない。津波画面の「避難場所を確認」からアプリの家／学校／その他へ進み、津波対応施設のみ提示する。避難先へ向かう選択時の終了条件は通常シナリオと同じ。

通知だけでは未開始Activityをロック中に新規作成できると仮定しない。Activityがない・終了済み・ユーザーが消した場合は壁紙と通知を維持し、次の前景化時に最新の津波案内を表示・Activity開始を試みる。この差を受入試験に記録する。

### 13.4 ActivityKitの実装境界

- 主アプリのNSSupportsLiveActivitiesを有効化し、専用WidgetKit拡張にActivityConfigurationとDynamic Islandのcompact／minimal／expanded表示を実装する。通常のホーム画面Widgetは作らない。
- LiveActivityCoordinatorがActivityAuthorizationInfo.areActivitiesEnabledを確認し、前景でActivity.request(attributes:content:pushType:nil)を行う。APNsやpush-to-startは今回使わない。1つのGuideSessionにつき最大1つのActivity。復帰時はActivity.activitiesと突合して重複開始を防ぐ。
- AttributesにsessionId、ContentStateにhazard・phase・stateRevision・必要な短い翻訳文と行動IDを入れる。静的／動的データ合計4KB以内を検証し、画像バイト・言語パッケージ全体・住所・座標は入れない。画像は拡張に同梱。拡張自身はサーバー通信・現在地取得をしない。
- App Groupを前提にしない。LiveActivityIntentは主アプリのプロセスでSessionStoreを操作し、表示に必要な文言はContentStateで拡張へ渡す。主アプリと拡張に必要なモデル・Intent定義のターゲット所属をそろえ、Personal Teamの署名・実機可否を早期検証する。App Groupが必要な方式へ無断で変更しない。
- 開始・更新失敗や許可オフでもアプリ・壁紙・通知は継続する。Live Activityは常時通信やWebSocketの停止回避の仕組みではない。Xcode接続下の受信成功を通常起動に一般化しない。

### 13.5 ロック画面からの操作と同期

「揺れがおさまりましたか」はButton(intent:)とConfirmShakingStoppedIntent: LiveActivityIntentで実装する。画面内の非機密な段階更新だけを行い、認証ポリシーはalwaysAllowedを意図として設定する。ロック中の実動作・OS追加認証は実機で検証する。自動で揺れが収まったと判断しない。

IntentにはsessionIdとexpectedRevisionを持たせ、SessionStoreが同一セッション・最新hazard・revisionを検証して保存後にActivityを更新する。連打・再送は冪等とし、保存失敗では画面だけ先へ進めない。津波更新後に遅れて到着した地震確認操作を拒否し、津波画面を戻さない。

「安全でないと感じたら」は見た目をボタンにしたLinkでnigeyo://evacuation?sessionId=UUIDへ進む。OSが必要とする認証を行って主アプリを開き、保存済みの最新hazardでchoose-placeを表示する。Live Activity内で住所・現在地・避難施設検索を行わない。

### 13.6 大きさ・終了・復元

3枚はロック画面の利用可能領域内で横3列を基本に、同じ大きさ・短いラベル・下部の操作を確保して可能な限り大きく表示する。Live Activityは高さ160ptを超えるとシステムが切り詰める可能性があり、画面全体への最大化や3枚のフルスクリーン表示は約束しない。Dynamic Typeで欠けない代替配置を用意し、compact／minimalでは簡略表示、詳細はロック画面／アプリで提供する。

避難開始の確定、訓練終了、設定全削除でActivity.end(..., dismissalPolicy:.immediate)を呼ぶ。避難開始後はそのセッションの再描画で再作成しない。ユーザーによる消去・OS終了は「避難済み」の意味にしない。OSの最大継続時間（8時間）や表示制御を超える常駐を保証しない。再起動時は保存状態とActivityの実在を照合し、状態をprotectへ戻さない。

### 13.7 場所の選択・手動開始・訓練

choose-placeは家／学校／その他。家・学校はhazardに対応する保存済み候補、未登録ならotherを選べる。otherは現在地から同梱データの災害適合施設を直線距離順に2件まで表示し、なければ候補なしとする。show-destinationは名称・災害適合・住所・距離種別・位置・「この避難場所へ向かう」・Google Mapsを表示する。

「揺れを感じました」はAPI・通知・ショートカットを使わず、mode=manual、source=manual、phase=protectで開始する。アプリ内訓練はmode=training、source=local、quake=nullで5〜15秒の整数を等確率に選び、UNTimeIntervalNotificationTriggerで予約する。津波シナリオは別訓練イベントとして明示し、実API取得と称さない。キャンセルは保留通知・案内・Activityを終了する。

## 14. 全国避難場所データ

### 14.1 出典と変換

国土地理院の指定緊急避難場所の全国CSVを使う。指定避難所のデータと混ぜない。データ取得元・取得日・利用条件・SHA-256・入力行数・採用件数・除外件数をmanifestに保存する。全国データをResourcesへ同梱し、アプリの初回起動時にダウンロードしない。

scripts/import-evacuation-sites.mjsはCSVをRFC 4180対応パーサーで読み、UTF-8・UTF-8 BOM・Shift_JISを明示して処理する。列名で取得し、列番号のハードコードをしない。地震・津波の値1または文字列「1」を対応あり、それ以外を対応確認なしとして扱う。緯度経度はWGS84、数値範囲不正・欠落・名称欠落は除外し件数を記録する。

同じ共通IDは重複排除する。共通IDが空なら、自治体名・名称・丸めていない元座標を組み合わせた文字列のSHA-256をIDにする。同一IDで値が競合したら変換を失敗させ、黙って先勝ちしない。

### 14.2 アプリ用レコード

```json
{
  "id": "gsi:example-id",
  "name": "施設名",
  "address": "公開施設の住所",
  "municipality": "市区町村名",
  "latitude": 35.0,
  "longitude": 135.0,
  "supportsEarthquake": true,
  "supportsTsunami": false,
  "notes": "原本の備考"
}
```

正規化JSONを一度だけ非メインスレッドで読み込み、EvacuationRepository actorが保持する。名称・住所は公式原文のまま。実行時の自動翻訳はしない。

### 14.3 絞り込み・距離

災害種別で絞り込み、地球半径6,371,000mのHaversineで直線距離を計算する。距離が同じ場合はidの昇順で並べる。最初は地点から100km以内を候補とし、100km内にないときは距離無制限の遠方施設を「近く」として表示しない。

初期設定は各枠の直線距離上位3件だけについて徒歩経路を取得する。緊急時otherは上位2件を直線距離のみで表示し、経路APIを呼ばない。

距離は1km未満をm、以上を小数1桁のkmで表示する。徒歩距離と直線距離のラベルを区別する。近い候補が必ず安全・到達可能とは表示しない。

## 15. MapKitとGoogle Mapsへの引き渡し

### 15.1 初期設定の場所入力

MKLocalSearchCompleterで入力候補、MKLocalSearchで選択候補の座標を確定する。検索開始は入力変更から300ms後、前の検索はキャンセルする。検索できない場合は地図のピン指定で継続できる。現在地許可を初期画面で必須にせず、位置が必要な操作時にだけ要求する。

地図の操作で選んだ座標はユーザーが確定するまで一時データ。自宅と大学の元座標は4枠の提案が終わるまでメモリに保持し、確定・キャンセルで破棄する。検索履歴や元座標をサーバーへ送らず、アプリログにも書かない。MapKit検索・経路計算のためAppleへ位置が送られることは、プライバシー説明に記載する。

### 15.2 徒歩距離の比較

MKDirections.Request.transportType=.walking。最大同時実行数2、1経路のタイムアウト8秒。初期設定の3候補について取得し、成功した経路距離の最短を第一候補とする。失敗候補は「徒歩距離未取得」として残し、成功候補より後に表示する。

3候補とも失敗した場合は直線距離順で表示し、徒歩距離比較は行えていないことを示してユーザーに選択してもらう。直線距離を徒歩距離として保存しない。距離・候補が決まったらユーザーが施設を確認して確定する。

この経路計算は候補比較のためだけに使う。Polyline、経路ステップ、曲がる方向、到着予想、リアルタイム追跡、到着判定は実装しない。

### 15.3 Google Maps URL

```text
https://www.google.com/maps/dir/?api=1&destination=緯度%2C経度&travelmode=walking
```

URLComponentsで組み立てる。originは渡さず、Google Maps側で現在地を扱う。Google Mapsアプリがなければ同じHTTPS URLがブラウザで開く。APIキーやGoogle Maps SDKは不要。OpenURL失敗時は施設の住所・座標をコピーできるようにする。

アプリ内の地図は施設位置の確認用であり、ナビ機能ではない。避難時は道路・建物の現況、自治体の案内を優先する文言を表示する。

## 16. 位置情報とプライバシー

- 使用許可はWhen In Useのみ。Always許可とバックグラウンド位置情報は使わない。
- other操作時に現在地を取得し、8秒で取得できなければ再試行・地図のピン指定・家／学校への戻りを提示する。
- 現在地が1分以上古い、または水平精度が1kmより悪い場合は確認を促し、黙って正確な現在地として扱わない。
- 元の自宅・大学の入力住所と座標は確定後に永続化しない。保存するのは4枠の公開避難施設情報のみ。
- 選択した施設から生活圏を推測できることは設定画面で説明する。外部へ送信しない。
- 設定の全削除で保存済み避難場所、言語、案内状態、接続トークンを削除する。削除確認を挟む。
- データ削除はiOSショートカット・壁紙・Filesに保存した素材を自動削除しない。その戻し方を案内する。

## 17. 品質・アクセシビリティ・UI

- 主要ボタンは44pt以上。Dynamic Type、VoiceOverラベル、十分なコントラストに対応する。
- protectは共通ピクトグラムを大きく表示し、短い指示と「揺れがおさまりましたか」を置く。災害対応を急がせる自動カウントダウンは置かない。
- 案内の次段階はユーザー操作で進む。画面の自動タイマーで「揺れが収まった」と判定しない。
- すべての訓練・デモ画面に、選択言語の訓練表示を置く。接続情報・JSON・API名は通常の案内画面に出さない。
- 通知・地図失敗の表示で、既に保存された案内を操作不能にしない。
- 全国検索中は進行表示を出し、キャンセル可能にする。地図背景が読み込めなくても施設一覧は表示する。
- 色だけで接続や進行状態を伝えない。

## 18. デモの準備・障害時の対応

### 18.1 事前確認

demo:preflightコマンドを用意し、Node版、8788の利用可否、fixtureの妥当性、全登録言語JSONのスキーマ・キー、5行動の画像、2種の署名済みショートカットの存在・チェックサム、公開アセットへのHTTP到達性を検証する。

PC画面ではiPhone接続、5秒ごとのheartbeat、通知許可、アプリ素材バージョンの一致を確認する。helloの次に端末の通知許可状態を送信し、許可がない場合は準備未完了とする。

会場と同じネットワークでリハーサルする。会場Wi-FiでTunnel接続不可なら、実績のあるiPhoneテザリングへ切り替える。新しい公開originに変わった場合は接続URLとショートカットの素材URLを更新する。

### 18.2 障害別の動作

| 障害 | 処理 |
| --- | --- |
| 地震APIの失敗 | last-good、fixtureへ自動切替して継続 |
| 外部APIが遅い | 3秒で打切り、保存データで継続 |
| iPhone未接続・生存報告停止 | 開始不可。ロック解除・アプリ再接続・Xcode状態を確認 |
| ACK紛失 | 同じrunIdで1回だけ再送。二重通知しない |
| 素材配信が不通 | 事前に検証したローカルPNG版ショートカットへ切替 |
| Live Activityが無効・開始不可 | アプリと通知・壁紙で継続。状態を成功扱いしない |
| 言語JSONの取得・検証失敗 | 正常な同梱／キャッシュを保持。案内中は更新しない |
| ショートカットが動かない | 手動実行・通知対象・ロック中許可を確認 |
| 会場ネットワーク全断 | アプリ内訓練で一連の体験を実演。PCからの実接続に成功したとは説明しない |
| 実機の故障・実行不能 | 事前収録した同じ手順の動画をバックアップとして再生 |

ネットワーク・OS・実機を含めた失敗ゼロは保証できない。仕様として確約するのは、外部地震APIの失敗だけでデモ体験を止めないこと、および失敗の種類に応じて復旧手段を用意することである。

### 18.3 デモ終了

アプリの「訓練を終了」でセッションをcompletedにし、保留通知を取り消してLive Activityを即時終了する。PC実行表示はreset可能にする。壁紙はユーザーが元のロック画面に戻す。次の実行を開始する前に端末のreadyを確認する。

## 19. ログと成功判定

Macはartifacts/demo/YYYY-MM-DD.jsonlへ、runId、source、APIの元ID・発表時刻、取得開始・終了、フォールバック理由、送信、ACKを記録する。端末の住所・現在地・接続トークン・完全なペアリングURLは記録しない。

端末は直近100件の診断を保持し、設定からコピーできる。ログは受信・保存・通知予約・アプリ画面復帰を区別する。

- PCでAPIが成功した：実際にHTTP 200と妥当な原文を取得した場合のみ。
- PCで送信した：WebSocketへ送出しただけ。
- 通知予約が完了した：端末からscheduledまたは対応するduplicate ACKがあった場合。
- 壁紙・画面点灯が成功した：実機で目視した結果を受入記録へ記入する。Live Activityの開始・更新・終了はActivityKitの結果と実表示を分けて記録する。
- アプリ復帰が成功した：対象sessionIdとphaseが表示されたことを確認する。

観測できない動作を自動的に成功にしない。

## 20. テストと受入条件

### 20.1 自動テスト

Node：本番API正常、タイムアウト、HTTPエラー、壊れたJSON、空配列、異なるcode、last-good採用、fixture採用、両方不正での事前確認失敗、API原時刻保持、sourceの正確性、Host／Origin／トークン検証、二重開始拒否、ACK対応、同じrunId再送、heartbeat期限切れ、552の対象区・grade・取消・重複・期限・空配列、画像準備→通知送信の順序、地震・津波別URL、言語manifest自動生成・不正パス拒否・署名済み配布物の検証。

Swift：Codable契約、時刻・言語・modeの検証、未許可通知の拒否、保存失敗時に通知しないこと、重複受信、別セッション中の拒否、状態保存・復元、アプリ起動経路3種類、案内遷移・3枚同時表示、LiveActivityIntentの冪等性・古いrevision拒否・津波優先・避難開始で即時終了・重複開始なし・4KB上限、言語JSON追加で一覧反映・更新失敗時の正常版維持、ランダム訓練の5〜15秒範囲、全国データ災害フィルター・距離順・IDタイブレーク、経路失敗時の表示、住所破棄、多言語キーの完全性。

全画面の画像比較のような脆いテストではなく、契約・保存・状態遷移・失敗時の分岐を優先する。通信・MapKit・通知はprotocolで置換して決定的にテストする。

### 20.2 実機受入試験

発表用Mac・iPhone・署名・ショートカットで以下を記録する。

1. 初期設定を完了し、4枠または候補なしの状態を保存できる。
2. Swift版でロック後15秒・1分・3分の生存報告を確認する。
3. 本番APIから取得したデータで、ロック中の通知→地震壁紙→解除後の同じprotect画面→次のロック画面のLive Activityまで進む。
4. iPhoneを触る前に画像が見え、音声案内が再生されないことを確認する。Live Activityの確認操作で同じ画面内に3枚と「安全でないと感じたら」が表示されることを確認する。
5. 外部APIだけを意図的に失敗させ、last-goodとfixtureの両方で継続する。運営用sourceが正しいことを確認する。
6. 同じrunIdの再送で二重通知・案内の初期化が起きない。
7. 同じ地震情報を別runIdで3回連続実演し、毎回終了・再開できる。
8. 英語・日本語・韓国語でアプリ・通知本文・Live Activityの言語がそろう。第4の言語JSONを追加・取得するだけでコード変更なしに一覧へ反映でき、案内中に文言が混ざらない。
9. 通常訓練はAPIにアクセスせず、ロック後に通知される。
10. 津波通知は確認ボタンを待たず壁紙・既存Live Activity・保存状態を津波へ更新する。552の取得成功と明示的な訓練を区別し、取消を避難開始の起点にしない。津波非対応施設を出さない。
11. Google Mapsへの外部リンクが、Google Mapsアプリあり・なしの双方で動く。アプリ内ナビがないことを確認する。
12. ネット不通でも同梱文言と保存済み避難場所・全国距離検索が動く。
13. Xcode停止後の通常起動は別の対照実験として記録し、デバッグ中の成功と混ぜない。
14. Live Activityから「安全でないと感じたら」で必要な認証後に家／学校／その他へ入り、避難先へ向かう確定でActivityが消える。
15. Activityの許可オフ、未開始での津波受信、消去後の復帰、津波と確認操作の競合、終了後の再描画を確認する。
16. 一括導入ページから2種を追加・有効化し、必要な手動操作・署名・origin更新・ローカルPNG版を実機確認する。追加ボタン1回だけで無断設定できたとは説明しない。

解除後のアプリ起動に追加タップが必要なら、そのOS上の実操作をdocs/shortcuts.mdへ記録する。「完全無操作」の達成を勝手に宣言しない。壁紙・アプリを開く設定とオートメーション有効化はユーザーが担当し、アプリAIは連携境界と実際の結果を記録する。

## 21. 実装順と成果物

### フェーズ0：共通契約

contracts/、Swift Codableモデル、cards.json・言語パッケージ・ActivityAttributesのスキーマ、SessionStore protocol、MockDeliveryService、フォルダと所有者を作る。両者が同じサンプルをデコードできることを確認する。

### フェーズ1：Swift版で縦に通す

最小SwiftUI画面、接続設定、Swift受信、状態保存、通知、再起動時のprotect表示までを作る。既存の成功済み検証版と同じ端末で比較する。両者の統合をこの段階で行う。

### フェーズ2：デモの堅牢化とショートカット

1サーバー、APIフォールバック、開始1ボタン、素材配信、受入ログを実装する。ユーザー設定済みショートカットで地震／津波壁紙・アプリ起動・ショートカット一括導入を実機確認する。

### フェーズ3：アプリ体験

言語、初期設定、4枠保存、手動開始、ランダム訓練、安全確認、津波訓練、全国検索、MapKit、Google Mapsリンク、Live ActivityとApp Intents、言語パッケージ更新を接続する。Bはフェーズ1・2と並行してMockDeliveryServiceで実装できる。

### フェーズ4：発表固定

素材とfixtureを固定し、発表端末で受入試験を実施する。録画バックアップ、ローカル素材ショートカット、ネット切替手順を準備する。以後、Bundle IDや通知titleを変更しない。

必須成果物：起動可能なSwiftアプリ、Macサーバー、PC画面、全言語JSON、5行動の画像・壁紙2種・署名済みショートカット一式・Live Activity拡張、全国避難場所データと出典manifest、fixtureと出典、共通契約、テスト、署名・起動・ショートカット・リハーサルの手順。翻訳内容・ピクトグラムの意味の未レビュー箇所はレビュー表に明記し、公開前に各言語の担当者が確認する。

## 22. 実装AIへの共通指示

- この仕様の機能を実装し、別のプラットフォームや通知方式へ独断で置き換えない。
- 担当AとBは一つのSwiftアプリを共有する。別アプリを生成して後で統合する方式にしない。
- 音声案内は実装しない。通知・壁紙・案内状態・Live Activityの処理を二重に実装せず、SessionStoreを正本にする。
- Live Activityと必要なWidgetKit拡張は本仕様どおり追加する。アプリ内ナビ、通常Widget、バックグラウンド位置情報、無音ループ再生、ログイン、課金機能は追加しない。
- テスト用データは契約に従い、サンプルであることをコード・運営用ログで識別する。
- 地震APIの失敗は規定のデータフォールバックで処理する。正常取得の偽装や発表時刻の改変をしない。
- 画面だけの完成で終了しない。通知→状態保存→起動→案内の接続を確認する。
- iPhoneがない環境で、ロック中・ショートカット・Live Activityの操作や表示を検証済みと報告しない。
- 実装の通常の選択は本書に従って進める。新しい外部サービスの導入、本改訂以外の共有契約変更、新たな音声案内の追加、災害情報の意味変更が必要な場合は実装を進める前に人へ確認する。
- 完了報告には変更、実行した検証、実機確認が必要な項目、起動コマンドを含める。

## 23. 参照情報

- ユーザー体験：Notionの「Nigeyoユーザー体験」。本書の確定方針（MapKit、音声案内なし、5行動のピクトグラム、Live Activity、拡張可能な言語JSON、アプリ内ナビなし）が技術実装上の優先仕様。
- P2P地震情報API：https://github.com/p2pquake/epsp-specifications/blob/master/json-api-v2.yaml
- Appleのローカル通知：https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app
- Xcode接続時の停止挙動：https://developer.apple.com/forums/thread/132078
- SwiftUI URL受信：https://developer.apple.com/documentation/swiftui/view/onopenurl(perform:)
- MapKit徒歩距離：https://developer.apple.com/documentation/mapkit/mkdirections
- Google Maps URL：https://developers.google.com/maps/documentation/urls/get-started
- 国土地理院の指定緊急避難場所：https://www.gsi.go.jp/bousaichiri/hinanbasho

既存の実装参照：`server/quake-history.mjs`、`server/native-remote.mjs`、`ios/App/App/SceneDelegate.swift`、`NATIVE-REMOTE-TEST.md`。現行実装のファイルをそのまま完成版と見なさず、契約v2・純Swift構成に移植する。

### 23.1 本改訂の技術根拠と検証境界

- ActivityKitの開始・更新・終了・4KB上限・表示領域：[Apple ActivityKit](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)
- Button(intent:)と主アプリでのLiveActivityIntent実行：[Apple WidgetKit](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)
- ロック中Intentの認証ポリシー：[Apple App Intents](https://developer.apple.com/documentation/appintents/intentauthenticationpolicy)
- Live Activity利用可否：[Apple ActivityAuthorizationInfo](https://developer.apple.com/documentation/activitykit/activityauthorizationinfo/areactivitiesenabled)
- ショートカット共有と署名：[Apple共有ガイド](https://support.apple.com/guide/shortcuts-mac/share-shortcuts-apdf01f8c054/mac)、[Appleコマンドラインガイド](https://support.apple.com/guide/shortcuts-mac/run-shortcuts-from-the-command-line-apd455c82f02/mac)

JSON言語パッケージの動的登録、UI状態機械、同じSessionStoreへの統合、一括セットアップ導線は本プロジェクトの設計判断。Live Activityの実装、3言語表示・ロック中ボタン・終了・津波更新、ショートカットの共有形式と一括導入は新規受入試験であり、既存の壁紙変更実証だけで成功扱いしない。
