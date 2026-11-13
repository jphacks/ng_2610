# AWSで実災害の通知を受ける

ECS FargateのワーカーがP2P地震情報のWebSocketに常時接続し、既存の登録地域判定で
緊急地震速報と津波警報・注意報を選別する。対象の警報はAPNs経由でiPhoneに表示する。
通知をタップすると、iPhoneが有効期限と現在の登録地域を照合し、緊急地震速報または
津波警報のガイドを訓練ラベルなしで開く。津波注意報は通知のみ。
手動の訓練送信は[別のLambda](aws-training-push.md)で行う。

## TestFlightの4台を登録する

1. 下の手順でAWSに配置し、`AppRegistrationEnabled=true` を設定する。スタック出力
   `LiveRegistrationUrl` のホスト名を `nigeyo-ios/Local.xcconfig` の
   `NIGEYO_LIVE_REGISTRATION_HOST` に設定する。Push Notifications対応のApp IDで
   `NIGEYO_APNS_ENTITLEMENTS = Config/Nigeyo.entitlements` を有効にしてTestFlightへ配布する。
2. 各iPhoneで通知とロック画面表示を許可する。「設定 → 診断ログ」で **Register for APNs** を
   実行し、**Copy APNs device token** で端末トークンを取得する。
3. `LiveSecretArn` で指定したSecrets Managerシークレットに、APNsの `teamId`、`keyId`、
   `privateKey`、`bundleId` と、端末の `devices` を登録する。最大4台で、`id` と
   `deviceToken` はそれぞれ一意にする。下の `deviceToken` は各端末で取得した値に置き換える。

   ```json
   [
     {"id":"tokyo","deviceToken":"TOKEN_FROM_TOKYO_IPHONE"},
     {"id":"osaka","deviceToken":"TOKEN_FROM_OSAKA_IPHONE"},
     {"id":"nagoya","deviceToken":"TOKEN_FROM_NAGOYA_IPHONE"},
     {"id":"hakata","deviceToken":"TOKEN_FROM_HAKATA_IPHONE"}
   ]
   ```

4. 各iPhoneで「設定 → 通知対象地域」を開き、自宅・大学の区域名を確認する。
   「自動監視を有効にする」をオンにして、「本番通知の配信先に登録済み」の表示を確認する。
   AWSはこの区域を訓練と本番の両方に使う。同じ地域を自宅と大学に登録しても通知は端末につき1件。
5. 同じ画面で本番用の地震・津波ショートカットを追加する。ショートカットアプリで
   対象をNigeyoにして「すぐに実行」を選び、手動で一度ずつ実行して壁紙変更を許可する。
   [ショートカットの手順](shortcuts.md#本番用ショートカット)
6. [訓練通知](aws-training-push.md#4台で確認する)で対象端末だけが受信することを確認した後、
   `LiveEnabled=true` で本番フィードの監視を開始する。

切替をオフにすると、そのiPhoneはAWSの地域別訓練と本番配信の両方から外れる。
訓練は最新の登録を直接参照する。稼働中の本番ワーカーは約3秒ごとに登録を取り込み、
送信の直前にも照合する。端末やトークンを交換したらシークレットを更新し、ECSタスクを
再起動した上で対象端末から登録し直す。トークンは購読更新の認証にも使うため、AWSに登録する
担当者にだけ渡す。

以前の単一端末構成はトップレベルの `deviceToken` を引き続き利用できる。
`devices` に移行した場合は各iPhoneで自動監視をオンにし直す。`AppRegistrationEnabled=false`
の従来の手動本番構成では、`deviceToken` と診断ログからコピーした `subscription` を使う。

## AWSに配置する

リポジトリのルートからDockerイメージをビルドし、デプロイ先と同じリージョンの
既存ECRリポジトリにプッシュする。

```sh
worker_image='ECRリポジトリのURI:regional-worker'
docker buildx build --platform linux/amd64 -f aws/Dockerfile.regional -t "$worker_image" --push .
```

訓練と同じ [template.yaml](../aws/template.yaml) を [SAMの手順](aws-training-push.md#初回セットアップ)で
配置する。 `WorkerImage` はECRのダイジェスト付きURI、`LiveSecretArn` は監視用シークレットのARN。
`VpcId` と、インターネットゲートウェイへの経路がある `PublicSubnet` を指定する。
最初は `LiveEnabled=false` のまま訓練を確認し、実配信の開始時に同じスタックを
`LiveEnabled=true` に更新する。監視の有効化は発表用端末と対象地域を確認してから行う。

ECSは監視タスクを1個起動する。ワーカーは外部からの接続を受け付けず、端末ごとの判定状態と
送信待ちの通知を非公開・暗号化済みS3バケットの `regional-monitor.json` に保存する。
同時に複数の監視タスクを起動しない。状態の読み込みに失敗すると起動を中止し、
保存に失敗した新規警報はAPNsへ渡さずCloudWatch Logsに記録する。
スタックを削除しても状態バケットは保持する。

## 確認方法と範囲

```sh
npm ci --prefix aws
npm ci --prefix aws/apns-training
node --test aws/apns-training/index.test.mjs aws/live-registration.test.mjs aws/regional-worker.test.mjs
sam validate --lint --template-file aws/template.yaml
```

ローカルテストでは、警報の再生を模擬フィードと模擬APNsの間だけで行う。
対象地域の警報が送信され、対象外、訓練フラグ付き、期限切れ、重複、取り消しが
警報として送信されないこと、再起動後も保存済みの状態が使われることを確認する。実機では署名済みの同じビルドを使い、
隔離したテスト環境で、ロック中の表示とタップ後のガイドを別々に確認する。

対象は緊急地震速報（556）と津波警報・注意報（552）。地震情報（551）は壁紙変更を起動しない。
地域は[区域ID付きの購読設定](notification-region-data.md)で照合する。
単一タスク・単一サブネットのため更新時などに短い監視中断があり、
フィード切断中の警報は取り直さない。[P2P地震情報の仕様](https://www.p2pquake.net/develop/json_api_v2/)では配信品質が無保証で、障害時の再配信もない。APNs受付は端末への到着を保証しない。また、APNsが受け付けてから送信済みの状態を保存するまでに障害が起きると、再送する可能性がある。
期限は発表時刻から2分で、APNsに渡した通知を後から取り消す経路はない。
壁紙切り替えは別途実機で検証する。
