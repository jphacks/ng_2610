# AWSから訓練通知を送る

発表担当者がAWS CLIからLambdaを呼び出すと、APNs経由で発表用iPhone 1台に
地震または津波の訓練通知を送る。送信先はSecrets Managerの設定で固定する。
送信担当者のIAMロールには、この関数の呼び出し権限だけを追加する。

## ローカル検証

リポジトリのルートでNode.js 24を使う。模擬APNsで通知内容と署名を確認する。

```sh
npm ci --prefix aws/apns-training
node --test aws/apns-training/index.test.mjs
sam validate --lint --template-file aws/template.yaml
```

## 初回セットアップ

1. [#21の手順](acceptance.md#testflight-apns-delivery-21)で、APNs対応のTestFlight版を
   発表用iPhoneに入れ、端末トークンを取得する。Appleのコンソールから先に送信し、
   通知の表示とタップ後のガイドを確認する。
2. Apple DeveloperのAccount Holderが、対象のApp IDとProductionで使えるAPNs署名キーを
   用意する。AWS Secrets Managerで、スタックと同じAWSアカウント・リージョンに
   シークレットを作成する。暗号化には既定のAWS管理キーを選ぶ。以下の5項目を
   JSONの文字列として登録する。

   | キー | 値 |
   | --- | --- |
   | `teamId` | Apple DeveloperのTeam ID |
   | `keyId` | APNs署名キーのKey ID |
   | `privateKey` | `.p8` のPEM全文。JSON内では改行を `\n` で表す |
   | `bundleId` | TestFlight版のBundle ID |
   | `deviceToken` | 発表用iPhoneで取得した16進文字列 |

   秘密鍵と端末トークンはSecrets Managerに直接登録する。端末トークンが変わった場合は
   同じシークレットを更新する。デプロイ時に渡すのはシークレットのARNだけ。
3. AWS CLIとAWS SAM CLIをセットアップし、デプロイできる権限で次を実行する。
   ガイド付きデプロイで、スタック名に `nigeyo-apns`、`APNsSecretArn` に
   シークレットの完全なARN、`OperatorRoleName` に発表担当が利用する既存IAMロールの
   **名前**を指定する。
   訓練と監視は1つのスタックで管理する。訓練から試す場合、監視用パラメーターは既定値のままでよい。
   後から [監視側の配置パラメーター](aws-live-alerts.md#awsに配置する)を同じスタックに追加する。

```sh
sam build --template-file aws/template.yaml
sam deploy --guided
```

## 発表用iPhoneで確認

発表担当のIAMロールで、スタック出力 `TrainingPushFunctionName` の値を使う。
地震ガイドを終了してから、`earthquake` を `tsunami` に置き換えてもう一度実行する。

```sh
training_push_function_name='TrainingPushFunctionNameの出力値'
aws lambda invoke \
  --function-name "$training_push_function_name" \
  --cli-binary-format raw-in-base64-out \
  --payload '{"hazard":"earthquake"}' \
  /tmp/nigeyo-training-push-result.json
cat /tmp/nigeyo-training-push-result.json
```

- `accepted: true` と `apnsStatus: 200` はAppleが送信要求を受け付けた結果。
  ロック中に通知が表示されたか、タップで対応する訓練ガイドが開いたかは、iPhoneで別々に記録する。
- `apnsStatus: 410` なら端末トークンを取り直す。`400` または `403` なら、
  同じTestFlight版のトークン、Bundle ID、Production対応の署名キーを照合する。
- `apns_configuration_unavailable` ならシークレットのARN、Lambdaの読み取り権限、
  JSONの項目を確認する。`apns_transport_failed` の場合は、再送前にiPhoneの通知を確認する。

通知とガイドの有効期限は送信要求から2分。APNsの実機確認が間に合わなければ、
Appleのコンソール送信または既存の端末内訓練を使う。
