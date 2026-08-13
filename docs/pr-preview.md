# PR プレビュー環境の設計

app リポジトリの Pull Request ごとに、その PR のコードが動く URL を自動で用意する
ための設計メモです。**まだ実装されていません。** 実装前に方針を固めるための文書で、
決めたことと、検討して採らなかった案の理由を残しています。

- 対象リポジトリ: `prtimes-hackathon-2026/app`
- 前提: このリポジトリが既に作っている共有基盤（VPC / ALB / ECS クラスター / RDS）に
  相乗りする

## 完成形

PR #123 を開くと `https://pr-123.preview.example.com` が生え、PR にコメントで URL が
付きます。push するたび入れ替わり、PR を閉じると消えます。

```
app に PR #123 を open / push
  └─ build   : ghcr.io/.../app:pr-123 と app-migrator:pr-123 を publish
     └─ preview: (needs: build) TFC の変数 preview_pull_requests に
                 {number = 123, image_tag = "pr-123"} を追加
                 → aws-preview ワークスペースの run を起動 (auto-apply)
                    └─ Terraform が PR 123 用の TG / リスナールール / ECS サービスを作る
                       └─ タスク起動時に bootstrap → migrate → app の順にコンテナが走る
     └─ comment: https://pr-123.preview.example.com を PR にコメント

PR #123 を close
  └─ preview: 変数から 123 を取り除いて run 起動 → 該当リソースだけ destroy
```

> `example.com` はプレースホルダです。実際に使うドメインが決まったら
> `preview_domain` 変数の既定値として置きます。

## 全体構成

| レイヤ | 置き場所 | 中身 |
| --- | --- | --- |
| 共有基盤 | 既存ワークスペース `aws` | VPC / ALB / HTTPS リスナー / ECS クラスター / ACM / Route 53 / プレビュー用 RDS と管理者シークレット |
| PR ごとのリソース | 新ワークスペース `aws-preview` | ターゲットグループ / リスナールール / タスク定義 / ECS サービス / シークレット / ロググループ |
| 制御 | app リポジトリの GitHub Actions | イメージの publish と、TFC API 経由の変数更新・run 起動 |

ALB・ECS クラスター・RDS インスタンス・サブネット・SG は**すべて共有**し、PR ごとに
作るのは軽いリソースだけにします。PR あたりの起動時間は 1〜2 分、実費は 1 日 ¥50 前後
（Fargate Spot なら ¥20 前後）に収まります。

### ルーティングはホストベース

共有 ALB の HTTPS リスナーに、PR ごとのリスナールールを 1 本ずつ足します。

| 項目 | 値 |
| --- | --- |
| 条件 | `host-header = pr-<番号>.preview.example.com` |
| 優先度 | `1000 + PR 番号` |
| アクション | forward → PR 用ターゲットグループ |

DNS は `*.preview.example.com` の A (ALIAS) レコード 1 本を ALB に向けるだけで、
PR ごとにレコードを作る必要はありません。証明書も `*.preview.example.com` の
ワイルドカード 1 枚で済みます（ワイルドカードは 1 ラベル分だけ対応するので、
`pr-123.preview.example.com` はカバーされます）。

同時プレビュー数の上限は**リスナールールのクォータ 100 件**です。ハッカソン規模なら
十分ですが、優先度に PR 番号をそのまま足しているため、PR 番号が 49000 を超えると
（クォータ上限 50000 に当たって）破綻します。実質的には起こりません。

### PR ごとに作るリソース (`modules/preview`)

| リソース | 名前 | 備考 |
| --- | --- | --- |
| `aws_lb_target_group` | `webapp-pr-123` | `deregistration_delay = 15`。ヘルスチェックは共有側と同じ `/api/health` |
| `aws_lb_listener_rule` | — | 上記のホストヘッダ条件 |
| `aws_cloudwatch_log_group` | `/ecs/webapp-preview/pr-123` | 保持 3 日 |
| `aws_secretsmanager_secret` | `webapp-preview/pr-123/app-db-url` | PR 専用ロールでの接続 URL。PR のコードに渡すのはこれだけ |
| `aws_ecs_task_definition` | `webapp-pr-123` | 256 CPU / 512 MiB。`bootstrap` + `migrate` + `app` の 3 コンテナ |
| `aws_ecs_service` | `webapp-pr-123` | `desired_count = 1`、`FARGATE_SPOT` |

