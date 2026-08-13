# infra

AWS を Terraform Cloud (HCP Terraform) で管理するための構成です。

## 構成

| ファイル | 役割 |
| --- | --- |
| `versions.tf` | `cloud` ブロック（organization / workspace）と provider のバージョン制約 |
| `providers.tf` | AWS provider。リージョンと `default_tags` |
| `variables.tf` | `aws_region` / `environment` |
| `main.tf` | 疎通確認用の data source と共通の locals |
| `iam_readonly.tf` | 参照専用 IAM ユーザー、コンソールログイン、アクセスキー |
| `network.tf` | 既存 VPC の参照、アプリ用パブリックサブネットとルーティング |
| `security_groups.tf` | ALB / ECS タスク / RDS の SG、既存の統計 DB への穴あけ |
| `alb.tf` | ALB、ターゲットグループ、リスナー |
| `ecs.tf` | ECS クラスター、タスク定義、サービス、ロググループ |
| `iam_ecs.tf` | ECS のタスク実行ロールとタスクロール |
| `iam_github_actions.tf` | app リポジトリの Actions が自動デプロイに使う OIDC ロール |
| `rds.tf` | アプリ用 PostgreSQL、既存の統計 DB の参照、シークレット |
| `outputs.tf` | アカウント情報、アプリの URL、DB エンドポイント、認証情報 |

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

## ウェブアプリケーション (ECS Fargate + ALB + RDS)

コンテナイメージを ECS Fargate で動かし、ALB で公開します。DB は 2 つ使います。

| DB | 用途 | 管理 |
| --- | --- | --- |
| `prtimes-hackathon-2026summer-db` | 統計情報（既存） | 運営の CloudFormation |
| `webapp-dev-db` | アプリケーション用（新規） | このリポジトリ |

### VPC は新しく作りません

統計 DB はハッカソン運営の CloudFormation スタック `prtimes-hackathon-2026summer` が
作った VPC `vpc-00a084258f8af45ee` (10.0.0.0/16) の中にいます。新しい VPC を作ると
統計 DB と別 VPC になり、VPC ピアリングが必要になるため、**既存 VPC にアプリ用の
リソースを足す**構成にしています。CFN 管理のリソースは data source で読むだけです。

既存 VPC の構成と、それに対して足しているものは次のとおりです。

| | 既存 (CFN 管理) | このリポジトリで追加 |
| --- | --- | --- |
| パブリックサブネット | `10.0.0.0/24` (1a) のみ | `10.0.1.0/24` (1a), `10.0.2.0/24` (1c) |
| プライベートサブネット | `10.0.10.0/24` (1a), `10.0.20.0/24` (1c) | （追加なし。新 RDS はここに置く） |
| ルートテーブル | パブリック用 / プライベート用 | 追加パブリックサブネット用（既存 IGW へ） |
| NAT Gateway | 無し | 立てない（下記参照） |

パブリックサブネットを足しているのは、**ALB が 2 AZ 以上のサブネットを要求する**のに
既存のパブリックサブネットが 1a に 1 つしかないためです。

### Fargate タスクはパブリックサブネットに置いています

この VPC には NAT Gateway がなく、プライベートサブネットから外に出られません。
イメージは GitHub Container Registry にあるので、ECR 用の VPC エンドポイントを
立てても届きません。そのため**タスクをパブリックサブネットに置き、パブリック IP を
付けて**イメージを pull します。

インバウンドはセキュリティグループで **ALB からのコンテナポートのみ**に絞っており、
インターネットから直接タスクには到達できません。プライベートサブネットに置きたく
なったら NAT Gateway（月 $50 前後 + データ処理料）を追加してください。

### 統計 DB への接続

統計 DB のセキュリティグループは CFN 管理で、`5432` を **pgAdmin の EC2 の SG から
のみ**許可しています。ここに ECS タスクの SG からの ingress ルールを 1 本だけ
Terraform で追加しています（`aws_vpc_security_group_ingress_rule.stats_db_from_tasks`）。

