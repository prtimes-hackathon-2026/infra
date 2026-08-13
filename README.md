# infra

AWS を Terraform Cloud (HCP Terraform) で管理するための構成です。

## 構成

| ファイル | 役割 |
| --- | --- |
| `versions.tf` | `cloud` ブロック（organization / workspace）と provider のバージョン制約 |
| `providers.tf` | AWS provider。リージョンと `default_tags` |
| `variables.tf` | `aws_region` / `environment` |
| `main.tf` | 疎通確認用の data source |
| `iam_readonly.tf` | 参照専用 IAM ユーザーとアクセスキー |
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

AWS CLI から読み取り操作をするためのユーザーを `iam_readonly.tf` で作成します。

| 変数 | 既定値 | 説明 |
| --- | --- | --- |
| `readonly_user_name` | `readonly` | ユーザー名 |
| `create_access_key` | `false` | アクセスキーを Terraform で作るか |
| `allow_self_credential_management` | `true` | 本人による自分のキー / パスワード / MFA の管理を許可するか |

権限は AWS 管理ポリシー `ReadOnlyAccess` です。ほぼ全サービスの
`Get*` / `List*` / `Describe*` に加え、S3 のオブジェクト取得や
Lambda の関数コード取得など**データそのものの読み取りも含みます**。
一覧・メタデータだけに絞りたい場合は `ViewOnlyAccess` に差し替えてください。

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

## 補足

- state は Terraform Cloud が保持します。`*.tfstate` はリポジトリに入りません（`.gitignore` 済み）。
- 変数の値（`aws_region` など）は `terraform.tfvars` ではなく、
  Terraform Cloud の **Terraform variables** に設定するのが Remote 実行での定石です。
- IAM ロールの権限は、扱うリソースが固まった時点で必要最小限に絞り込むことを推奨します。
