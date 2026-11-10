# 生活拠点の通知区域

初期設定または「場所を設定し直す」で選んだ自宅・大学のピンから、地震の細分区域と
津波予報区を提案する。地震はピンと細分区域の境界、津波はピンが入る市区町村と
沿岸市町村対応表を照合する。候補が複数の場合は選択してから保存する。
対応表に候補がない場合は「候補なし」と表示し、安全判定には使わない。
選択した生活拠点の住所・座標は保存せず、確認済みの区域IDを生活拠点ごとに保存する。
避難先施設の変更は通知区域に影響しない。以前の設定を生活拠点から作り直すには、
自宅・大学を選び直す。

AWSへ確認済み設定を渡す場合、バージョン2の対象には区域IDと、表示・P2P地震情報の
照合に使う公式名を含める。ワーカーはIDと公式名の対応を検証する。
既存のバージョン1の愛知の購読も扱う。

大会用の4台の訓練配信（[#28](https://github.com/jphacks/ng_2610/issues/28)）では、
診断ログから確認済み設定をコピーし、端末ごとの `regions.earthquake` に
`earthquakeAreaId`、`regions.tsunami` に `tsunamiAreaIds` の値を設定する。
送信時の `region` にも同じIDを指定する。

## 出典とデータの再生成

気象庁の以下の資料を加工して作成。GISの座標系はJGD2011。
境界を簡略化して同梱し、境界付近では隣接する区域も候補にする。
市町村GISにコード付き境界がない地点は、確認画面で候補を手動選択できる。
地震の候補も取得できない場合、生活拠点を通知先に登録せずに初期設定を続けられる。
地図データの出典と承認番号は[気象庁のGIS一覧](https://www.data.jma.go.jp/developer/gis.html)を参照。

| 入力ファイル | 気象庁資料 |
| --- | --- |
| `quake.zip` | [地震情報／細分区域](https://www.data.jma.go.jp/developer/gis/20240520_AreaForecastLocalE_GIS.zip) |
| `city.zip` | [市町村等（地震津波関係）](https://www.data.jma.go.jp/developer/gis/20241128_AreaInformationCity_quake_GIS.zip) |
| `tsunami.zip` | [津波予報区](https://www.data.jma.go.jp/developer/gis/20240520_AreaTsunami_GIS.zip) |
| `shindo.html` | [緊急地震速報や震度情報で用いる区域の名称](https://www.jma.go.jp/jma/kishou/know/jishin/joho/shindo-name.html) |
| `tsunami.pdf` | [津波予報区と沿岸市町村の対応表（2026年3月26日）](https://www.jma.go.jp/jma/kishou/know/jishin/joho/tsunami-yohoku/tsunami_shichouson.pdf) |

Python環境に `pyshp<3`、`shapely`、`pdfplumber` を用意して、リポジトリのルートで実行する。

```sh
python scripts/build-notification-regions.py /path/to/jma-inputs nigeyo-ios/Nigeyo/Resources
```
