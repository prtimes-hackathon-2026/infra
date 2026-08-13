#!/bin/sh
# ---------------------------------------------------------------------------
# PR プレビュー用の database とロールを用意する。
#
# app コンテナより先に走り (ECS の dependsOn: SUCCESS)、終わったら exit 0 する。
# タスクが起動するたびに実行されるので、全体を冪等に書いてある。
#
# 上流の postgres 公式イメージにこのスクリプトを渡すだけで動く。PR のコードは
# 一切入らないので、管理者資格情報をここに渡しても PR 由来のコードには届かない。
#
# 受け取る環境変数:
#   ADMIN_DATABASE_URL  プレビュー用 RDS の管理者 URL (ECS の secrets)
#   APP_DATABASE_URL    この PR 専用ロールの URL       (ECS の secrets)
#   DB_ROLE / DB_NAME   作る対象の名前                 (平文でよい)
# ---------------------------------------------------------------------------
set -eu

# パスワードは APP_DATABASE_URL から取り出す。タスク定義の平文側に
# パスワードを置かずに済ませるため。
# postgresql://<role>:<password>@<host>:<port>/<dbname>
credentials=${APP_DATABASE_URL#*://}
credentials=${credentials%%@*}
DB_PASSWORD=${credentials#*:}

if [ -z "$DB_PASSWORD" ] || [ "$DB_PASSWORD" = "$credentials" ]; then
  echo "bootstrap: APP_DATABASE_URL からパスワードを取り出せませんでした" >&2
  exit 1
fi

# CREATE DATABASE はトランザクションに入れられないので \gexec で流す。
# \gexec は「直前のクエリバッファ」を実行するため、SELECT の末尾に
# セミコロンを付けてはいけない。
psql "$ADMIN_DATABASE_URL" --no-psqlrc -v ON_ERROR_STOP=1 \
  -v role="$DB_ROLE" -v password="$DB_PASSWORD" -v dbname="$DB_NAME" <<'SQL'
-- ロール: 無ければ作る
SELECT format('CREATE ROLE %I LOGIN', :'role')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role')
\gexec

-- パスワードは毎回合わせる。Terraform 側で作り直されても自己修復する
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'role', :'password')
\gexec

-- PostgreSQL 16 以降、CREATEROLE ユーザーが作ったロールへの自己付与に SET は
-- 含まれない (createrole_self_grant の既定が空)。一方 CREATE DATABASE ... OWNER は
-- 対象ロールへ SET ROLE できることを要求するので、明示的に付け直す。RDS の
-- マスターユーザーは superuser ではないため、この付与を省くと弾かれる。
--
-- 付与済みのロールに対しても option を更新するだけなので、既に SET 無しで
-- 作られてしまったロールもこれで直る。
SELECT format('GRANT %I TO CURRENT_USER WITH SET TRUE', :'role')
\gexec

-- database: 所有者を PR のロールにする
SELECT format('CREATE DATABASE %I OWNER %I', :'dbname', :'role')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'dbname')
\gexec

-- CONNECT は既定で PUBLIC に付いている。このままだと pr_A のロールで pr_B の
-- database に接続でき、テーブルの中身は読めないもののカタログ (テーブル名や
-- カラム名) は覗ける。database を認可境界として成立させるため PUBLIC から外し、
-- この PR のロールと管理者にだけ明示的に戻す。
SELECT format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', :'dbname')
\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'dbname', :'role')
\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'dbname', current_user)
\gexec

-- PostgreSQL 15 以降、public スキーマの CREATE 権限は PUBLIC から外れている。
-- database の所有者なら pg_database_owner 経由で足りるはずだが、template1 の
-- 状態に依存しないよう明示的に付けておく。
\connect :dbname
GRANT ALL ON SCHEMA public TO :"role"
SQL

echo "bootstrap: database ${DB_NAME} / role ${DB_ROLE} is ready"
