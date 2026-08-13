# ハッカソン用の PostgreSQL インスタンス。
#
# 実体は CloudFormation スタック prtimes-hackathon-2026summer の HackathonDb で、
# ここでは既存インスタンスを Terraform の state に取り込む (import) だけを行う。
# 属性値はすべて現状の AWS 側の値に合わせてあるので、import の plan は
# タグの追加 (provider の default_tags 分) 以外の差分が出ないはず。
#
# 注意: CFN と Terraform の二重管理になる。スタック側の DeletionPolicy は Delete の
# ため、スタックを削除すると Terraform の prevent_destroy とは無関係に DB も消える。
# CloudFormation のスタックには termination protection をかけておくこと。

import {
  to = aws_db_instance.hackathon
  id = var.db_identifier
}

resource "aws_db_instance" "hackathon" {
  identifier     = var.db_identifier
  engine         = "postgres"
  engine_version = "17.7"
  instance_class = "db.t4g.small"
  username       = "postgres"

  # password は指定しない。import では AWS から読み取れず、書くと不要な
  # パスワード変更が走る。ローテーションが必要になったら別途対応する。

  allocated_storage  = 1000
  storage_type       = "gp3"
  iops               = 12000
  storage_throughput = 500
  storage_encrypted  = false # 既存インスタンスの実値。後から有効化はできない

  db_subnet_group_name   = "prtimes-hackathon-2026summer-dbsubnetgroup-6r3h5y8laexs"
  vpc_security_group_ids = ["sg-07a56fdc4aafa5704"]
  parameter_group_name   = "default.postgres17"
  availability_zone      = "ap-northeast-1a"
  multi_az               = false
  publicly_accessible    = false
  network_type           = "IPV4"
  port                   = 5432
  ca_cert_identifier     = "rds-ca-rsa2048-g1"

  backup_retention_period = var.db_backup_retention_period
  backup_window           = "16:30-18:30"
  maintenance_window      = "sun:18:30-sun:19:00"
  copy_tags_to_snapshot   = false

  auto_minor_version_upgrade   = false
  performance_insights_enabled = false
  monitoring_interval          = 0
  engine_lifecycle_support     = "open-source-rds-extended-support"

  deletion_protection = var.db_deletion_protection

  # 万が一 destroy が実行されても、最終スナップショットを取ってからでないと
  # 消せないようにしておく (skip_final_snapshot の既定値 false を明示)。
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.db_identifier}-final"

  tags = {
    Purpose = "hackathon"
    Event   = "2026summer"
    Team    = "team5"
  }

  lifecycle {
    # データを持つリソースなので、terraform destroy や設定ミスによる
    # 置き換えを Terraform のレベルで止める。
    prevent_destroy = true

    ignore_changes = [
      # スナップショットから復元して作られたインスタンス。復元元は API から
      # 読めないため state では null のままになる。
      snapshot_identifier,
      # マスターパスワードは Terraform の管理外。
      password,
    ]
  }
}