> **注意**: 運営がスタックを更新してこの SG を作り直すと、追加したルールは消えます。
> アプリから統計 DB に繋がらなくなったら、まず `terraform apply` を実行してください。

### コンテナに渡される接続情報

変数名は app リポジトリの `src/shared/env.ts` の zod スキーマに合わせています。

| 種別 | 変数名 | 中身 |
| --- | --- | --- |
| シークレット | `APP_DATABASE_URL` | アプリ用 RDS の接続 URL（Terraform が自動生成） |
| シークレット | `STATS_DATABASE_URL` | 統計 DB の接続 URL（**手動設定が必要**） |
| 環境変数 | `APP_DATABASE_SSL` / `STATS_DATABASE_SSL` | `require` |
| 環境変数 | `NODE_ENV` | `production` |

`APP_DATABASE_POOL_MAX` (既定 10) / `STATS_DATABASE_POOL_MAX` (既定 5) はアプリ側の
既定値に任せています。上書きしたい変数は `container_environment` に map で渡します。

コンテナポートは Dockerfile の `PORT=3000` / `EXPOSE 3000` に、ヘルスチェックパスは
`/api/health`（DB に触らない liveness チェック）に合わせています。

#### アプリ用 DB のパスワードは Terraform state に入ります

アプリは接続情報を `APP_DATABASE_URL` という**1 本の URL** で受け取ります。ECS は
シークレットの値を環境変数の一部に埋め込めないため、URL を組み立てるには Terraform 側
でパスワードの平文を持つ必要があります。

RDS の `manage_master_user_password` は平文を取得できず、さらに自動ローテーションで
組み立て済みの URL が陳腐化するため使えません。したがって `random_password` で
40 桁の英数字パスワードを生成し、URL を組み立てて Secrets Manager に入れています。
**平文が Terraform state に入る**点に注意してください（state は Terraform Cloud 側で
暗号化・アクセス制御されています）。

state に入れたくない場合は、Terraform 1.11+ の write-only 引数
（`aws_db_instance.password_wo` / `aws_secretsmanager_secret_version.secret_string_wo`）と
`ephemeral "random_password"` を組み合わせる方法があります。ローテーション時に
`*_wo_version` を手で上げる運用になります。

### 主な変数

| 変数 | 既定値 | 説明 |
| --- | --- | --- |
| `container_image` | `ghcr.io/prtimes-hackathon-2026/app:latest` | デプロイするイメージ |
| `registry_credentials_secret_arn` | `null` | イメージが private の場合に指定（下記） |
| `container_port` | `3000` | Dockerfile の `EXPOSE 3000` に合わせている |
| `health_check_path` | `/api/health` | ALB のヘルスチェックパス |
| `task_architecture` | `X86_64` | arm64 イメージなら `ARM64` |
| `task_cpu` / `task_memory` | `512` / `1024` | Fargate のサイズ |
| `desired_count` | `1` | 起動タスク数 |
| `container_environment` | `{}` | 追加の環境変数 |
| `certificate_arn` | `null` | 指定すると HTTPS を有効化し、HTTP はリダイレクト |
| `app_db_instance_class` | `db.t4g.small` | 統計 DB と同じ |
| `app_db_allocated_storage` | `200` | GiB。統計 DB は 1000 だがアプリ用は小さくしてある |
| `container_insights` | `disabled` | 課金が増えるため既定は無効 |
| `github_deploy_repository` | `prtimes-hackathon-2026/app` | 自動デプロイを許可するリポジトリ |
| `github_deploy_branches` | `["main"]` | 自動デプロイを許可するブランチ |
| `create_github_oidc_provider` | `true` | GitHub 用 OIDC プロバイダを Terraform で作るか |

### デプロイ手順

**1. Terraform Cloud の run ロールに権限を追加する（先にこれが必要）**

