# 既存 VPC（ハッカソン運営の CloudFormation スタック prtimes-hackathon-2026summer が
# 作成したもの）を参照する。統計用 RDS がこの VPC にいるため、新しく VPC は作らず
# ここにアプリ用のリソースを足していく。CFN 管理のリソースは data source で読むだけ。

data "aws_vpc" "main" {
  id = var.vpc_id
}

data "aws_internet_gateway" "main" {
  filter {
    name   = "attachment.vpc-id"
    values = [var.vpc_id]
  }
}

# 統計 DB が入っているプライベートサブネット。新しい RDS もここに置く。
data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }

  filter {
    name   = "tag:aws:cloudformation:logical-id"
    values = ["PrivateSubnetA", "PrivateSubnetC"]
  }
}

# 既存のパブリックサブネットは ap-northeast-1a に 1 つだけで、ALB の
# 「2 AZ 以上」要件を満たせない。アプリ用に 2 AZ 分を自前で作る。
resource "aws_subnet" "public" {
  for_each = var.public_subnets

  vpc_id                  = var.vpc_id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name}-public-${substr(each.key, -1, 1)}"
    Tier = "public"
  }
}

# 既存の IGW を使う（VPC に IGW は 1 つしか付けられない）。ルートテーブルは
# CFN 管理のものに相乗りせず自前で持つ。
resource "aws_route_table" "public" {
  vpc_id = var.vpc_id

  tags = {
    Name = "${local.name}-public"
  }
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = data.aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}