SG・サブネット・タスクロール・実行ロールは共有基盤のものをそのまま使います。
ECS タスク用 SG (`webapp-dev-ecs-tasks`) を再利用するので、**プレビュー環境も統計 DB に
到達できます**。統計 DB は参照専用の使い方なので許容していますが、書き込みを伴う機能を
足すときは別 SG に分けてください。

Fargate Spot は中断される可能性がありますが、プレビュー用途では許容します（クラスターの
capacity provider には `FARGATE_SPOT` が既に登録済みです）。

## DB は PR ごとに分ける

プレビュー専用の RDS インスタンスを 1 台立て、その中に **PR ごとの database**
(`pr_123`) を切ります。

| | 選択 | 理由 |
| --- | --- | --- |
| インスタンス | 新規 `webapp-preview-db` (db.t4g.micro / gp3 20GiB) | 開発用 DB と巻き添えを分ける。追加費用は月 $15 前後 |
| database | PR ごと (`pr_123`) | マイグレーションを含む PR が他のプレビューを壊さない |
| DB ロール | PR ごと (`pr_123`)。自分の database にしか権限を持たない | PR のコードに管理者資格情報を渡さないため（下記） |
| 接続情報 | Terraform が URL を組み立てて Secrets Manager へ | 共有基盤の `APP_DATABASE_URL` と同じ方式 |
| 管理者 URL | 共有基盤側に 1 つ (`webapp-preview/admin-db-url`) | bootstrap コンテナだけが受け取る |
| 統計 DB | 既存を共有 | 参照専用のため |

パスワードの平文が Terraform state に入る点は共有基盤と同じトレードオフです
（README の「アプリ用 DB のパスワードは Terraform state に入ります」参照）。

### database とロールの作成は bootstrap コンテナが行う

ここが設計上いちばん悩んだところです。**Terraform Cloud は SaaS なので、プライベート
サブネットにいる RDS に到達できません。** つまり `postgresql` provider で
`CREATE DATABASE` を実行することはできず、マイグレーションも同様です。

採る方式は、**PR 用タスク定義にコンテナを 3 つ積み、ECS のコンテナ依存関係
(`dependsOn` の `SUCCESS` 条件) で順に走らせる**やり方です。

```
タスク起動
  ├─ bootstrap コンテナ            ← main からビルドした固定イメージ (:main)
  │    ADMIN_DATABASE_URL（プレビュー RDS の管理者）と、
  │    APP_DATABASE_URL（PR 用ロールの URL。ここから名前とパスワードを取る）を受け取り、
  │    1. pr_123 database が無ければ CREATE DATABASE
  │    2. pr_123 ロールが無ければ CREATE ROLE（パスワードは Terraform が生成）
  │    3. pr_123 database にだけ権限を GRANT
  │    4. exit 0
  ├─ migrate コンテナ (dependsOn: bootstrap = SUCCESS)   ← PR のコード
  │    APP_DATABASE_URL に対して drizzle-kit migrate → exit 0
  └─ app コンテナ (dependsOn: migrate = SUCCESS)          ← PR のコード
       node server.js
```

**管理者資格情報を受け取るのは bootstrap だけ**で、これは main からビルドした固定
イメージです。PR 由来の migrate / app に渡すのは `pr_123` ロールの URL だけなので、
ある PR のコードが他の PR の database を読み書きすることはできません。database を
分けることが、単なる名前空間ではなく**認可境界**として成立します。

同一タスク内でも ECS の `secrets` はコンテナごとに解決されるため、bootstrap の環境変数を
app のコードから読むことはできません。加えて、管理者シークレットの `GetSecretValue` は
**タスク実行ロールにだけ許可し、タスクロールには許可しません**。コンテナのコードが
使えるのはタスクロールの資格情報なので、AWS API 経由で管理者 URL を取り直すことも
できません。

