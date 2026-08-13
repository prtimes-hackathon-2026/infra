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
     └─ preview: TFC の変数 preview_pull_requests に {number=123, tag="pr-123"} を追加
                 → aws-preview ワークスペースの run を起動 (auto-apply)
                    └─ Terraform が PR 123 用の TG / リスナールール / ECS サービスを作る
                       └─ タスク起動時に migrate コンテナが database pr_123 を作って
                          drizzle-kit migrate を流し、成功したら app コンテナが起動
     └─ comment: https://pr-123.preview.example.com を PR にコメント

PR #123 を close
  └─ preview: 変数から 123 を取り除いて run 起動 → 該当リソースだけ destroy
```

> `example.com` はプレースホルダです。実際に使うドメインが決まったら
> `preview_domain` 変数の既定値として置きます。

## 全体構成

| レイヤ | 置き場所 | 中身 |
| --- | --- | --- |
| 共有基盤 | 既存ワークスペース `aws` | VPC / ALB / HTTPS リスナー / ECS クラスター / ACM / Route 53 / プレビュー用 RDS |
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
| `aws_secretsmanager_secret` | `webapp-preview/pr-123/app-db-url` | PR 専用 database への接続 URL |
| `aws_ecs_task_definition` | `webapp-pr-123` | 256 CPU / 512 MiB。`migrate` + `app` の 2 コンテナ |
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
| 接続情報 | Terraform が URL を組み立てて Secrets Manager へ | 共有基盤の `APP_DATABASE_URL` と同じ方式 |
| 統計 DB | 既存を共有 | 参照専用のため |

パスワードの平文が Terraform state に入る点は共有基盤と同じトレードオフです
（README の「アプリ用 DB のパスワードは Terraform state に入ります」参照）。

### database の作成とマイグレーションは migrate サイドカーで

ここが設計上いちばん悩んだところです。**Terraform Cloud は SaaS なので、プライベート
サブネットにいる RDS に到達できません。** つまり `postgresql` provider で
`CREATE DATABASE` を実行することはできず、マイグレーションも同様です。

採る方式は、**PR 用タスク定義に `migrate` コンテナを同居させる**やり方です。

```
タスク起動
  ├─ migrate コンテナ (essential = false)
  │    1. ADMIN_DATABASE_URL で postgres データベースに接続
  │    2. pg_database に pr_123 が無ければ CREATE DATABASE pr_123
  │    3. APP_DATABASE_URL に対して drizzle-kit migrate
  │    4. exit 0
  └─ app コンテナ (dependsOn: migrate = SUCCESS)
       └─ node server.js
```

ECS のコンテナ依存関係 (`dependsOn` の `SUCCESS` 条件) を使うので、**Terraform だけで
完結します**。GitHub Actions から `ecs run-task` を叩く必要がなく、後述のとおり
Actions に AWS の権限を一切渡さずに済むのが効いています。migrate が失敗すればタスクは
起動せず、デプロイサーキットブレーカーが働きます。

タスクが起動するたびに migrate が走りますが、drizzle のマイグレーションは冪等なので
問題ありません。イメージ pull の分、起動が 20〜30 秒延びます。

**app リポジトリ側に必要な変更**: 現在の `Dockerfile` は `output: 'standalone'` の
ランタイムイメージで、`drizzle-kit` を含んでいません。`migrator` ステージ
（devDependencies と `drizzle/` を含む）を足し、上記の手順を行うエントリポイントを
用意して `ghcr.io/.../app-migrator` として publish する必要があります。

### database の削除

PR を閉じても `pr_123` database は残ります。Terraform から `DROP DATABASE` を実行する
手段がない（同じ到達性の問題）ためです。空の database はほぼ無料なので放置でも構い
ませんが、気になるなら後述のスイーパーで EventBridge Scheduler → `ecs run-task` を
組み、開いていない PR の database を落としてください。

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

app リポジトリの `preview.yml` が、`pull_request` の `opened` / `synchronize` /
`reopened` / `closed` で動きます。

1. TFC API で `preview_pull_requests` の現在値を取得
2. 対象 PR のエントリを追加・更新・削除して `PATCH /vars/:id`
3. `POST /runs` で run を起動（ワークスペースは auto-apply 設定）
4. run の完了を待ち、PR に URL をコメント

> **重要**: この変数更新は read-modify-write なので、複数 PR が同時に走ると片方の
> 更新が消えます。ワークフローには **PR 番号を含めない** `concurrency` グループ
> （例: `group: preview-tfc`）を設定して、リポジトリ全体で直列化してください。

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

## セキュリティ上の注意

- **プレビューからは統計 DB の実データが見えます。** ALB は現在 `0.0.0.0/0` に開いて
  いるので、プレビュー用リスナールールには `source-ip` 条件を足してチームの IP に
  絞ることを勧めます。ALB のリスナールールは条件を複数持てるので、ホストヘッダと
  組み合わせるだけで済みます。
- fork からの PR ではイメージを publish しない（既存のガードを維持）。
- TFC トークンは `aws-preview` ワークスペース限定のチームトークンにする。

## run ロールに追加が必要な権限

TFC の AWS ロール（README の「デプロイ手順」1 のポリシー）に、以下が追加で要ります。

| サービス | アクション |
| --- | --- |
| ECS | `RegisterTaskDefinition` / `DeregisterTaskDefinition` / `CreateService` / `UpdateService` / `DeleteService` |
| ELBv2 | `CreateTargetGroup` / `DeleteTargetGroup` / `CreateRule` / `DeleteRule` / `ModifyRule` |
| ACM | `RequestCertificate` / `DescribeCertificate` / `DeleteCertificate` |
| Route 53 | `ChangeResourceRecordSets` / `GetHostedZone` / `ListResourceRecordSets` |
| Secrets Manager / Logs / RDS | 既存のものに加えてプレビュー用リソース名のプレフィックス |

## 実装の順序

段階的に入れれば、途中で止めても壊れません。

| 段階 | やること | 単体で価値があるか |
| --- | --- | --- |
| 0 | ドメイン取得、ACM 証明書、Route 53、`certificate_arn` を設定して HTTPS 化 | ある（本番も HTTPS になる） |
| 1 | 共有基盤の output 追加、`modules/preview` 実装、`aws-preview` ワークスペースを手動 apply で 1 PR 試す | ある（手動プレビューとして使える） |
| 2 | app リポジトリの `migrator` イメージと `preview.yml`、`docker-publish.yml` の PR タグ対応 | ある（ここで自動化が完成） |
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
| Actions から `ecs run-task` でマイグレーション | 同上。migrate サイドカーなら Terraform だけで完結する |
