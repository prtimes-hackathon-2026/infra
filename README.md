# infra

AWS を Terraform Cloud (HCP Terraform) で管理するための構成です。

## 構成

| ファイル | 役割 |
| --- | --- |
| `versions.tf` | `cloud` ブロック（organization / workspace）と provider のバージョン制約 |
| `providers.tf` | AWS provider。リージョンと `default_tags` |
| `variables.tf` | `aws_region` / `environment` |
| `main.tf` | 疎通確認用の data source |
| `iam_readonly.tf` | 参照専用 IAM ユーザー、コンソールログイン、アクセスキー |
| `rds.tf` | 既存の RDS (PostgreSQL) を取り込む `import` ブロックとリソース定義 |
| `outputs.tf` | 実際に認証できたアカウント ID・ARN・リージョン、参照専用ユーザーの認証情報 |

## セットアップ

### 1. 接続先

| 項目 | 値 |
| --- | --- |
| Organization | `prtimes-hackathon-2026` |
| Project | Default Project |
| Workspace | `aws` |

`versions.tf` に設定済みです。ワークスペース名は組織内で一意なため、
`cloud` ブロックで project を指定する必要はありません。
ワークスペースは **Execution mode: Remote** で作成しておいてください。

### 2. AWS 認証情報

Remote 実行では plan / apply が Terraform Cloud 側で走るため、
ローカルの `~/.aws/credentials` は**使われません**。ワークスペースの
**Variables → Environment variables** に認証情報を設定します。

動的認証情報 (OIDC) を使う場合:

| 変数名 | 値 |
| --- | --- |
| `TFC_AWS_PROVIDER_AUTH` | `true` |
| `TFC_AWS_RUN_ROLE_ARN` | run が引き受ける IAM ロールの ARN |

IAM 側（OIDC プロバイダとロールの信頼ポリシー）は AWS コンソールで設定済み。
信頼ポリシーの条件はこの組織・ワークスペースの場合、次の形になります。

```json
{
  "StringEquals": {
    "app.terraform.io:aud": "aws.workload.identity"
  },
  "StringLike": {
    "app.terraform.io:sub": "organization:prtimes-hackathon-2026:project:Default Project:workspace:aws:run_phase:*"
  }
}
```

`sub` は ID (`org-…` / `ws-…`) ではなく**名前**ベースです。
project 部分は `project:*` としても構いません。

### 3. 動作確認

```bash
terraform login   # Terraform Cloud のトークンを取得（初回のみ）
terraform init
terraform plan
```

`terraform apply` 後、`account_id` と `caller_arn` が想定どおりのアカウント・ロールを
指していれば、Terraform Cloud から AWS への経路が通っています。

## 参照専用 IAM ユーザー

AWS CLI とマネジメントコンソールから読み取り操作をするためのユーザーを
`iam_readonly.tf` で作成します。

| 変数 | 既定値 | 説明 |
| --- | --- | --- |
| `readonly_user_name` | `readonly` | ユーザー名 |
| `create_login_profile` | `false` | コンソールのログインプロファイルを Terraform で作るか |
| `login_profile_password_length` | `20` | Terraform が生成する初期パスワードの長さ |
| `login_profile_pgp_key` | `null` | 初期パスワードを暗号化する PGP 公開鍵 (base64) / `keybase:<user>` |
| `create_access_key` | `false` | アクセスキーを Terraform で作るか |
| `allow_self_credential_management` | `true` | 本人による自分のキー / パスワード / MFA の管理を許可するか |

権限は AWS 管理ポリシー `ReadOnlyAccess` です。ほぼ全サービスの
`Get*` / `List*` / `Describe*` に加え、S3 のオブジェクト取得や
Lambda の関数コード取得など**データそのものの読み取りも含みます**。
一覧・メタデータだけに絞りたい場合は `ViewOnlyAccess` に差し替えてください。

加えて AWS 管理ポリシー `SignInLocalDevelopmentAccess` をアタッチしています。
`aws login`（AWS CLI のブラウザ経由サインイン）に必要な
`signin:AuthorizeOAuth2Access` / `signin:CreateOAuth2Token` だけを許可するもので、
リソースに対する権限は増えません。実際にできる操作は `ReadOnlyAccess` の範囲のままです。

### コンソールへのサインイン

コンソールのパスワード（ログインプロファイル）は **Terraform では作りません**
（`create_login_profile = false`）。Terraform Cloud の run ロール
`terraform-policy` に `iam:CreateLoginProfile` を付与しておらず、apply が
`AccessDenied` になるためです。管理者が手動で設定します。

