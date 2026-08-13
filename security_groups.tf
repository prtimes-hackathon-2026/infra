# ---------------------------------------------------------------------------
# ALB
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Inbound HTTP/HTTPS to the application load balancer"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${local.name}-alb"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = toset(var.alb_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTP from ${each.value}"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = local.https_enabled ? toset(var.alb_ingress_cidrs) : toset([])

  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from ${each.value}"
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# ALB からタスクへ。egress を全開にせず、転送先のポートだけ許可する。
resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  security_group_id            = aws_security_group.alb.id
  description                  = "To ECS tasks"
  referenced_security_group_id = aws_security_group.ecs_tasks.id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
}

# ---------------------------------------------------------------------------
# ECS タスク
# ---------------------------------------------------------------------------

resource "aws_security_group" "ecs_tasks" {
  name        = "${local.name}-ecs-tasks"
  description = "Application container. Inbound from the ALB only"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${local.name}-ecs-tasks"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb" {
  security_group_id            = aws_security_group.ecs_tasks.id
  description                  = "From ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.container_port
  to_port                      = var.container_port
  ip_protocol                  = "tcp"
}

# タスクはパブリックサブネットに置くので、イメージの pull・Secrets Manager・
# CloudWatch Logs はいずれもこの egress を通る。
resource "aws_vpc_security_group_egress_rule" "tasks_all" {
  security_group_id = aws_security_group.ecs_tasks.id
  description       = "All outbound (image pull, AWS APIs, RDS)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------------------
# アプリ用 RDS
# ---------------------------------------------------------------------------

resource "aws_security_group" "app_db" {
  name        = "${local.name}-db"
  description = "PostgreSQL from the application tasks only"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${local.name}-db"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "app_db_from_tasks" {
  security_group_id            = aws_security_group.app_db.id
  description                  = "PostgreSQL from ECS tasks"
  referenced_security_group_id = aws_security_group.ecs_tasks.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# pgAdmin の EC2 からも触れるようにしておく（統計 DB と同じ運用にする）。
resource "aws_vpc_security_group_ingress_rule" "app_db_from_pgadmin" {
  security_group_id            = aws_security_group.app_db.id
  description                  = "PostgreSQL from pgAdmin EC2"
  referenced_security_group_id = data.aws_security_group.pgadmin.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# ---------------------------------------------------------------------------
# 既存の統計 DB への穴あけ
# ---------------------------------------------------------------------------
# 統計 DB の SG は CloudFormation 管理なので、SG 本体は data source で読み、
# ECS タスクからの 5432 だけを独立したルールとして追加する。
# 運営側がスタックを更新して SG を作り直すとこのルールは消えるので、
# 統計 DB に繋がらなくなったらまず apply し直すこと。

data "aws_security_group" "stats_db" {
  id = one(data.aws_db_instance.stats.vpc_security_groups)
}

data "aws_security_group" "pgadmin" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }

  filter {
    name   = "tag:aws:cloudformation:logical-id"
    values = ["Ec2SecurityGroup"]
  }
}

resource "aws_vpc_security_group_ingress_rule" "stats_db_from_tasks" {
  security_group_id            = data.aws_security_group.stats_db.id
  description                  = "PostgreSQL from ${local.name} ECS tasks"
  referenced_security_group_id = aws_security_group.ecs_tasks.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# ---------------------------------------------------------------------------
# pgAdmin の EC2 への穴あけ
# ---------------------------------------------------------------------------
# こちらの SG も CloudFormation 管理なので、統計 DB と同じく本体には触らず
# 22 / 80 のルールだけを足す。運営がスタックを更新して SG を作り直すと消えるので、
# 繋がらなくなったらまず apply し直すこと。

resource "aws_vpc_security_group_ingress_rule" "pgadmin_ssh" {
  for_each = toset(var.pgadmin_ingress_cidrs)

  security_group_id = data.aws_security_group.pgadmin.id
  description       = "SSH from ${each.value}"
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "pgadmin_http" {
  for_each = toset(var.pgadmin_ingress_cidrs)

  security_group_id = data.aws_security_group.pgadmin.id
  description       = "pgAdmin from ${each.value}"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}