現在の run ロール `terraform-policy` は **IAM ユーザーの操作しか許可されていません**。
このままでは VPC / ECS / RDS / ELB の作成が全て `AccessDenied` になります。
下記を `terraform-app-policy` という名前の**インラインポリシーとして追加**してください
（既存の `terraform-policyPolicy` は残す）。

run ロール自身の権限は Terraform では管理できません（自分の権限を自分で足せない）。
管理者権限のあるプリンシパルか IAM コンソールから行ってください。

<details>
<summary>追加するポリシー (JSON)</summary>

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "NetworkingRead",
      "Effect": "Allow",
      "Action": ["ec2:Describe*", "elasticloadbalancing:Describe*"],
      "Resource": "*"
    },
    {
      "Sid": "NetworkingWrite",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateSubnet",
        "ec2:DeleteSubnet",
        "ec2:ModifySubnetAttribute",
        "ec2:CreateRouteTable",
        "ec2:DeleteRouteTable",
        "ec2:CreateRoute",
        "ec2:DeleteRoute",
        "ec2:ReplaceRoute",
        "ec2:AssociateRouteTable",
        "ec2:DisassociateRouteTable",
        "ec2:CreateSecurityGroup",
        "ec2:DeleteSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:AuthorizeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupEgress",
        "ec2:ModifySecurityGroupRules",
        "ec2:UpdateSecurityGroupRuleDescriptionsIngress",
        "ec2:UpdateSecurityGroupRuleDescriptionsEgress",
        "ec2:CreateTags",
        "ec2:DeleteTags"
      ],
      "Resource": "*",
      "Condition": { "StringEquals": { "aws:RequestedRegion": "ap-northeast-1" } }
    },
    {
      "Sid": "LoadBalancerEcsRdsLogs",
      "Effect": "Allow",
      "Action": [
        "elasticloadbalancing:*",
        "ecs:*",
        "rds:*",
        "logs:*",
        "application-autoscaling:*"
      ],
      "Resource": "*",
      "Condition": { "StringEquals": { "aws:RequestedRegion": "ap-northeast-1" } }
    },
    {
      "Sid": "ManageEcsRoles",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:TagRole",
        "iam:UntagRole",
        "iam:ListRoleTags",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:ListAttachedRolePolicies",
        "iam:PutRolePolicy",
        "iam:GetRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:ListRolePolicies",
        "iam:ListInstanceProfilesForRole",
        "iam:UpdateAssumeRolePolicy"
      ],
      "Resource": ["arn:aws:iam::317695556802:role/webapp-*"]
    },
    {
      "Sid": "ManageGithubOidcProvider",
      "Effect": "Allow",
      "Action": [
        "iam:CreateOpenIDConnectProvider",
        "iam:DeleteOpenIDConnectProvider",
        "iam:GetOpenIDConnectProvider",
        "iam:TagOpenIDConnectProvider",
        "iam:UntagOpenIDConnectProvider",
        "iam:UpdateOpenIDConnectProviderThumbprint"
      ],
      "Resource": "arn:aws:iam::317695556802:oidc-provider/token.actions.githubusercontent.com"
    },
    {
      "Sid": "PassRolesToEcs",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::317695556802:role/webapp-*",
      "Condition": {
        "StringEquals": { "iam:PassedToService": "ecs-tasks.amazonaws.com" }
      }
    },
    {
      "Sid": "ServiceLinkedRoles",
      "Effect": "Allow",
      "Action": "iam:CreateServiceLinkedRole",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "iam:AWSServiceName": [
            "ecs.amazonaws.com",
            "elasticloadbalancing.amazonaws.com",
            "rds.amazonaws.com"
          ]
        }
      }
    },
    {
      "Sid": "ManageSecrets",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:CreateSecret",
        "secretsmanager:DeleteSecret",
        "secretsmanager:DescribeSecret",
        "secretsmanager:UpdateSecret",
        "secretsmanager:GetSecretValue",
        "secretsmanager:PutSecretValue",
        "secretsmanager:GetResourcePolicy",
        "secretsmanager:ListSecretVersionIds",
        "secretsmanager:TagResource",
        "secretsmanager:UntagResource"
      ],
      "Resource": [
        "arn:aws:secretsmanager:ap-northeast-1:317695556802:secret:webapp-*"
      ]
    },
    {
      "Sid": "KmsForEncryptedResources",
      "Effect": "Allow",
      "Action": ["kms:DescribeKey", "kms:ListAliases"],
      "Resource": "*"
    }
  ]
}
```

</details>

`elasticloadbalancing` / `ecs` / `rds` / `logs` はサービス単位のワイルドカードに
しています（リージョンだけ制限）。扱うリソースが固まったら絞り込んでください。

`ManageGithubOidcProvider` は自動デプロイ（後述）用の OIDC プロバイダを Terraform で
作るためのものです。プロバイダを Terraform で管理しない場合
（`create_github_oidc_provider = false`）は、代わりに `iam:GetOpenIDConnectProvider` と
`iam:ListOpenIDConnectProviders`（`Resource` は `*`）だけあれば足ります。
デプロイ用ロール本体は `webapp-*` に収まるので `ManageEcsRoles` の範囲内です。

**2. イメージが pull できる状態か確認する**

既定値は `ghcr.io/prtimes-hackathon-2026/app:latest` です。`app` リポジトリが public
なので、GHCR のパッケージも public として公開され、認証なしで pull できます
（`docker-publish.yml` が main への push で `latest` を発行、`linux/amd64` のみ）。

```bash
# 200 なら認証なしで pull できる。403 なら private または未 push
curl -s -o /dev/null -w '%{http_code}\n' \
  "https://ghcr.io/token?scope=repository:prtimes-hackathon-2026/app:pull&service=ghcr.io"
