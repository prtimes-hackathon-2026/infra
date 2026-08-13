# ---------------------------------------------------------------------------
# PR 1 つ分のプレビュー環境
#
# ALB / ECS クラスター / RDS / サブネット / SG / IAM ロールは共有基盤のものを
# 借りる。ここで作るのは PR ごとに寿命が違う軽いリソースだけ。
#
# 設計の背景は docs/pr-preview.md を参照。
# ---------------------------------------------------------------------------

locals {
  pr = var.pull_request_number

  # webapp-pr-123。ターゲットグループ名は 32 文字までなので短く保つ。
  name = "${var.app_name}-pr-${local.pr}"

  # webapp-preview/pr-123
  path = "${var.preview_name}/pr-${local.pr}"

  host_name = "pr-${local.pr}.${var.preview_domain}"
  url       = "https://pr-${local.pr}.${var.preview_domain}"

  # PostgreSQL の識別子。ハイフンは引用符が要るのでアンダースコアにする。
  db_name = "pr_${local.pr}"
  db_role = "pr_${local.pr}"

  app_environment = merge(
    {
      NODE_ENV           = "production"
      APP_DATABASE_SSL   = "require"
      STATS_DATABASE_SSL = "require"
    },
    var.container_environment,
  )
}

# ---------------------------------------------------------------------------
# ルーティング
# ---------------------------------------------------------------------------

resource "aws_lb_target_group" "this" {
  name        = local.name
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  # PR は頻繁に入れ替わるので、共有側 (30 秒) より短くして回転を速くする。
  deregistration_delay = 15

  health_check {
    path                = var.health_check_path
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name        = local.name
    PullRequest = tostring(local.pr)
  }
}

# 優先度は 1000 + PR 番号。番号が単調増加するので衝突しない。
# 同時プレビュー数の上限はリスナールールのクォータ (既定 100 件)。
resource "aws_lb_listener_rule" "this" {
  listener_arn = var.listener_arn
  priority     = 1000 + local.pr

  condition {
    host_header {
      values = [local.host_name]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  tags = {
    Name        = local.name
    PullRequest = tostring(local.pr)
  }
}

# ---------------------------------------------------------------------------
# この PR 専用の DB 資格情報
#
# app コンテナに渡すのはこれだけ。pr_123 ロールは自分の database にしか
# 権限を持たないので、ある PR のコードが他の PR の database を触ることは
# できない (database を分けることが認可境界として成立する)。
# ---------------------------------------------------------------------------

resource "random_password" "db" {
  length  = 40
  special = false

  # PR 番号が同じ限りパスワードを作り直さない。
  keepers = {
    pull_request = local.pr
  }
}

resource "aws_secretsmanager_secret" "app_db_url" {
  name        = "${local.path}/app-db-url"
  description = "APP_DATABASE_URL for PR #${local.pr} preview"

  # PR を閉じてすぐ再オープンしても同名で作り直せるようにする。
  recovery_window_in_days = 0

  tags = {
    Name        = local.name
    PullRequest = tostring(local.pr)
  }
}

resource "aws_secretsmanager_secret_version" "app_db_url" {
  secret_id = aws_secretsmanager_secret.app_db_url.id

  secret_string = format(
    "postgresql://%s:%s@%s:%d/%s",
    local.db_role,
    random_password.db.result,
    var.db_address,
    var.db_port,
    local.db_name,
  )
}

# ---------------------------------------------------------------------------
# タスク定義
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${local.path}"
  retention_in_days = var.log_retention_days

  tags = {
    Name        = local.name
    PullRequest = tostring(local.pr)
  }
}

locals {
  bootstrap_container = {
    name  = "bootstrap"
    image = var.bootstrap_image

    # 仕事を終えたら exit 0 する。essential にすると task ごと止まる。
    essential = false

    # postgres 公式イメージの entrypoint (docker-entrypoint.sh) を経由せず
    # 直接シェルを起動する。スクリプトが必要な値は environment / secrets から
    # 受け取るので、Terraform 側でのテンプレート展開は要らない。
    entryPoint = ["/bin/sh", "-c"]
    command    = [file("${path.module}/bootstrap.sh")]

    environment = [
      { name = "DB_NAME", value = local.db_name },
      { name = "DB_ROLE", value = local.db_role },
      # RDS は rds.force_ssl が既定で有効。psql の既定 (prefer) でも通るが明示する。
      { name = "PGSSLMODE", value = "require" },
      { name = "PGCONNECT_TIMEOUT", value = "15" },
    ]

    secrets = [
      { name = "ADMIN_DATABASE_URL", valueFrom = var.admin_db_secret_arn },
      { name = "APP_DATABASE_URL", valueFrom = aws_secretsmanager_secret.app_db_url.arn },
    ]

    logConfiguration = {
      logDriver = "awslogs"

      options = {
        awslogs-group         = aws_cloudwatch_log_group.this.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "bootstrap"
      }
    }
  }

  app_container = merge(
    {
      name      = var.app_name
      image     = var.image
      essential = true

      # bootstrap が database とロールを作り終えるまで起動しない。
      # bootstrap が失敗すれば app は動かず、サーキットブレーカーが働く。
      dependsOn = [
        {
          containerName = "bootstrap"
          condition     = "SUCCESS"
        },
      ]

      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        },
      ]

      environment = [
        for k, v in local.app_environment : {
          name  = k
          value = v
        }
      ]

      # 管理者 URL は渡さない。PR のコードが受け取るのは自分の database に
      # しか権限が無い pr_<番号> ロールの URL だけ。
      secrets = [
        {
          name      = "APP_DATABASE_URL"
          valueFrom = aws_secretsmanager_secret.app_db_url.arn
        },
        {
          name      = "STATS_DATABASE_URL"
          valueFrom = var.stats_db_secret_arn
        },
      ]

      logConfiguration = {
        logDriver = "awslogs"

        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "app"
        }
      }
    },
    var.registry_credentials_secret_arn == null ? {} : {
      repositoryCredentials = {
        credentialsParameter = var.registry_credentials_secret_arn
      }
    },
  )
}

resource "aws_ecs_task_definition" "this" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = var.task_execution_role_arn
  task_role_arn            = var.task_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.task_architecture
  }

  container_definitions = jsonencode([
    local.bootstrap_container,
    local.app_container,
  ])

  tags = {
    Name        = local.name
    PullRequest = tostring(local.pr)
  }
}

# ---------------------------------------------------------------------------
# サービス
# ---------------------------------------------------------------------------

resource "aws_ecs_service" "this" {
  name            = local.name
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = 1

  # 中断されうるが、プレビュー用途では許容する。
  capacity_provider_strategy {
    capacity_provider = var.capacity_provider
    weight            = 1
  }

  # NAT の無い VPC なので、イメージ pull のためにパブリック IP を付ける。
  # inbound は SG で ALB からのみに絞られている。
  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = var.app_name
    container_port   = var.container_port
  }

  # bootstrap のイメージ pull と起動時マイグレーションの分、共有側より長めに取る。
  health_check_grace_period_seconds = 120
  enable_execute_command            = true

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # ルールが消えるより先にサービスが消えると、ドレイン中のターゲットが
  # 宙に浮く。作成時も含めて順序を固定しておく。
  depends_on = [aws_lb_listener_rule.this]

  tags = {
    Name        = local.name
    PullRequest = tostring(local.pr)
  }
}
