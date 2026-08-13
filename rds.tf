# 既存の RDS (PostgreSQL) を Terraform 管理下に取り込むための定義。
#
# この DB は CloudFormation スタック `prtimes-hackathon-2026summer` が
# 作成したもの (論理 ID: HackathonDb)。import ブロックで state に取り込むだけで、
# リソースそのものは作り直さない。
#
# 重要: 取り込んだ直後は CloudFormation と Terraform の二重管理になる。
# 恒久的に Terraform 側へ寄せる手順は README の
# 「RDS を Terraform 管理下に移す」を参照。

import {
  to = aws_db_instance.hackathon
  id = var.rds_identifier
}

resource "aws_db_instance" "hackathon" {
  identifier = var.rds_identifier

  engine                   = "postgres"
  engine_version           = "17.7"
  engine_lifecycle_support = "open-source-rds-extended-support"
  instance_class           = var.rds_instance_class

  # スナップショットからの復元で作成されたため、マスターユーザー名は postgres。
  # パスワードは Terraform では管理しない (lifecycle.ignore_changes 参照)。
  username = "postgres"
  port     = 5432

  allocated_storage  = var.rds_allocated_storage
  storage_type       = "gp3"
  iops               = var.rds_iops
  storage_throughput = var.rds_storage_throughput
  storage_encrypted  = false

  db_subnet_group_name   = var.rds_subnet_group_name
  vpc_security_group_ids = [var.rds_security_group_id]
  availability_zone      = "ap-northeast-1a"
  multi_az               = false
  publicly_accessible    = false
  network_type           = "IPV4"

  parameter_group_name = "default.postgres17"
  option_group_name    = "default:postgres-17"
  ca_cert_identifier   = "rds-ca-rsa2048-g1"

  # ハッカソン用途のため自動バックアップは無効 (CloudFormation 側の設定を踏襲)
  backup_retention_period  = 0
  backup_window            = "16:30-18:30"
  maintenance_window       = "sun:18:30-sun:19:00"
  copy_tags_to_snapshot    = false
  delete_automated_backups = true

  auto_minor_version_upgrade   = false
  performance_insights_enabled = false
  monitoring_interval          = 0
  deletion_protection          = var.rds_deletion_protection
  apply_immediately            = false

  # 万一 destroy された場合に備えて最終スナップショットは取る
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.rds_identifier}-final"

  tags = {
    Purpose = "hackathon"
    Event   = "2026summer"
    Team    = "team5"
  }

  lifecycle {
    # ハッカソンのデータが入っているので Terraform からは絶対に消させない
    prevent_destroy = true

    ignore_changes = [
      # マスターパスワードは AWS API から読み出せないので Terraform では持たない
      password,
      # スナップショットからの復元元は取り込み後は意味を持たない
      snapshot_identifier,
    ]
  }
}