```

`403` になる場合（パッケージを private にした場合など）は、`read:packages` 権限の PAT を
`{"username": "<GitHubユーザー名>", "password": "<PAT>"}` の JSON で Secrets Manager に
保存し、その ARN を `registry_credentials_secret_arn` に渡してください。タスク実行ロールに
読み取り権限が自動で付き、`repositoryCredentials` 経由で pull します。

**3. apply**

```bash
terraform plan
terraform apply
```

**4. 統計 DB の接続 URL をシークレットに入れる**

統計 DB は運営が作ったもので、Terraform 側ではパスワードを知りようがありません。
シークレットの箱だけ作るので、値は手で入れてください。**値が入っていないと
`ResourceNotFoundException` でタスクが起動しません。**

```bash
terraform output stats_db_secret_arn
```

Secrets Manager コンソールでそのシークレットを開き、**プレーンテキスト**で
接続 URL を保存します。

```
postgresql://postgres:<統計DBのパスワード>@prtimes-hackathon-2026summer-db.cvkmyi86uqk4.ap-northeast-1.rds.amazonaws.com:5432/<dbname>
```

統計 DB には初期データベース名が設定されていないため、`<dbname>` は pgAdmin などで
実際の DB 名を確認してください。アプリからは参照しかしないので、専用の読み取り専用
ユーザー（`.env.example` の例では `stats_reader`）を作って使うのが望ましいです。

アプリ用 DB の `APP_DATABASE_URL` は Terraform が自動で入れるので、手作業は要りません。

**5. 疎通確認**

```bash
terraform output app_url
curl -i "$(terraform output -raw app_url)/api/health"   # {"status":"ok"}
curl -i "$(terraform output -raw app_url)"
```

`/api/health` は DB に触らないので、DB 接続が壊れていても 200 を返します。DB まで
確認したい場合はアプリの画面を開くか、`aws logs tail` でエラーを確認してください。

### 自動デプロイ (GitHub Actions + OIDC)

既定のイメージは `:latest` を指しています。タグが変わらないと Terraform には差分が
出ないため、**新しいイメージを push しても `terraform apply` ではデプロイされません**。
そこで app リポジトリの `docker-publish.yml` に `deploy` ジョブを置き、main への
push でイメージを publish した直後に `update-service --force-new-deployment` を
叩かせています。デプロイの流れはこうなります。

```
app の main に push
  └─ build   : ghcr.io/prtimes-hackathon-2026/app:latest を publish
     └─ deploy: OIDC で webapp-dev-github-actions-deploy を引き受ける
                → aws ecs update-service --force-new-deployment
                → aws ecs wait services-stable で収束を待つ
