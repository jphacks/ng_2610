# AWSで実災害の通知を受ける

ECS FargateのワーカーがP2P地震情報のWebSocketに常時接続し、既存の登録地域判定で
緊急地震速報と津波警報・注意報を選別する。対象の警報はAPNs経由でiPhoneに表示する。
通知をタップすると、iPhoneが有効期限と現在の登録地域を照合し、緊急地震速報または
津波警報のガイドを訓練ラベルなしで開く。津波注意報は通知のみ。
手動の訓練送信は[別のLambda](aws-training-push.md)で行う。

## 発表用iPhoneの登録

1. この変更を含むAPNs対応TestFlight版を入れ、通知とロック画面表示を許可する。
   アプリの「通知対象地域」で自宅・学校の地域を確認して自動監視を有効にする。
2. 「設定 → 診断ログ」で **Register for APNs** を押し、端末トークンを取得する。
   **Copy confirmed notification regions** で確認済み地域のJSONも取得する。
3. 訓練用とは別のSecrets Managerシークレットを作成する。APNsの署名設定は
   [訓練送信の設定](aws-training-push.md#初回セットアップ)と同じ。送信先は単独端末の
   `deviceToken` をトップレベルに設定する。
   コピーした地域JSONを `subscription` キーの値としてオブジェクトのまま追加する。
   キー・トークン・地域JSONはAWSコンソールで直接登録する。
4. 端末や登録地域を変更したらシークレットを更新し、ECSサービスを再デプロイする。
   AWS側の登録は手動なので、配信停止はスタックの `LiveEnabled=false` で行う。
   既存のWebSocketデモサーバーへの接続は解除しておくと、二重配信を避けられる。

## アプリから配信登録する（事前設定済みの1台）

本番用の端末を初回に1台指定すれば、そのiPhoneで「通知対象地域」のスイッチを
切り替えるだけで、確認済み区域の登録・解除ができます。

1. 本番用シークレットに署名設定と対象iPhoneの `deviceToken` を登録します。
   アプリから登録する構成ではシークレットに `subscription` を入れる必要はありません。
2. 更新したワーカーイメージを使い、`AppRegistrationEnabled=true` でSAMスタックを更新します。
   実際の警報を監視するには `LiveEnabled=true` が別途必要です。登録APIはこの設定がオフでも利用できます。
3. スタック出力 `LiveRegistrationUrl` のホスト名を
   `nigeyo-ios/Local.xcconfig` の `NIGEYO_LIVE_REGISTRATION_HOST` に設定して、
   APNs対応のTestFlightビルドを配布します。
4. アプリで区域を確認してスイッチをオンにし、「本番通知の配信先に登録済み」と表示されることを確認します。
   オフにすると登録が解除されます。ワーカーは約3秒ごとに設定を取り込みます。

APIは登録済み端末のAPNsトークンを認証に使い、同じ端末への購読更新だけを許可します。
端末を交換したりAPNsトークンが変わったりした場合は、本番用シークレットを更新してワーカーを再デプロイしてください。
その後、新しい端末で購読を再登録します。オートメーションによる壁紙変更は
[ショートカットの設定](registered-region-monitoring.md#残る制約)も必要です。

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

ECSは監視タスクを1個起動する。外部からの接続は受け付けず、地域ごとの判定状態と
送信待ちの通知を非公開・暗号化済みS3バケットの `regional-monitor.json` に保存する。
同時に複数の監視タスクを起動しない。状態の読み込みに失敗すると起動を中止し、
保存に失敗した新規警報はAPNsへ渡さずCloudWatch Logsに記録する。
スタックを削除しても状態バケットは保持する。

## 確認方法と範囲

```sh
npm ci --prefix aws
npm ci --prefix aws/apns-training
node --test aws/apns-training/index.test.mjs aws/regional-worker.test.mjs
sam validate --lint --template-file aws/template.yaml
```

ローカルテストでは、警報の再生を模擬フィードと模擬APNsの間だけで行う。
対象地域の警報が送信され、対象外、訓練フラグ付き、期限切れ、重複、取り消しが
警報として送信されないこと、再起動後も保存済みの状態が使われることを確認する。実機では署名済みの同じビルドを使い、
隔離したテスト環境で、ロック中の表示とタップ後のガイドを別々に確認する。

この構成は発表用iPhone 1台を対象とする。全国の生活拠点を設定した端末は
[区域ID付きの購読設定](notification-region-data.md)を使う。
単一タスク・単一サブネットのため更新時などに短い監視中断があり、
フィード切断中の警報は取り直さない。APNs受付は端末への到着を保証しない。また、APNsが受け付けてから送信済みの状態を保存するまでに障害が起きると、再送する可能性がある。
期限は発表時刻から2分で、APNsに渡した通知を後から取り消す経路はない。
壁紙切り替えは別途実機で検証する。
