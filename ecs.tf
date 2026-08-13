resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_cluster" "main" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = var.container_insights
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

locals {
  # 変数名は app リポジトリの src/shared/env.ts (zod スキーマ) に合わせている。
  # 接続 URL の 2 本は必須。SSL は RDS が rds.force_ssl を既定で有効にしている
  # ため require を明示している (アプリ側の既定値も require)。
  app_environment = merge(
    {
      NODE_ENV           = "production"
      APP_DATABASE_SSL   = "require"
      STATS_DATABASE_SSL = "require"
    },
    var.container_environment,
  )
}

resource "aws_ecs_task_definition" "app" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.task_architecture
  }

  container_definitions = jsonencode([
    merge({
      name      = var.app_name
      image     = var.container_image
      essential = true

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

      secrets = [
        {
          name      = "APP_DATABASE_URL"
          valueFrom = aws_secretsmanager_secret.app_db_url.arn
        },
        {
          name      = "STATS_DATABASE_URL"
          valueFrom = aws_secretsmanager_secret.stats_db_url.arn
        },
      ]

      logConfiguration = {
        logDriver = "awslogs"

        options = {
          awslogs-group         = aws_cloudwatch_log_group.app.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "app"
        }
      }
      },
      # イメージが private なら pull 用の認証情報を渡す。public なら何も足さない。
      var.registry_credentials_secret_arn == null ? {} : {
        repositoryCredentials = {
          credentialsParameter = var.registry_credentials_secret_arn
        }
    }),
  ])
}

resource "aws_ecs_service" "app" {
  name            = local.name
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # NAT がない VPC なので、イメージ pull のためにパブリックサブネット +
  # パブリック IP で動かす。inbound は SG で ALB からのみに絞っている。
  network_configuration {
    subnets          = [for s in aws_subnet.public : s.id]
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = var.app_name
    container_port   = var.container_port
  }

  health_check_grace_period_seconds = 60
  enable_execute_command            = true

  # 起動に失敗し続けるデプロイを自動で切り戻す。
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener.http]
}