1. IAM コンソールの **Users → `readonly` → Security credentials →
   Console sign-in → Enable console access**
2. パスワードを発行し、**「次回サインイン時にパスワードの変更を要求」を有効**にする
3. サインイン URL と初期パスワードを本人に渡す

```bash
terraform output console_signin_url   # https://<account_id>.signin.aws.amazon.com/console
```

サインイン画面では次を入力します。

| 項目 | 値 |
| --- | --- |
| Account ID (or alias) | `account_id` output の値 |
| IAM user name | `readonly` |
| Password | 管理者が発行したパスワード |

以降のパスワード変更は本人でできます（`allow_self_credential_management = true`
により `iam:ChangePassword` を許可済み）。

#### Terraform で管理したい場合

run ロールに次を許可したうえで `create_login_profile = true` にします。

```json
{
  "Effect": "Allow",
  "Action": [
    "iam:CreateLoginProfile",
    "iam:GetLoginProfile",
    "iam:UpdateLoginProfile",
    "iam:DeleteLoginProfile"
  ],
  "Resource": "arn:aws:iam::<account_id>:user/readonly"
}
```

`Get` がないと作成直後の読み戻しで、`Delete` がないと `false` に戻したときや
destroy で失敗します。この場合、初期パスワードは
`terraform output -raw readonly_console_password` で取り出せますが、
**state に平文で保存されます**。避けたい場合は `login_profile_pgp_key` に
PGP 公開鍵（base64）または `keybase:<username>` を指定してください。
`readonly_console_password` は空になり、暗号化された値が
`readonly_console_password_encrypted` に入ります。

```bash
terraform output -raw readonly_console_password_encrypted | base64 -d | gpg -d
```

本人がパスワードを変更しても Terraform は差分として扱いません
（`password_reset_required` などを `ignore_changes` に入れてあります）。
プロファイルを作り直すとパスワードがリセットされる点に注意してください。

### AWS CLI からのサインイン (`aws login`)

長期のアクセスキーを持たずに CLI を使う方法です。ブラウザが開いて
コンソールと同じ資格情報でサインインし、CLI 側には一時的な認証情報が入ります。
`SignInLocalDevelopmentAccess` をアタッチしてあるのはこのためです。

```bash
aws login --profile readonly
aws sts get-caller-identity --profile readonly
```

コンソールのパスワード（ログインプロファイル）が必要なので、先に
「コンソールへのサインイン」の手順を済ませてください。

### アクセスキーの発行

既定では Terraform はアクセスキーを作りません（`create_access_key = false`）。
シークレットを state に残さないためです。キーは利用者本人が発行します。

1. IAM コンソールの **Users → `readonly` → Security credentials → Create access key**
   でキーを作成する（`allow_self_credential_management = true` により、本人の
   `iam:CreateAccessKey` が許可されています）
2. AWS CLI に登録して疎通を確認する

```bash
aws configure --profile readonly
aws sts get-caller-identity --profile readonly
```

Terraform 側に作らせたい場合は `create_access_key = true` にすると
`readonly_access_key_id` / `readonly_secret_access_key` が output されますが、
シークレットは **state に平文で保存される**点に注意してください（state は
Terraform Cloud 側にあり、ワークスペースの閲覧権限を持つ人は
`terraform output` 経由で取り出せます）。

## RDS を Terraform 管理下に移す

### 現状

ハッカソン環境の実リソースは、すべて CloudFormation スタック
`prtimes-hackathon-2026summer` が作成したものです。

| 種別 | 物理 ID |
| --- | --- |
| VPC | `vpc-00a084258f8af45ee` (10.0.0.0/16) |
| プライベートサブネット | `subnet-02b72eb0bd260a389` (1a) / `subnet-0a0fb586a10cf3aa3` (1c) |
| DB サブネットグループ | `prtimes-hackathon-2026summer-dbsubnetgroup-6r3h5y8laexs` |
| RDS セキュリティグループ | `sg-07a56fdc4aafa5704` |
| **RDS (PostgreSQL 17.7)** | **`prtimes-hackathon-2026summer-db`** |
| pgAdmin EC2 | `i-03d2c129397aa9185` (EIP `13.158.197.89`) |

