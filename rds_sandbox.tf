# ---------------------------------------------------------------------------
# 統計 DB の複製 (サンドボックス)
#
# 統計 DB は運営の CloudFormation が作ったもので、こちらからは data source で
# 読むことしかできない。壊すわけにいかないので、スナップショットを 1 枚取って
# 別インスタンスに復元し、調査や試し書きはそちらでやる。
#
# 複製の中身は本物と同じデータなので、扱いは本番と同じ重みで考えること。
# 「壊しても本番に波及しない」だけで、「見せてよい」わけではない。
#
# 注意: スナップショットの取得は運営のインスタンスに対する操作になる。
# Single-AZ の RDS では取得中に短い I/O 停止が起きるため、初回 apply は
# 利用の少ない時間帯に回すこと。
# ---------------------------------------------------------------------------

locals {
  # sandbox_snapshot_version を上げるとスナップショットを取り直し、
  # 復元インスタンスも作り直される (= 最新データで作り直す操作)。
  sandbox_snapshot_identifier = "${local.sandbox_name}-stats-v${var.sandbox_snapshot_version}"
}

resource "aws_db_snapshot" "stats" {
  count = var.sandbox_enabled ? 1 : 0

  db_instance_identifier = data.aws_db_instance.stats.db_instance_identifier
  db_snapshot_identifier = local.sandbox_snapshot_identifier

  # 既定の 20 分ではデータ量によっては足りない。
  timeouts {
    create = "60m"
  }

  tags = {
    Name = local.sandbox_snapshot_identifier
  }
}

# 複製先のマスターパスワード。
#
# スナップショットから復元するとマスターユーザー名とパスワードは元のまま
# 引き継がれるが、こちらは運営のパスワードを知らない。復元と同時に
# password を渡して張り替える (RDS 側は復元後の ModifyDBInstance になる)。
# 平文が Terraform state に入る点は rds.tf の冒頭のコメントと同じ。
resource "random_password" "sandbox_db" {
  count = var.sandbox_enabled ? 1 : 0

  length  = 40
  special = false
}

resource "aws_db_instance" "sandbox" {
  count = var.sandbox_enabled ? 1 : 0

  identifier          = "${local.sandbox_name}-db"
  snapshot_identifier = aws_db_snapshot.stats[0].db_snapshot_identifier

  # engine / engine_version / allocated_storage / storage_type / kms_key_id /
  # username / db_name はスナップショットから引き継ぐので指定しない
  # (いずれも provider 側が computed なので、省略すれば実際の値が入る)。
  instance_class = var.sandbox_db_instance_class
  multi_az       = false

  # storage_encrypted だけは computed ではないため、省略すると provider の
  # 既定 false と実際の値が食い違い、plan に ForceNew の差分が出続ける
  # (暗号化状態はスナップショット由来で、復元後に変えることもできない)。
  # 元の統計 DB の値をそのまま渡して固定する。
  storage_encrypted = data.aws_db_instance.stats.storage_encrypted

  password          = random_password.sandbox_db[0].result
  apply_immediately = true

  # サブネットグループはアプリ用と同じもの (同じプライベートサブネット) で足りる。
  # パラメータグループは元のメジャーバージョンが分からないので既定に任せる。
  db_subnet_group_name   = aws_db_subnet_group.app.name
  vpc_security_group_ids = [aws_security_group.sandbox_db[0].id]
  publicly_accessible    = false

  # 使い捨てなのでバックアップは取らない。取り直したいときは
  # sandbox_snapshot_version を上げる。
  backup_retention_period = 0
  maintenance_window      = "sun:20:00-sun:21:00"

  auto_minor_version_upgrade = false
  deletion_protection        = false
  skip_final_snapshot        = true

  tags = {
    Name = "${local.sandbox_name}-db"
  }
}

# ---------------------------------------------------------------------------
# ネットワーク境界
#
# 触れるのはメンテナンス用タスクだけ。ECS タスク SG (aws_security_group.ecs_tasks)
# は許可しない — 許可すると本番の app コンテナからも複製に届いてしまい、
# 「本番とサンドボックスを分ける」という前提が崩れる。
#
# 逆向きも同じで、メンテナンス用タスクは専用 SG を持たせてあるため、
# 本番のアプリ用 DB (ecs_tasks / pgAdmin の SG のみ許可) にも
# 統計 DB 本体にも到達できない。
# ---------------------------------------------------------------------------

resource "aws_security_group" "sandbox_db" {
  count = var.sandbox_enabled ? 1 : 0

  name        = "${local.sandbox_name}-db"
  description = "PostgreSQL from the sandbox maintenance task only"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${local.sandbox_name}-db"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "sandbox_db_from_maintenance" {
  count = var.sandbox_enabled ? 1 : 0

  security_group_id            = aws_security_group.sandbox_db[0].id
  description                  = "PostgreSQL from the sandbox maintenance task"
  referenced_security_group_id = aws_security_group.sandbox_task[0].id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# ---------------------------------------------------------------------------
# 接続 URL
#
# 受け取るのはメンテナンス用タスクだけ。ecs_exec ユーザーは ReadOnlyAccess を
# 持っているのでこのシークレットは読めるが、複製の資格情報なので構わない
# (本番側のシークレットは iam_ecs_exec.tf で明示的に Deny している)。
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "sandbox_db_url" {
  count = var.sandbox_enabled ? 1 : 0

  name        = "${local.sandbox_name}/db-url"
  description = "Connection URL for the sandbox copy of the stats database"

  # 作り直しても同名で再作成できるようにする。
  recovery_window_in_days = 0

  tags = {
    Name = "${local.sandbox_name}-db-url"
  }
}

resource "aws_secretsmanager_secret_version" "sandbox_db_url" {
  count = var.sandbox_enabled ? 1 : 0

  secret_id = aws_secretsmanager_secret.sandbox_db_url[0].id

  secret_string = format(
    "postgresql://%s:%s@%s:%d/%s",
    # ユーザー名はスナップショット元 (運営の統計 DB) から引き継がれる。
    data.aws_db_instance.stats.master_username,
    random_password.sandbox_db[0].result,
    aws_db_instance.sandbox[0].address,
    aws_db_instance.sandbox[0].port,
    var.sandbox_db_name,
  )
}
