# ---------------------------------------------------------------------------
# サンドボックス用のメンテナンスタスク
#
# 複製した統計 DB を触るための psql 入りのコンテナを 1 本だけ常駐させ、
# ECS Exec で入って使う。踏み台の EC2 も Session Manager の設定も要らない。
#
# クラスターを本番と分けているのは IAM のためでもある。ecs:ExecuteCommand の
# リソースはタスク ARN (= arn:...:task/<クラスター名>/<タスクID>) で、タスク ID は
# 起動のたびに変わる。クラスターを分けておけば「サンドボックスのタスクだけ」を
# ワイルドカード 1 本で正確に表現できる (iam_ecs_exec.tf 参照)。
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "sandbox" {
  count = var.sandbox_enabled ? 1 : 0

  name = local.sandbox_name

  tags = {
    Name = local.sandbox_name
  }
}

resource "aws_ecs_cluster_capacity_providers" "sandbox" {
  count = var.sandbox_enabled ? 1 : 0

  cluster_name       = aws_ecs_cluster.sandbox[0].name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = var.sandbox_capacity_provider
    weight            = 1
  }
}

resource "aws_cloudwatch_log_group" "sandbox" {
  count = var.sandbox_enabled ? 1 : 0

  name              = "/ecs/${local.sandbox_name}"
  retention_in_days = var.log_retention_days

  tags = {
    Name = local.sandbox_name
  }
}

# ---------------------------------------------------------------------------
# タスクロール
#
# アプリのタスクロール (aws_iam_role.task) を使い回さず別に立てている。
# あちらはアプリのコードが使う権限が今後増えていく場所で、そこに相乗りすると
# メンテナンス用タスクが黙って権限を貰ってしまう。ここに要るのは exec のための
# ssmmessages だけ。
# ---------------------------------------------------------------------------

resource "aws_iam_role" "sandbox_task" {
  count = var.sandbox_enabled ? 1 : 0

  name               = "${local.sandbox_name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy" "sandbox_task_exec_command" {
  count = var.sandbox_enabled ? 1 : 0

  name   = "ecs-exec"
  role   = aws_iam_role.sandbox_task[0].id
  policy = data.aws_iam_policy_document.task_exec_command.json
}

# ---------------------------------------------------------------------------
# ネットワーク
#
# 専用 SG。inbound は無し (ALB にも繋がない)。outbound は全開にしているが、
# 到達できるのは「この SG を許可している相手」だけなので、実際に届く DB は
# サンドボックスだけ。アプリ用 DB も統計 DB 本体も ecs_tasks / pgAdmin の SG
# しか許可していないため弾かれる。
#
# 全開にしているのはイメージ pull (ECR Public)・Secrets Manager・
# CloudWatch Logs・ECS Exec の SSM エンドポイントに出るため。
# この VPC には NAT が無いのでパブリックサブネット + パブリック IP で動かす。
# ---------------------------------------------------------------------------

resource "aws_security_group" "sandbox_task" {
  count = var.sandbox_enabled ? 1 : 0

  name        = "${local.sandbox_name}-task"
  description = "Sandbox maintenance task. No inbound"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${local.sandbox_name}-task"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "sandbox_task_all" {
  count = var.sandbox_enabled ? 1 : 0

  security_group_id = aws_security_group.sandbox_task[0].id
  description       = "All outbound (image pull, AWS APIs, sandbox RDS)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------------------
# タスク定義
# ---------------------------------------------------------------------------

resource "aws_ecs_task_definition" "sandbox_maintenance" {
  count = var.sandbox_enabled ? 1 : 0

  family                   = local.sandbox_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  # シェルと psql が動けばよいので最小構成。
  cpu    = 256
  memory = 512

  execution_role_arn = aws_iam_role.task_execution.arn
  task_role_arn      = aws_iam_role.sandbox_task[0].arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name = "psql"

      # プレビューの bootstrap と同じく上流の postgres 公式イメージ。
      # ただし alpine ではなく glibc のタグを使う。ECS Exec で注入される
      # SSM エージェントのバイナリが glibc リンクで、musl の alpine では
      # 起動できず exec に失敗する。
      image     = var.sandbox_maintenance_image
      essential = true

      # postgres イメージの entrypoint は DB サーバーを起動しようとするので
      # 経由しない。ここでやりたいのは「入れる箱を生かしておく」ことだけ。
      entryPoint = ["/bin/sh", "-c"]
      command    = ["sleep infinity"]

      environment = [
        { name = "PGHOST", value = aws_db_instance.sandbox[0].address },
        { name = "PGPORT", value = tostring(aws_db_instance.sandbox[0].port) },
        { name = "PGUSER", value = data.aws_db_instance.stats.master_username },
        { name = "PGDATABASE", value = var.sandbox_db_name },
        # RDS は rds.force_ssl が既定で有効。
        { name = "PGSSLMODE", value = "require" },
        { name = "PGCONNECT_TIMEOUT", value = "15" },
      ]

      # パスワードを含むのでシークレット経由。`psql "$PGURL"` で繋がる。
      secrets = [
        {
          name      = "PGURL"
          valueFrom = aws_secretsmanager_secret.sandbox_db_url[0].arn
        },
      ]

      logConfiguration = {
        logDriver = "awslogs"

        options = {
          awslogs-group         = aws_cloudwatch_log_group.sandbox[0].name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "psql"
        }
      }
    },
  ])

  tags = {
    Name = local.sandbox_name
  }
}

# ---------------------------------------------------------------------------
# サービス
#
# 使わない間は sandbox_maintenance_desired_count = 0 で止められる
# (RDS は動いたままなので、課金を完全に止めるなら sandbox_enabled = false)。
# ---------------------------------------------------------------------------

resource "aws_ecs_service" "sandbox_maintenance" {
  count = var.sandbox_enabled ? 1 : 0

  name            = local.sandbox_name
  cluster         = aws_ecs_cluster.sandbox[0].id
  task_definition = aws_ecs_task_definition.sandbox_maintenance[0].arn
  desired_count   = var.sandbox_maintenance_desired_count

  capacity_provider_strategy {
    capacity_provider = var.sandbox_capacity_provider
    weight            = 1
  }

  network_configuration {
    subnets          = [for s in aws_subnet.public : s.id]
    security_groups  = [aws_security_group.sandbox_task[0].id]
    assign_public_ip = true
  }

  enable_execute_command = true

  # シークレットに値が入る前・実行ロールに読む権限が付く前にタスクが起動すると
  # ResourceInitializationError で落ちる。
  depends_on = [
    aws_secretsmanager_secret_version.sandbox_db_url,
    aws_iam_role_policy.task_execution_secrets,
  ]

  tags = {
    Name = local.sandbox_name
  }
}