RDS はテンプレートのパラメータでは `db.m7i.large` ですが、実際には
`db.t4g.small` に手で変更されています（= すでに CloudFormation ドリフトがある状態）。
`rds.tf` / `variables.tf` の既定値は**実リソースの現状**に合わせてあります。

### 先に必要な作業: run ロールへの RDS 権限追加

run ロール `terraform-policy` には現在 **IAM 系の権限しか付いていません**
（インラインポリシー `terraform-policyPolicy`）。このままだと Terraform Cloud での
plan が `rds:DescribeDBInstances` の AccessDenied で失敗します。

IAM コンソールで `terraform-policy` ロールに次のステートメントを追加してください。

```json
{
  "Sid": "ManageHackathonRds",
  "Effect": "Allow",
  "Action": [
    "rds:DescribeDBInstances",
    "rds:ListTagsForResource",
    "rds:AddTagsToResource",
    "rds:RemoveTagsFromResource",
    "rds:ModifyDBInstance"
  ],
  "Resource": [
    "arn:aws:rds:ap-northeast-1:317695556802:db:prtimes-hackathon-2026summer-db",
    "arn:aws:rds:ap-northeast-1:317695556802:db:*"
  ]
}
```

`rds:DeleteDBInstance` は意図的に含めていません。付けなければ、`prevent_destroy`
に加えて IAM 側でも削除を防げます。

### 手順

`rds.tf` の `import` ブロックが取り込みを行います。追加の CLI 操作は不要です。

1. 上記の RDS 権限を run ロールに追加する
2. この変更を main にマージする
3. Terraform Cloud の workspace `aws` で plan を確認する
4. apply する

読み取り専用の認証情報でローカル検証した plan では、RDS への変更は
**state 上だけの項目とタグ追加のみ**で、再作成や設定変更は発生しませんでした。

```
# aws_db_instance.hackathon will be imported then updated in-place
  + apply_immediately         = false
  + final_snapshot_identifier = "prtimes-hackathon-2026summer-db-final"
  ~ skip_final_snapshot       = true -> false
  ~ tags_all                  = { + Environment, + ManagedBy, + Workspace }

Plan: 1 to import, 0 to add, 1 to change, 0 to destroy.
```

`apply_immediately` / `skip_final_snapshot` / `final_snapshot_identifier` は
AWS API 上の属性ではなく Terraform 側の挙動を決める値なので、AWS への変更は
`default_tags` の3タグ追加だけです。

apply が通ったら `import` ブロックは削除して構いません（残っていても
state に取り込み済みのリソースは無視されます）。

### 重要: CloudFormation との二重管理について

import したあとも、この RDS は **CloudFormation スタックのメンバーのまま**です。
Terraform から見えるのは AWS API の状態だけなので、スタック側を更新すると
Terraform で入れた変更が巻き戻される可能性があります。

さらに、テンプレート上 RDS は次の設定になっています。

```yaml
HackathonDb:
  Type: AWS::RDS::DBInstance
  DeletionPolicy: Delete
  UpdateReplacePolicy: Delete
```

**スタックを削除すると DB も消えます。** Terraform 側の `prevent_destroy` は
CloudFormation の削除を止められません。

恒久的に Terraform 側へ寄せるなら、import 後に次を実施してください。

1. テンプレートの `HackathonDb` を `DeletionPolicy: Retain` /
   `UpdateReplacePolicy: Retain` に変更してスタックを更新する
2. テンプレートから `HackathonDb` を削除してスタックを更新する
   （Retain 済みなので実リソースは残り、スタックの管理から外れる）
3. 以降は Terraform だけが管理者になる

1 と 2 はハッカソン運営が配布したテンプレートに手を入れる作業なので、
実施前に運営側と合意を取ってください。それまでの間は
**CloudFormation スタックを更新・削除しない**運用でカバーします。

### サブネットグループ / セキュリティグループを取り込まない理由

これらも CloudFormation 管理ですが、RDS から参照するだけなら ID を
変数で渡せば足ります。二重管理するリソースを1つに絞るため、`rds.tf` では
`var.rds_subnet_group_name` / `var.rds_security_group_id` として
文字列参照にとどめています。

## 補足

- state は Terraform Cloud が保持します。`*.tfstate` はリポジトリに入りません（`.gitignore` 済み）。
- 変数の値（`aws_region` など）は `terraform.tfvars` ではなく、
  Terraform Cloud の **Terraform variables** に設定するのが Remote 実行での定石です。
- IAM ロールの権限は、扱うリソースが固まった時点で必要最小限に絞り込むことを推奨します。
