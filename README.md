# infra

AWS を Terraform Cloud (HCP Terraform) で管理するための構成です。

## 構成

| ファイル | 役割 |
| --- | --- |
| `versions.tf` | `cloud` ブロック（organization / workspace）と provider のバージョン制約 |
| `providers.tf` | AWS provider。リージョンと `default_tags` |
| `variables.tf` | `aws_region` / `environment` / RDS・IAM ユーザー向けの変数 |
| `main.tf` | 疎通確認用の data source |
| `iam_readonly.tf` | 参照専用 IAM ユーザー、コンソールログイン、アクセスキー |
| `rds.tf` | 既存 RDS (`prtimes-hackathon-2026summer-db`) の import 定義 |
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

## RDS (`prtimes-hackathon-2026summer-db`) の取り込み

### 前提

この RDS は CloudFormation スタック `prtimes-hackathon-2026summer`（論理 ID
`HackathonDb`）で作られたものです。VPC / サブネット / pgAdmin 用 EC2 も同じ
スタックにあります。Terraform に import しても CFN 側の管理からは外れないため、
**二重管理**になります。特に次の点に注意してください。

- CFN テンプレートの `DeletionPolicy` / `UpdateReplacePolicy` は **`Delete`**。
  スタックを削除すると Terraform の `prevent_destroy` とは無関係に DB も消えます。
  → CloudFormation コンソールでスタックの **termination protection を有効化**してください。
- CFN 側でスタック更新をかけると、Terraform で変えた設定がテンプレートの値に
  戻される可能性があります。以後この DB の設定変更は Terraform 側に寄せる想定です。

### 現状のバックアップ状況（重要）

| 項目 | 値 |
| --- | --- |
| 自動バックアップ保持日数 | `0`（＝**無効**、PITR 不可） |
| 手動スナップショット | **0 件** |
| 削除保護 | 無効 |
| ストレージ暗号化 | 無効（後から有効化はできない） |

import 作業自体はデータに触れませんが、**復旧手段が何もない状態**です。
作業前に手動スナップショットを取ってください（手動スナップショットは
インスタンスを消しても残ります）。

```bash
aws rds create-db-snapshot \
  --region ap-northeast-1 \
  --db-instance-identifier prtimes-hackathon-2026summer-db \
  --db-snapshot-identifier prtimes-hackathon-2026summer-db-before-tfimport

# 完了まで待つ
aws rds wait db-snapshot-available \
  --region ap-northeast-1 \
  --db-snapshot-identifier prtimes-hackathon-2026summer-db-before-tfimport
```

`readonly` ユーザーでは実行できません。管理者権限のプロファイルかコンソールから
実行してください。

### 取り込み手順

`rds.tf` に `import` ブロックと `aws_db_instance.hackathon` を定義済みです。
属性値はすべて現状の AWS 側の値に合わせてあります。

1. スナップショットを取る（上記）
2. `terraform plan` を実行し、次を確認する
   - `1 to import, 0 to add, 0 to change, 0 to destroy`
     （タグは provider の `default_tags` で `Environment` / `ManagedBy` /
     `Workspace` が付くため、その分だけ in-place の変更として出ます。
     タグの付与はデータに影響しません）
   - **`must be replaced` / `forces replacement` の行が 1 つも無いこと**。
     もし出ていたら apply せず、差分の出ている属性を `rds.tf` の値に反映してから
     やり直してください（RDS の replacement は作り直し＝データ消失です）
3. `terraform apply`
4. import 後は `import` ブロックを削除しても構いません（残しても no-op です）

run ロールには `rds:DescribeDBInstances` / `rds:ListTagsForResource` /
`rds:AddTagsToResource` / `rds:ModifyDBInstance` が必要です。

### 取り込み後の安全側への変更（任意・別 apply 推奨）

`rds.tf` はデフォルトで現状維持なので、必要に応じて変数を変えてください。

| 変数 | 変更内容 | 影響 |
| --- | --- | --- |
| `db_deletion_protection = true` | RDS の削除保護 | 無停止。CFN のスタック削除も失敗するようになる |
| `db_backup_retention_period = 7` | 自動バックアップ・PITR を有効化 | **`0` → `1` 以上への変更はインスタンス再起動を伴う**（数十秒〜数分の断） |

`aws_db_instance.hackathon` には `prevent_destroy = true` と
`skip_final_snapshot = false` を設定してあるため、`terraform destroy` は失敗し、
仮に外しても最終スナップショットを取らずには削除できません。

## 補足

- state は Terraform Cloud が保持します。`*.tfstate` はリポジトリに入りません（`.gitignore` 済み）。
- 変数の値（`aws_region` など）は `terraform.tfvars` ではなく、
  Terraform Cloud の **Terraform variables** に設定するのが Remote 実行での定石です。
- IAM ロールの権限は、扱うリソースが固まった時点で必要最小限に絞り込むことを推奨します。
