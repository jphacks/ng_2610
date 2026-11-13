# AWSから訓練通知を送る

発表担当者がAWS CLIから災害種別と区域を指定すると、APNs経由でその区域を登録した
発表用iPhoneに訓練通知を送る。Secrets Managerに最大4台を登録できる。
送信担当者のIAMロールには、この関数の呼び出し権限だけを追加する。

## ローカル検証

リポジトリのルートでNode.js 24を使う。模擬APNsで通知内容と署名を確認する。

```sh
npm ci --prefix aws/apns-training
node --test aws/apns-training/index.test.mjs
sam validate --lint --template-file aws/template.yaml
```

## アプリで確認した地域を使う

4台のTestFlightデモは [iPhoneの登録手順](aws-live-alerts.md#testflightの4台を登録する) を使う。
`AppRegistrationEnabled=true` では、訓練Lambdaは `LiveSecretArn` の端末一覧とアプリの
登録区域を使う。AWSに区域を転記する必要はない。`LiveEnabled=false` の間も訓練を送信できる。
`APNsSecretArn` は既存のスタック入力なので、共用構成では `LiveSecretArn` と同じARNを指定できる。

## 初回セットアップ

以下は `AppRegistrationEnabled=false` で訓練区域を手動登録する構成。

1. [#21の手順](acceptance.md#testflight-apns-delivery-21)で、APNs対応のTestFlight版を
   発表用iPhone 4台に入れ、端末ごとにトークンを取得する。Appleのコンソールから先に送信し、
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
   | `devices` | 各端末の `id`、`deviceToken`、災害種別ごとの `regions` を持つ配列 |

   `devices` の例。`deviceToken` の例示値は各端末で取得したトークンに置き換える。

   ```json
   [
     {"id":"iphone-1","deviceToken":"0001","regions":{"tsunami":["石川県能登"]}},
     {"id":"iphone-2","deviceToken":"0002","regions":{"tsunami":["石川県能登"]}},
     {"id":"iphone-3","deviceToken":"0003","regions":{"earthquake":["愛知県西部"]}},
     {"id":"iphone-4","deviceToken":"0004","regions":{"tsunami":["宮城県"]}}
   ]
   ```

   訓練では、登録した区域名を完全一致で照合する。`id` とトークンは端末ごとに一意にする。
   既存の単独端末設定は、トップレベルの `deviceToken` と区域指定なしの呼び出しで利用できる。
   4台に切り替えるときは、トップレベルの `deviceToken` を `devices` に置き換える。

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

## 4台で確認する

各iPhoneの「通知対象地域」に表示される区域名を使う。例えば、地震の東京23区は
`東京都２３区`、大阪市は `大阪府北部`、名古屋市は `愛知県西部`、福岡市博多区は
`福岡県福岡`。津波は別の区域名で照合する（例として大阪市の `大阪府`）。
4台の自宅・大学の登録地域が重ならない状態で試す。

発表担当のIAMロールで、スタック出力 `TrainingPushFunctionName` の値を使う。
下の例では、4台を同じ会場でロックしても、大阪府北部を登録したiPhoneだけに送信される。

```sh
training_push_function_name='TrainingPushFunctionNameの出力値'
aws lambda invoke \
  --function-name "$training_push_function_name" \
  --cli-binary-format raw-in-base64-out \
  --payload '{"hazard":"earthquake","region":"大阪府北部"}' \
  /tmp/nigeyo-training-push-result.json
cat /tmp/nigeyo-training-push-result.json
```

- `results` に大阪の端末IDだけが出ることを確認する。`apnsStatus: 200` はAPNsによる受付。
  実機で、ロック中の通知表示、壁紙の切替、タップ後の訓練ラベル付きガイドを別々に記録する。
  東京・名古屋・博多の区域に順に変更し、対象の1台が切り替わることを確認する。
- 津波は `{"hazard":"tsunami","region":"大阪府"}` で確認する。自動監視をオフにした端末は
  次の送信から除外される。場所を変えたら、区域を確認して自動監視をオンにし直す。
- `apnsStatus: 410` なら端末トークンを取り直す。`400` または `403` なら、
  同じTestFlight版のトークン、Bundle ID、Production対応の署名キーを照合する。
- `apns_configuration_unavailable` ならシークレットのARN、Lambdaの読み取り権限、
  JSONの項目を確認する。`apns_transport_failed` の場合は、再送前にiPhoneの通知を確認する。

通知とガイドの有効期限は送信要求から2分。APNsの実機確認が間に合わなければ、
Appleのコンソール送信または既存の端末内訓練を使う。
