# PR プレビュー環境

app リポジトリの Pull Request ごとに、その PR のコードが動く URL を自動で用意する
ための構成です。**実装済みです。** 決めたことと、検討して採らなかった案の理由を
残しています。設計時の想定と実装で食い違った点は
「[設計から変えたところ](#設計から変えたところ)」にまとめてあります。

- 対象リポジトリ: `prtimes-hackathon-2026/app`
- 前提: このリポジトリが既に作っている共有基盤（VPC / ALB / ECS クラスター / RDS）に
  相乗りする

| 置き場所 | 中身 |
| --- | --- |
| `dns.tf` | プレビュー用ドメインの Route 53 ゾーンと ACM 証明書 |
| `rds_preview.tf` | プレビュー用 RDS、SG、管理者シークレット |
| `modules/preview/` | PR 1 つ分のリソース（TG / リスナールール / タスク定義 / サービス） |
| `modules/preview/bootstrap.sh` | database とロールを作る冪等な SQL |
| `preview/` | `aws-preview` ワークスペースのルート（working directory に指定する） |
| app: `.github/workflows/preview*.yml` | 登録・削除・夜間の再収束 |
| app: `.github/scripts/preview-tfc.sh` | TFC の変数更新と run 起動 |

セットアップ手順は「[入れかた](#入れかた)」を参照してください。

## 完成形

PR #123 を開くと `https://pr-123.preview-prtimes-hackathon-2026.naohanpen.dev` が生え、
PR にコメントで URL が付きます。push するたび入れ替わり、PR を閉じると消えます。

```
app に PR #123 を open / push
  └─ build   : ghcr.io/.../app:pr-123 と :pr-123-<sha> を publish
     └─ preview: (needs: build) TFC の変数 preview_pull_requests に
                 {"number": 123, "image_tag": "pr-123-<sha>"} を追加
                 → aws-preview ワークスペースの run を起動 (auto-apply)
                    └─ Terraform が PR 123 用の TG / リスナールール / ECS サービスを作る
                       └─ タスク起動時に bootstrap → app の順にコンテナが走る
     └─ comment: https://pr-123.preview-prtimes-hackathon-2026.naohanpen.dev をコメント

PR #123 を close
  └─ preview: 変数から 123 を取り除いて run 起動 → 該当リソースだけ destroy
```

> `image_tag` にコミットの SHA を含めているのがポイントです。`pr-123` のような
> 可変タグだけを指していると、push でイメージを差し替えても Terraform 側に差分が
> 出ず、**プレビューが入れ替わりません**。

> ドメインは `preview-prtimes-hackathon-2026.naohanpen.dev` です
> (`preview_domain` 変数の既定値)。

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
| 条件 | `host-header = pr-<番号>.preview-prtimes-hackathon-2026.naohanpen.dev` |
| 優先度 | `1000 + PR 番号` |
| アクション | forward → PR 用ターゲットグループ |

同時プレビュー数の上限は**リスナールールのクォータ 100 件**です。ハッカソン規模なら
十分ですが、優先度に PR 番号をそのまま足しているため、PR 番号が 49000 を超えると
（クォータ上限 50000 に当たって）破綻します。実質的には起こりません。

### DNS と証明書

`preview-prtimes-hackathon-2026.naohanpen.dev` の Route 53 ホストゾーンをこのアカウント
に作り、**親ゾーン `naohanpen.dev` 側に NS レコードで委任**します。親ゾーンが別アカウント
や別の DNS サービスにある場合、この委任だけは手作業になります。

委任が済むまで ACM の DNS 検証は完了しません。`aws_acm_certificate_validation` は
既定で 75 分待ってから失敗するので、**apply を 2 回に分ける**ようにしてあります。

| | `preview_domain_delegated` | 作られるもの |
| --- | --- | --- |
| 1 回目 | `false` | ゾーン、証明書、検証用レコード。検証は待たない |
| 2 回目 | `true`（既定） | 証明書の検証完了、HTTPS リスナー |

1 回目の apply 後に `terraform output preview_zone_name_servers` を親ゾーンへ NS
レコードとして登録し、それから `true` にしてください。委任は済んでいるので既定は
`true` です。ゾーンを作り直して NS が変わったときだけ、登録し直すまで一時的に
`false` に戻します。

| レコード | 向き先 | 用途 |
| --- | --- | --- |
| `*.preview-prtimes-hackathon-2026.naohanpen.dev` A (ALIAS) | ALB | 全 PR をこれ 1 本で賄う |
| `preview-prtimes-hackathon-2026.naohanpen.dev` (apex) A (ALIAS) | ALB | 既存の dev アプリ（リスナーの既定アクション） |

PR ごとに DNS レコードを作る必要はありません。証明書も ACM で 1 枚だけ取り、
ワイルドカードと apex の 2 つの名前を載せます。

- `*.preview-prtimes-hackathon-2026.naohanpen.dev`（`pr-123.…` をカバー）
- `preview-prtimes-hackathon-2026.naohanpen.dev`（ワイルドカードは 1 ラベル分しか
  対応しないので、apex は別途 SAN に入れる）

apex を含めておくのは、`certificate_arn` を設定すると HTTP が HTTPS にリダイレクト
されるようになり、**ALB の DNS 名で直接アクセスすると証明書エラーになる**ためです。
既存の dev アプリにも、このドメインで正規の名前を与えておくのが素直です。

> `.dev` は HSTS preload されているため、ブラウザからは HTTP で到達できません。
> 証明書と DNS の用意は、プレビュー以前に必須の作業です。プレビューをやらない場合でも
> 入れる価値があります。

### PR ごとに作るリソース (`modules/preview`)

| リソース | 名前 | 備考 |
| --- | --- | --- |
| `aws_lb_target_group` | `webapp-pr-123` | `deregistration_delay = 15`。ヘルスチェックは共有側と同じ `/api/health` |
| `aws_lb_listener_rule` | — | 上記のホストヘッダ条件 |
| `aws_cloudwatch_log_group` | `/ecs/webapp-preview/pr-123` | 保持 3 日 |
| `aws_secretsmanager_secret` | `webapp-preview/pr-123/app-db-url` | PR 専用ロールでの接続 URL。DB の資格情報として渡すのはこれだけ |
| `aws_ecs_task_definition` | `webapp-pr-123` | 256 CPU / 512 MiB。`bootstrap` + `app` の 2 コンテナ |
| `aws_ecs_service` | `webapp-pr-123` | `desired_count = 1`、`FARGATE_SPOT` |

DB 以外では、統計 DB の接続 URL・`OPENAI_API_KEY`・`AUTH_PASSWORD` を共有基盤の
シークレットからそのまま渡しています。`OPENAI_API_KEY` は **PR のコードが読める**ので、
外部からの PR もプレビューする運用に変えるときは `aws-preview` ワークスペースの
`openai_api_key_enabled` を `false` にしてください（AI コーチングの API だけが
動かなくなります）。

`AUTH_PASSWORD`（簡易ログインの合言葉）を渡しているのは、プレビューもインターネットから
到達できるためです。渡さないとアプリ側の既定値（`prtimes`）で誰でも入れてしまいます。
本番と同じ合言葉なので、これも **PR のコードから読めます**。外部からの PR を
プレビューするなら、プレビュー専用のシークレットを別に作って渡してください
（`modules/preview` の `auth_password_secret_arn` に別の ARN を渡すだけで済みます）。

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

**Terraform Cloud は SaaS なので、プライベートサブネットにいる RDS に到達できません。**
つまり `postgresql` provider で `CREATE DATABASE` を実行することはできません。

一方で**マイグレーションは考える必要がありません**。app は main で起動時マイグレーション
を導入済みで、コンテナが立ち上がるときに自分でスキーマを合わせます。プレビューも同じ
仕組みにそのまま乗ります。

残る仕事は「app が接続しにいく前に database とロールが存在していること」だけです。これを
bootstrap コンテナが用意し、ECS のコンテナ依存関係 (`dependsOn` の `SUCCESS` 条件) で
app より先に走らせます。

```
タスク起動
  ├─ bootstrap コンテナ    ← public.ecr.aws/docker/library/postgres:17-alpine（上流の公式イメージ）
  │    ADMIN_DATABASE_URL（プレビュー RDS の管理者）と、
  │    APP_DATABASE_URL（PR 用ロールの URL。名前とパスワードはここから取る）を受け取り、
  │    psql で pr_123 の database とロールを、無ければ作る（冪等な SQL）→ exit 0
  └─ app コンテナ (dependsOn: bootstrap = SUCCESS)   ← PR のコード
       起動時マイグレーションが pr_123 にスキーマを作り、node server.js が listen する
```

bootstrap は**アプリのイメージを一切使いません**。上流の postgres 公式イメージに SQL を
渡すだけなので、PR のコードが混入する余地がそもそもありません（Docker Hub のレート制限を
避けて ECR Public を指定しています）。

**管理者資格情報を受け取るのは bootstrap だけ**で、PR 由来の app に渡すのは `pr_123`
ロールの URL だけです。ある PR のコードが他の PR の database を読み書きすることは
できず、database を分けることが単なる名前空間ではなく**認可境界**として成立します。

ただし、これは黙って成り立つものではありません。PostgreSQL は新しい database の
`CONNECT` 権限を既定で `PUBLIC` に与えるため、素直に `CREATE DATABASE` しただけだと
**`pr_A` のロールで `pr_B` の database に接続できてしまいます**。テーブルの中身は
所有者以外に権限が無いので読めませんが、カタログ（テーブル名やカラム名）は覗けます。
bootstrap は database を作った後に次を流して、この穴を閉じています。

```sql
REVOKE CONNECT ON DATABASE pr_123 FROM PUBLIC;
GRANT  CONNECT ON DATABASE pr_123 TO pr_123;        -- この PR のロール
GRANT  CONNECT ON DATABASE pr_123 TO <管理者>;       -- bootstrap の再実行用
```

管理者にも明示的に戻しているのは、RDS のマスターユーザーが superuser ではなく、
`PUBLIC` から外すと ACL の対象になるためです（戻さないと 2 回目の bootstrap が
自分の作った database に入れなくなります）。

同一タスク内でも ECS の `secrets` はコンテナごとに解決されるため、bootstrap の環境変数を
app のコードから読むことはできません。加えて、管理者シークレットの `GetSecretValue` は
**タスク実行ロールにだけ許可し、タスクロールには許可しません**。コンテナのコードが
使えるのはタスクロールの資格情報なので、AWS API 経由で管理者 URL を取り直すことも
できません。

Terraform だけで完結するのも利点です。GitHub Actions から `ecs run-task` を叩く必要が
なく、Actions に AWS の権限を一切渡さずに済みます。bootstrap が失敗すれば app は起動
せず、デプロイサーキットブレーカーが働きます。

タスクが起動するたびに bootstrap が走りますが冪等です。イメージ pull の分、起動が
10〜20 秒延びます。

**app リポジトリの `Dockerfile` に変更は要りません。** 起動時マイグレーションがある
おかげで `drizzle-kit` を含む migrator イメージを別途用意する必要がなく、app 側で必要な
のはワークフローの変更だけです。

### 後片付けは PR の database とロールを残します

PR を閉じても `pr_123` の database とロールは残ります。Terraform から
`DROP DATABASE` を実行する手段がない（同じ到達性の問題）ためです。空の database は
ほぼ無料なので放置でも構いませんが、気になるなら後述のスイーパーで
EventBridge Scheduler → `ecs run-task` を組み、開いていない PR のものを落として
ください。この掃除タスクも管理者資格情報を使うので、bootstrap と同じ postgres
イメージに SQL を渡す形で動かします。

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

TFC 側には **HCL 型の Terraform variable** として登録し、ワークフローは値を **JSON で**
書き込みます。HCL のオブジェクト構文は `{"key": value}` 表記も受け付ける
（[HCL の仕様][hcl-spec]では `objectelem = (Identifier | Expression) ("=" | ":") Expression`）
ので、JSON はそのまま有効な HCL 式として解釈されます。おかげでワークフロー側は
`jq` だけで読み書きでき、HCL のパーサを持たずに済みます。

```json
[{ "number": 123, "image_tag": "pr-123-abc1234" }]
```

[hcl-spec]: https://github.com/hashicorp/hcl/blob/main/hclsyntax/spec.md#collection-values

共有基盤の値（リスナー ARN、クラスター名、SG、サブネット、ロール ARN など）は
`terraform_remote_state` data source で `aws` ワークスペースの output から読みます。
`aws` ワークスペース側で **Remote state sharing** を `aws-preview` に対して許可する
設定が必要です。

> 当初は `tfe_outputs` を使う想定でしたが、公式ドキュメントを確認したところ
> **「Remote state access controls do not apply when using the `tfe_outputs` data
> source」**（[Access state from other workspaces][state-sharing]）とあり、
> `tfe_outputs` は Remote state sharing の設定を迂回します。代わりに `tfe` provider
> 用の API トークンが要り、HCP Terraform の run の中でも
> **「you will need to use one of the two options above」**（[tfe provider][tfe-provider]）
> と明記されていて省略できません。
>
> 一方 `terraform_remote_state` は
> **「HCP Terraform automatically manages API credentials for `terraform_remote_state`
> access during runs managed by HCP Terraform」** なのでトークンが不要です。
> 「必要なシークレットは `TFC_TOKEN` だけ」という当初の方針を保てるうえ、アクセス制御が
> Remote state sharing の設定として残って監査できるので、こちらを採りました。

[state-sharing]: https://developer.hashicorp.com/terraform/cloud-docs/workspaces/state#access-state-from-other-workspaces
[tfe-provider]: https://registry.terraform.io/providers/hashicorp/tfe/latest/docs

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
> 更新が消えます。**PR 番号を含めない** `concurrency` グループ（`group: preview-tfc`）
> を設定して直列化しています。concurrency グループ名はリポジトリ全体で共有されるので、
> 登録側・削除側・夜間ジョブに同じ名前を付ければ三者の競合をまとめて防げます。
>
> ただし直列化しても取りこぼしは残ります。GitHub の concurrency は**待機できるのが
> 1 件だけ**で、3 つ目が来ると待機中のものが取り消されるためです。取り消された分は
> 夜間の再収束ジョブが拾います（後述）。これが「あるべき状態を毎回計算し直す」方式を
> 採っている実際的な理由の 1 つです。

呼び出し側の job に `concurrency` と `permissions` を書けるのは、reusable workflow を
呼ぶ job で使えるキーワードとして[公式に列挙されている][reusable-keywords]ためです
（`cancel-in-progress: true` を呼び出し元と呼び出し先で同じグループ名にすると相互に
取り消し合うという注意書きがありますが、ここでは `false` かつ呼び出し側にのみ
設定しているので当たりません）。

[reusable-keywords]: https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations#supported-keywords-for-jobs-that-call-a-reusable-workflow

必要なシークレットは `TFC_TOKEN` だけです（`aws-preview` ワークスペースにスコープした
チームトークン）。**Actions に AWS の認証情報は渡しません。**

### イメージの publish

これまで `docker-publish.yml` は PR ではビルドするだけで push していませんでした。PR でも
push するように変更してあります。fork や無関係な人の PR を弾く `author_association` の
ガードは既にあったので、そのまま流用しています。

PR には**タグを 2 つ**打ちます。

| タグ | 誰が使うか |
| --- | --- |
| `pr-123` | 人。`docker run` で手元に持ってくるとき |
| `pr-123-<sha7>` | プレビュー。`preview_pull_requests` の `image_tag` はこちら |

プレビューが可変タグ (`pr-123`) を指していると、push でイメージを差し替えても
タスク定義の `image` が変わらず、Terraform に差分が出ません。差分が無いので ECS は
サービスを入れ替えず、**新しいコードがプレビューに反映されません**。コミットごとに
別のタグを指すことで、push のたびに新しいタスク定義リビジョンが登録されて入れ替わります。

`pr-123` の方は `type=ref,event=pr` が生やします（[metadata-action の仕様][meta-ref]で
`pull_request` イベントの `refs/pull/2/merge` → `pr-2` と定義されています）。

[meta-ref]: https://github.com/docker/metadata-action#typeref

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

README の「デプロイ手順」1 のインラインポリシーに、**ACM と Route 53 の 2 つの
ステートメント**を足します（実際の JSON は README を参照）。

| サービス | 状況 |
| --- | --- |
| ECS / ELBv2 / RDS / Logs | 既存の `ecs:*` / `elasticloadbalancing:*` / `rds:*` / `logs:*` で足りる |
| Secrets Manager | 既存の `secret:webapp-*` が `webapp-preview/...` も覆う（ARN 前方一致） |
| ACM | **要追加**。証明書の発行・削除に加えて `ListTagsForCertificate` |
| Route 53 | **要追加**。ゾーンの作成・削除、レコードの変更、`GetChange` |

2 つ注意点があります。

- **タグ系のアクションを忘れないこと。** `default_tags` を付けているため
  `acm:ListTagsForCertificate` や `route53:ListTagsForResource` は refresh のたびに
  呼ばれます。無いと apply ではなく **plan の時点で `AccessDenied`** になります
  （README が OIDC プロバイダについて書いている落とし穴と同じです）。
- **Route 53 のステートメントに `aws:RequestedRegion` 条件を付けないこと。**
  Route 53 はグローバルサービスで、API 呼び出しのリージョンが `us-east-1` として
  評価されるため、`ap-northeast-1` に限定した条件を付けると全て弾かれます。
  ACM は ALB と同じリージョンの証明書が要るので、こちらは条件付きで構いません。

### 3. タスク実行ロールの GetSecretValue

`iam_ecs.tf` の `ReadSecrets` ステートメントは、既存の 2 つのシークレット（と
レジストリ認証情報）だけを列挙しています。このままではプレビュー用シークレットを
読めず、**タスクの初期化が `ResourceInitializationError` で失敗します**。resources に
`arn:aws:secretsmanager:<region>:<account>:secret:webapp-preview/*` を足してください。

足す先が**タスク実行ロールであってタスクロールではない**点が、前述の bootstrap の
分離を成り立たせています。タスクロールにも管理者シークレットの読み取りを足すと、PR の
コードから AWS API で管理者 URL を取得できてしまい、分離が崩れます。

## 入れかた

コードは全部入っていますが、**手作業が要る箇所が 4 つ**あります（親ゾーンへの NS 委任、
run ロールの IAM、TFC ワークスペースの作成、app リポジトリの secret / variable）。
下の順に進めれば、途中で止めても壊れません。

### 1. run ロールの権限を先に足す

「[IAM に必要な変更](#iam-に必要な変更)」の 1（信頼ポリシーに `aws-preview` を追加）と
2（権限ポリシー）を先にやります。run ロール自身の権限は Terraform では管理できません。

### 2. ドメインを生やす（`aws` ワークスペース）

既に委任済みなら `terraform apply` 1 回で終わります（`preview_domain_delegated` の
既定が `true`）。ゾーンを作り直して NS が変わった場合だけ、以下の 2 段階を踏みます。

```bash
# 1 回目: ゾーンと検証用レコードを作る。証明書の検証は待たない
terraform apply -var preview_domain_delegated=false
terraform output preview_zone_name_servers
```

出てきた 4 つの NS を、親ゾーン `naohanpen.dev` に `preview-prtimes-hackathon-2026`
の NS レコードとして登録します（親ゾーンが別管理なのでここは手作業）。`dig NS
preview-prtimes-hackathon-2026.naohanpen.dev` が返るようになったら:

```bash
# 2 回目: 証明書を検証して HTTPS リスナーを立てる（既定値に戻すだけ）
terraform apply
```

`preview_domain_delegated` は既定が `true` なので、ワークスペースの Variables に
入れる必要はありません（`aws-preview` ワークスペースはこの変数を持たないので、
入れると「宣言されていない変数」の警告が出ます）。ここまでで既存の dev アプリも HTTPS になります
（`.dev` は HSTS preload されていて、そもそも HTTP では到達できません）。

プレビュー用 RDS は `preview_enabled`（既定 `true`）で作られます。作りたくない間は
`false` にしてください。

### 3. `aws-preview` ワークスペースを作る

| 設定 | 値 |
| --- | --- |
| 名前 | `aws-preview` |
| Execution mode | Remote |
| Working Directory | `preview` |
| Auto-apply | **有効**（無効だと run が `planned` で止まり、ワークフローがタイムアウトする） |
| Environment variables | `TFC_AWS_PROVIDER_AUTH=true`、`TFC_AWS_RUN_ROLE_ARN=<run ロール>` |

そのうえで **`aws` ワークスペース**の Settings → Remote state sharing で `aws-preview`
を許可します。これが無いと `terraform_remote_state` が共有基盤の output を読めません。

`preview_pull_requests` 変数は、app のワークフローが初回に自動で作ります（HCL 型・
値 `[]`）。手で作る場合は **HCL を有効に、sensitive は無効**にしてください。sensitive に
すると API から値を読めなくなり、read-modify-write が成立しません。

動作確認は手で 1 PR 分入れてみるのが早いです。

```bash
cd preview
terraform apply -var 'preview_pull_requests=[{"number":1,"image_tag":"pr-1-abc1234"}]'
```

### 4. app リポジトリの secret と variable

| 種類 | 名前 | 値 |
| --- | --- | --- |
| Secret | `TFC_TOKEN` | `aws-preview` にスコープしたチームトークン |
| Variable | `PREVIEW_ENABLED` | `true`（これが `true` になるまでワークフローは黙ってスキップします） |
| Variable | `TFC_ORGANIZATION` | 省略時 `prtimes-hackathon-2026` |
| Variable | `TFC_PREVIEW_WORKSPACE` | 省略時 `aws-preview` |
| Variable | `PREVIEW_DOMAIN` | 省略時 `preview-prtimes-hackathon-2026.naohanpen.dev` |

`TFC_TOKEN` は変数の更新と run の起動に使うだけで、**AWS の認証情報は Actions に一切
渡しません**。`PREVIEW_ENABLED` を `false` に戻せば、いつでも自動化だけ止められます。

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
| migrator イメージを別に作って migrate コンテナを挟む | app が main で起動時マイグレーションを持っているので不要。bootstrap は database とロールの作成だけに絞れる |
| 管理者資格情報を PR 由来のコンテナに渡す | PR のコードが同一インスタンス上の全 PR の database を触れてしまい、database を分ける意味が失われる。bootstrap を上流の postgres イメージに分離した |
| プレビューの閲覧を IP で制限する | 統計データはチーム内で見えて差し支えないという判断。必要になればリスナールールに条件を 1 つ足すだけで後から入れられる |

## 設計から変えたところ

実装しながら公式ドキュメントで裏を取った結果、設計時の想定と食い違った点です。

| 箇所 | 設計時 | 実装 | 理由 |
| --- | --- | --- | --- |
| 共有基盤の output の読み方 | `tfe_outputs` | `terraform_remote_state` | `tfe_outputs` は Remote state sharing を迂回し、別途 API トークンが要る。設計が挙げていた「Remote state sharing を許可する」「シークレットは `TFC_TOKEN` だけ」の 2 つは `terraform_remote_state` の性質。前述の[制御プレーン](#制御プレーン-ワークスペースを分ける)を参照 |
| `image_tag` | `pr-123` | `pr-123-<sha7>` | 可変タグだと Terraform に差分が出ず、push しても入れ替わらない |
| database の権限 | database を分ければ境界になる | `CONNECT` を `PUBLIC` から剥がす | PostgreSQL の既定では他の PR の database に接続できてしまう |
| ドメインの apply | 1 回 | 2 回（`preview_domain_delegated`） | NS 委任が済むまで ACM の検証が終わらず、1 回で通そうとすると 75 分待って失敗する |
| `concurrency` による直列化 | これで競合を防げる | 防ぎきれない前提で運用 | GitHub の concurrency は待機枠が 1 件だけ。3 つ目が来ると待機中が取り消される。夜間の再収束ジョブが最終的な整合性を担保する |

### 確認に使った一次情報

- [HCP Terraform: Access state from other workspaces][state-sharing] — `tfe_outputs` は remote state access controls の対象外、`terraform_remote_state` は run 中の API 認証情報が自動管理される
- [tfe provider][tfe-provider] — HCP Terraform の中でも `token` か `TFE_TOKEN` が必要
- [HCL Native Syntax Specification][hcl-spec] — `objectelem` は `=` と `:` の両方を受け付ける（JSON がそのまま HCL 式として通る根拠）
- [Workspace Variables API](https://developer.hashicorp.com/terraform/cloud-docs/api-docs/workspace-variables) — `PATCH /workspaces/:workspace_id/vars/:variable_id`、`sensitive: true` は「written once and not visible thereafter」
- [Runs API](https://developer.hashicorp.com/terraform/cloud-docs/api-docs/run) — `configuration-version` を省略すると最新の設定バージョンが使われる。run のステータス一覧
- [GitHub Actions: 呼び出し側 job で使えるキーワード][reusable-keywords] — `concurrency` と `permissions` が使える
- [ECS タスク定義パラメータ](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_definition_parameters.html) — `SUCCESS` 条件は essential なコンテナには設定できない（bootstrap を `essential: false` にしている根拠）
- [ECS: 機密データを渡す](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/specifying-sensitive-data-secrets.html) — シークレットを取得するのは**タスク実行ロール**
- [aws_acm_certificate_validation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/acm_certificate_validation) — ワイルドカードと apex で検証レコードが重なるため `allow_overwrite = true` を使う公式パターン
- [aws_lb_listener_rule](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_listener_rule) — `priority` は 1〜50000（`1000 + PR 番号` の上限が PR 49000 になる根拠）