Terraform だけで完結するのも利点です。GitHub Actions から `ecs run-task` を叩く必要が
なく、Actions に AWS の権限を一切渡さずに済みます。bootstrap や migrate が失敗すれば
タスクは起動せず、デプロイサーキットブレーカーが働きます。

タスクが起動するたびに bootstrap と migrate が走りますが、どちらも冪等です。イメージ
pull の分、起動が 30〜40 秒延びます。

**app リポジトリ側に必要な変更**: 現在の `Dockerfile` は `output: 'standalone'` の
ランタイムイメージで、`drizzle-kit` を含んでいません。`migrator` ステージ
（devDependencies と `drizzle/` を含む）を足し、`ghcr.io/.../app-migrator` として
publish する必要があります。bootstrap は同じ `migrator` イメージの `:main` タグを
エントリポイントだけ変えて流用すれば足り、3 つめのイメージは要りません。

### 後片付けは PR の database とロールを残します

PR を閉じても `pr_123` の database とロールは残ります。Terraform から
`DROP DATABASE` を実行する手段がない（同じ到達性の問題）ためです。空の database は
ほぼ無料なので放置でも構いませんが、気になるなら後述のスイーパーで
EventBridge Scheduler → `ecs run-task` を組み、開いていない PR のものを落として
ください。この掃除タスクも管理者資格情報を使うので、bootstrap と同じく main 由来の
イメージで動かします。

## 制御プレーン: ワークスペースを分ける

PR ごとのリソースは `aws-preview` という**2 つめの TFC ワークスペース**が持ちます。

- 共有基盤の plan が PR の開閉のたびに走らない
- プレビューの apply が失敗しても、共有基盤の state に影響しない
- Actions に渡す TFC トークンを、このワークスペースだけに絞れる

`aws-preview` 側は変数 1 つで駆動します。

```hcl
variable "preview_pull_requests" {
  type = list(object({
    number    = number
    image_tag = string
  }))
  default = []
}
```

これを `for_each` して `modules/preview` を呼びます。**PR ごとにワークスペースを
作らない**のがポイントで、state が散らからず、リストから要素を消すだけで destroy に
なります。

共有基盤の値（リスナー ARN、クラスター名、SG、サブネット、ロール ARN など）は
`tfe_outputs` data source で `aws` ワークスペースの output から読みます。`aws`
ワークスペース側で **Remote state sharing** を `aws-preview` に対して許可する設定が
必要です。

### GitHub Actions からの操作

TFC の変数を更新して run を起動する処理は登録も削除も同じなので、reusable workflow
（`preview.yml`、`workflow_call` で受ける）に切り出して 2 か所から呼びます。

| 呼び出し元 | 契機 | 備考 |
| --- | --- | --- |
| `docker-publish.yml` の `preview` job | `opened` / `synchronize` / `reopened` | **`needs: build`** を付ける |
| `preview-cleanup.yml` | `closed` | イメージが要らないので publish を待たない |

登録側を `docker-publish.yml` の中に置いて `needs: build` を付けるのが要点です。別
workflow にすると**同じ `pull_request` イベントから独立に起動する**ため、イメージの
publish より先に TFC の run が進み、まだ存在しないタグを pull しようとしてタスクが
起動しません。

reusable workflow の中身:

1. TFC API で `preview_pull_requests` の現在値を取得
2. 対象 PR のエントリを追加・更新・削除して `PATCH /vars/:id`
3. `POST /runs` で run を起動（ワークスペースは auto-apply 設定）
4. run の完了を待ち、PR に URL をコメント

> **重要**: この変数更新は read-modify-write なので、複数 PR が同時に走ると片方の
> 更新が消えます。**PR 番号を含めない** `concurrency` グループ（例:
> `group: preview-tfc`）を設定して直列化してください。concurrency グループ名は
> リポジトリ全体で共有されるので、登録側と削除側に同じ名前を付ければ両者の競合も
> まとめて防げます。

