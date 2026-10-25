# ng_2610 "nigeyo"

[![IMAGE ALT TEXT HERE](https://jphacks.com/wp-content/uploads/2026/07/IMG_5316.png)](https://www.youtube.com/watch?v=piaNsc6ilBI)

## 製品概要
### 背景(製品開発のきっかけ、課題等）
チーム内に留学生もいたということで、留学生向けの避難・防災アプリを開発しました。世の中にある外国人向けの避難アプリは主に観光客向けだったため、我々と一緒に暮らす留学生に特化したアプリです。

### 製品説明（具体的な製品の説明）
地震・津波のとき、言葉に頼らずに「次の一歩」を示すiPhoneアプリです。通知を受けると、ショートカットがロック画面の壁紙を行動ピクトグラムに切り替え、Live Activityで「頭を守る → 3つの安全確認 → 避難場所」へ案内します。避難場所は国土地理院の指定緊急避難場所（全国約10万件）から、地震・津波それぞれに対応した施設だけを提示し、経路はGoogle Mapsへ引き渡します。

### 特長
#### 1. 言葉より先に、絵で伝える
5つの行動ピクトグラム（頭を守る・安全確保・火を消す・扉を開ける・高台へ）を全言語で共有し、ロック画面の壁紙とLive Activityに表示します。
#### 2. 言語はJSONを1つ足すだけ
英語・日本語・韓国語を同梱。言語パッケージ（JSON）を追加すると、コードを変えずに一覧へ反映されます。
#### 3. 地震と津波で避難先を分ける
自宅・学校 × 地震・津波の4枠を事前に保存。津波時は津波対応施設だけを示し、オフラインでも検索できます。

### 解決出来ること


### 今後の展望
### 注力したこと（こだわり等）
* 
* 

## 開発技術
### 活用した技術
#### API・データ
* P2P地震情報 API（地震 551・津波 552、取得失敗時は last-good → 実データfixtureへ自動フォールバック）
* 国土地理院 指定緊急避難場所データ（全国CSV → アプリ同梱JSON）
* Google Maps URL（徒歩経路の外部引き渡し）

#### フレームワーク・ライブラリ・モジュール
* Swift 6 / SwiftUI / Observation / ActivityKit・WidgetKit（Live Activity, Dynamic Island）/ App Intents / UserNotifications / MapKit / CoreLocation
* Node.js（node:http, ws）、Cloudflare Tunnel、iOSショートカット

#### デバイス
* iPhone（iOS 27以上）
* Mac（デモサーバー・操作画面）

### 独自技術
#### ハッカソンで開発した独自機能・技術
* 独自で開発したものの内容をこちらに記載してください
* 特に力を入れた部分をファイルリンク、またはcommit_idを記載してください。

## 動かし方
* セットアップ・デモ手順: [docs/setup.md](docs/setup.md)
* ショートカット: [docs/shortcuts.md](docs/shortcuts.md)
* 実機受入記録: [docs/acceptance.md](docs/acceptance.md) / 翻訳レビュー表: [docs/translation-review.md](docs/translation-review.md)
* 通信契約: [contracts/messages.md](contracts/messages.md) / 仕様: [NIGEYO-TECH-SPEC.md](NIGEYO-TECH-SPEC.md)

```sh
npm ci && npm run demo:prepare && npm run demo:server   # Mac
open nigeyo-ios/Nigeyo.xcodeproj                         # iPhone (scheme: Nigeyo)
```
