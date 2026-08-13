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
  # アプリ用 DB は接続情報を個別の環境変数で渡す。パスワードだけは
  # Secrets Manager から注入するので、DATABASE_URL を組み立てたい場合は
  # アプリ側で組み立てる。
  app_environment = merge(
    {
      DB_HOST = aws_db_instance.app.address
      DB_PORT = tostring(aws_db_instance.app.port)
      DB_NAME = var.app_db_name
      DB_USER = var.app_db_username

      STATS_DB_HOST = data.aws_db_instance.stats.address
      STATS_DB_PORT = tostring(data.aws_db_instance.stats.port)
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
    {
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
          # RDS が管理するシークレットは {"username":..,"password":..} の JSON。
          # 末尾の :password:: で password キーだけを取り出している。
          name      = "DB_PASSWORD"
          valueFrom = "${aws_db_instance.app.master_user_secret[0].secret_arn}:password::"
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