必要なシークレットは `TFC_TOKEN` だけです（`aws-preview` ワークスペースにスコープした
チームトークン）。**Actions に AWS の認証情報は渡しません。**

### イメージの publish

現在の `docker-publish.yml` は PR ではビルドするだけで push していません。PR でも
`pr-<番号>` タグで push するように変更します。fork や無関係な人の PR を弾く
`author_association` のガードは既にあるので、そのまま流用できます。

> `pull_request_target` は使わないでください。PR のコードを書き込み権限付きで実行する
> ことになり、プレビュー環境の意味では最悪の踏み台になります。

## 後片付け

close イベントでの destroy に加えて、**夜間の再収束ジョブ**を置きます。

```
毎晩 1 回 (schedule)
  ├─ gh api で open な PR 番号の一覧を取得
  ├─ preview_pull_requests を「open な PR だけ」に書き換え
  └─ run を起動
```

TTL で古いものを消す方式より、あるべき状態を毎回計算し直すこの方式を勧めます。close
イベントの取りこぼしやワークフロー失敗で置き去りになったサービスを、原因によらず
回収できるためです。**プレビュー環境が静かに課金され続けるのは定番の事故**なので、
自動化はここまで入れて 1 セットと考えてください。

## セキュリティ上の整理

### 閲覧は制限しません（決定事項）

プレビュー URL は公開のままにします。統計データはチーム内で見えて差し支えないという
判断で、リスナールールに `source-ip` 条件は付けません。URL を知っていれば誰でも
到達できる前提で運用します。

後から絞りたくなった場合、ALB のリスナールールは条件を複数持てるので、ホストヘッダ
条件に `source-ip` を足すだけで入れられます。

### 未マージのコードは信頼境界の内側で動きます

閲覧制限とは別の話として、プレビューで動くのは**レビュー前のコード**で、それが統計 DB
の実データに接続し、egress 全開の SG で動きます。緩和しているのは次の 2 点です。

- fork や無関係な人の PR ではイメージを publish しない（`author_association` の既存
  ガードを維持。`pull_request_target` は使わない）
- PR のコードに渡す DB 資格情報を、その PR 専用ロールに限定する（前述の bootstrap）

つまり**書き込み権限のあるメンバーの未マージコードは信頼する**という前提に立っています。
統計データを外に出したくない度合いが上がったら、プレビュー用に匿名化したデータセットを
用意するか、プレビューからは統計 DB を外して stub を返す形にしてください。

### その他

- TFC トークンは `aws-preview` ワークスペース限定のチームトークンにする

## IAM に必要な変更

### 1. run ロールの信頼ポリシー（見落としやすい）

README「2. AWS 認証情報」に載せている信頼ポリシーは、`sub` を
`…:workspace:aws:run_phase:*` に限定しています。このままでは**権限をいくら足しても
`aws-preview` ワークスペースの run はロールを引き受けられません**。`StringLike` の値を
配列にして両方を許可してください。

```json
"app.terraform.io:sub": [
  "organization:prtimes-hackathon-2026:project:Default Project:workspace:aws:run_phase:*",
  "organization:prtimes-hackathon-2026:project:Default Project:workspace:aws-preview:run_phase:*"
]
```

`workspace:aws*` のようなワイルドカードでも通りますが、将来 `aws` で始まる別の
ワークスペースを作ったときに意図せず権限が付くため、列挙を勧めます。

### 2. run ロールの権限ポリシー

README の「デプロイ手順」1 のインラインポリシーに、以下が追加で要ります。

| サービス | アクション |
| --- | --- |
| ECS | `RegisterTaskDefinition` / `DeregisterTaskDefinition` / `CreateService` / `UpdateService` / `DeleteService` |
| ELBv2 | `CreateTargetGroup` / `DeleteTargetGroup` / `CreateRule` / `DeleteRule` / `ModifyRule` |
| ACM | `RequestCertificate` / `DescribeCertificate` / `DeleteCertificate` |
| Route 53 | `ChangeResourceRecordSets` / `GetHostedZone` / `ListResourceRecordSets` |
| Secrets Manager / Logs / RDS | 既存のものに加えてプレビュー用リソース名のプレフィックス |