```

長期のアクセスキーは配りません。`iam_github_actions.tf` が GitHub の OIDC
プロバイダとデプロイ専用ロールを作り、信頼ポリシーで
`repo:prtimes-hackathon-2026/app:ref:refs/heads/main` からの実行だけに絞っています
（`aud` も `sts.amazonaws.com` に固定）。ロールにできるのは**この ECS サービスの
`UpdateService` / `DescribeServices` だけ**です。

**セットアップ (1 回だけ)**

1. run ロールに `ManageGithubOidcProvider` を追加して `terraform apply`
   （デプロイ手順 1 のポリシー参照）。OIDC プロバイダはアカウントに 1 つしか
   作れないので、他の用途で作成済みなら `create_github_oidc_provider = false`
   にして既存を参照します。
2. ロールの ARN を取り出す:

   ```bash
   terraform output -raw github_actions_deploy_role_arn
   # arn:aws:iam::317695556802:role/webapp-dev-github-actions-deploy
   ```

3. app リポジトリの **Settings → Secrets and variables → Actions → Variables** に
   `AWS_DEPLOY_ROLE_ARN` という名前で登録する（Secrets ではなく Variables）。
   この変数が空のうちは `deploy` ジョブはスキップされるので、手順 1〜2 が
   終わるまで main に push しても CI は落ちません。

デプロイを許可する対象を変えたい場合は `github_deploy_repository` /
`github_deploy_branches` を変更して apply してください。ブランチを足すと、
そのブランチの workflow もロールを引き受けられるようになります。

**手で流したいとき**（ロールバックや、CI を通さずに入れ替えたいとき）:

```bash
aws ecs update-service --force-new-deployment \
  --cluster "$(terraform output -raw ecs_cluster_name)" \
  --service "$(terraform output -raw ecs_service_name)"
```

`:latest` は動くタグなので、`update-service` を叩いた時点の `latest` が入ります。
特定のコミットに戻したいときは、`container_image` に
`ghcr.io/prtimes-hackathon-2026/app:sha-<commit>`（`docker-publish.yml` が常に
発行しています）を指定して `terraform apply` してください。

### 運用

ログを見る:

```bash
aws logs tail "$(terraform output -raw log_group_name)" --follow
```

コンテナに入る（マイグレーション実行など。ECS Exec を有効にしてあります）:

```bash
aws ecs execute-command --interactive --command /bin/sh \
  --cluster "$(terraform output -raw ecs_cluster_name)" \
  --task <task-id>
```

### 費用の目安 (ap-northeast-1, 月額)

| リソース | 概算 |
| --- | --- |
| ALB | $20 + LCU |
| Fargate (0.5 vCPU / 1GB × 1タスク常時) | $18 前後 |
| RDS db.t4g.small | $25 前後 |
| RDS gp3 200GB | $28 前後 |
| CloudWatch Logs / Secrets Manager | 数ドル |

合計で月 $90〜100 程度です。使い終わったら `terraform destroy` で消えます
（アプリ用 RDS は `skip_final_snapshot = true` なのでスナップショットは残りません）。

## 補足

- state は Terraform Cloud が保持します。`*.tfstate` はリポジトリに入りません（`.gitignore` 済み）。
- 変数の値（`aws_region` など）は `terraform.tfvars` ではなく、
  Terraform Cloud の **Terraform variables** に設定するのが Remote 実行での定石です。
- IAM ロールの権限は、扱うリソースが固まった時点で必要最小限に絞り込むことを推奨します。
