# 既存の統計用 RDS。エンドポイントをアプリに渡すために参照する。
data "aws_db_instance" "stats" {
  db_instance_identifier = var.stats_db_identifier
}

# アプリ用 RDS。統計 DB と同じプライベートサブネット (1a / 1c) に置く。
resource "aws_db_subnet_group" "app" {
  name        = "${local.name}-db"
  description = "Private subnets for ${local.name}"
  subnet_ids  = data.aws_subnets.private.ids

  tags = {
    Name = "${local.name}-db"
  }
}

# 空のパラメータグループを用意しておく。あとからパラメータを変えたくなったとき、
# default.* からの差し替え（再起動が必要）を避けられる。
resource "aws_db_parameter_group" "app" {
  name        = "${local.name}-pg"
  family      = "postgres${split(".", var.app_db_engine_version)[0]}"
  description = "Parameter group for ${local.name}"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "app" {
  identifier = "${local.name}-db"

  engine         = "postgres"
  engine_version = var.app_db_engine_version
  instance_class = var.app_db_instance_class

  # 統計 DB (db.t4g.small / gp3) と同じ構成。ストレージだけ用途に合わせて小さくしている。
  allocated_storage     = var.app_db_allocated_storage
  max_allocated_storage = var.app_db_allocated_storage * 2
  storage_type          = "gp3"
  storage_encrypted     = true
  multi_az              = false

  db_name  = var.app_db_name
  username = var.app_db_username
  port     = 5432

  # パスワードは Terraform で生成せず RDS に管理させる。state にも Git にも
  # 平文が残らず、値は Secrets Manager のシークレットに入る。
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.app.name
  parameter_group_name   = aws_db_parameter_group.app.name
  vpc_security_group_ids = [aws_security_group.app_db.id]
  publicly_accessible    = false

  backup_retention_period = var.app_db_backup_retention_days
  backup_window           = "17:00-18:00" # JST 02:00-03:00
  maintenance_window      = "sun:18:00-sun:19:00"
  copy_tags_to_snapshot   = true

  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  auto_minor_version_upgrade = false
  deletion_protection        = var.app_db_deletion_protection

  # ハッカソン用途のため、destroy 時に最終スナップショットを取らない。
  # 残したい場合は false にして final_snapshot_identifier を指定する。
  skip_final_snapshot = true

  tags = {
    Name = "${local.name}-db"
  }
}

# ---------------------------------------------------------------------------
# 統計 DB の接続情報
# ---------------------------------------------------------------------------
# 統計 DB は運営が作ったもので、マスターパスワードが Secrets Manager に
# 入っていない。空のシークレットだけ Terraform で作り、値（接続 URL）は
# 手でコンソールに入れる。こうすればパスワードが Git にも state にも載らない。

resource "aws_secretsmanager_secret" "stats_db_url" {
  name        = "${local.name}/stats-db-url"
  description = "postgres://USER:PASSWORD@${data.aws_db_instance.stats.address}:${data.aws_db_instance.stats.port}/DBNAME"

  # ハッカソン中に作り直すことを想定して、削除後すぐ同名で作れるようにする。
  recovery_window_in_days = 0

  tags = {
    Name = "${local.name}-stats-db-url"
  }
}