### 3. タスク実行ロールの GetSecretValue

`iam_ecs.tf` の `ReadSecrets` ステートメントは、既存の 2 つのシークレット（と
レジストリ認証情報）だけを列挙しています。このままではプレビュー用シークレットを
読めず、**タスクの初期化が `ResourceInitializationError` で失敗します**。resources に
`arn:aws:secretsmanager:<region>:<account>:secret:webapp-preview/*` を足してください。

足す先が**タスク実行ロールであってタスクロールではない**点が、前述の bootstrap の
分離を成り立たせています。タスクロールにも管理者シークレットの読み取りを足すと、PR の
コードから AWS API で管理者 URL を取得できてしまい、分離が崩れます。

## 実装の順序

段階的に入れれば、途中で止めても壊れません。

| 段階 | やること | 単体で価値があるか |
| --- | --- | --- |
| 0 | ドメイン取得、ACM 証明書、Route 53、`certificate_arn` を設定して HTTPS 化 | ある（本番も HTTPS になる） |
| 1 | 共有基盤の output 追加、`modules/preview` 実装、`aws-preview` ワークスペースを手動 apply で 1 PR 試す | ある（手動プレビューとして使える） |
| 2 | app リポジトリの `migrator` イメージ（bootstrap 兼用）、`preview.yml`、`docker-publish.yml` の PR タグ対応と `preview` job | ある（ここで自動化が完成） |
| 3 | 夜間の再収束ジョブ | 運用の安全弁 |

段階 0 は独立していて、プレビューをやらない場合でも入れる価値があります。

## 費用の目安 (ap-northeast-1)

| 項目 | 概算 |
| --- | --- |
| プレビュー用 RDS db.t4g.micro + gp3 20GiB | 月 $15 前後（常時） |
| Route 53 ホストゾーン | 月 $0.50 + ドメイン代 |
| ALB | 追加なし（共有） |
| Fargate 0.25 vCPU / 0.5 GiB | PR 1 つあたり 1 日 $0.37。Spot なら $0.11 前後 |
| CloudWatch Logs / Secrets Manager | 数ドル |

同時に 3 つのプレビューが常時動いても、月 $30〜40 の増加に収まります。

## 検討して採らなかった案

| 案 | 却下の理由 |
| --- | --- |
| PR ごとに ALB を建てる | ドメイン不要で URL が得られる利点はあるが、ALB は 1 台 月 $20、作成に 3 分かかる。ドメインを用意する前提が立ったので不要 |
| PR ごとに RDS インスタンス | 作成に 5〜10 分。プレビューの回転速度が致命的に落ちる |
| 全プレビューで 1 つの database を共有 | 最安だが、スキーマを変える PR が混ざると他のプレビューが壊れる |
| パスベースのルーティング (`/pr-123/*`) | Next.js の `basePath` がビルド時定数のため、PR ごとにイメージを作り直す羽目になる |
| PR ごとに TFC ワークスペース | state が散らかり、destroy 漏れの検知が難しい。変数 1 つの `for_each` で足りる |
| Actions から AWS CLI で直接作る | Terraform を経由しないぶん速いが、Actions に `CreateService` / `PassRole` 相当の強い権限を渡すことになる。drift も追えない |
| Actions から `ecs run-task` でマイグレーション | 同上。コンテナ依存関係を使えば Terraform だけで完結する |
| 管理者資格情報を PR 由来の migrator に渡す | PR のコードが同一インスタンス上の全 PR の database を触れてしまい、database を分ける意味が失われる。bootstrap を main 由来の固定イメージに分けた |
| プレビューの閲覧を IP で制限する | 統計データはチーム内で見えて差し支えないという判断。必要になればリスナールールに条件を 1 つ足すだけで後から入れられる |
