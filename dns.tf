# ---------------------------------------------------------------------------
# プレビュー用ドメイン (Route 53 + ACM)
#
# PR ごとに DNS レコードや証明書を作る必要はない。ワイルドカードの ALIAS
# レコード 1 本と、ワイルドカード + apex を載せた証明書 1 枚で全 PR を賄う。
#
# 親ゾーン (naohanpen.dev) はこのアカウントの管理外なので、**NS 委任だけは
# 手作業**になる。委任が済むまで ACM の DNS 検証は完了せず、
# aws_acm_certificate_validation は既定で 75 分待ってから失敗する。そのため
# 「検証を待つかどうか」を preview_domain_delegated で切り替える。
#
#   1 回目の apply: preview_domain_delegated = false でゾーンと検証用レコードだけ作る
#                   → output preview_zone_name_servers を親ゾーンに NS で登録
#   2 回目の apply: preview_domain_delegated = true にする
#                   → 証明書が検証され、HTTPS リスナーが立つ
#
# 委任は済んでいるので既定は true。ゾーンを作り直して NS が変わったときだけ、
# 登録し直すまで一時的に false に戻す。
# ---------------------------------------------------------------------------

locals {
  preview_domain_enabled = var.preview_domain != null

  # 証明書の検証を待てる状態か (= 親ゾーンからの委任が済んでいるか)
  preview_certificate_enabled = local.preview_domain_enabled && var.preview_domain_delegated

  # HTTPS リスナーを作るか。count / for_each / dynamic の条件に使うので、
  # plan 時に確定する変数だけで組み立てる (証明書の ARN は apply 後にしか
  # 決まらないため、ARN の null 判定を条件にしてはいけない)。
  https_enabled = var.certificate_arn != null || local.preview_certificate_enabled

  # 明示指定があればそれを、なければ自前で取った証明書を使う。
  # どちらも無い場合は coalesce が失敗するので try で null に倒す。
  certificate_arn = try(
    coalesce(
      var.certificate_arn,
      one(aws_acm_certificate_validation.preview[*].certificate_arn),
    ),
    null,
  )
}

resource "aws_route53_zone" "preview" {
  count = local.preview_domain_enabled ? 1 : 0

  name = var.preview_domain

  # comment は ASCII しか受け付けないので英語で書く。
  comment = "PR preview environments for ${local.name}"

  tags = {
    Name = var.preview_domain
  }
}

# ワイルドカードは 1 ラベル分しかカバーしないので、apex は SAN に別途入れる。
# apex に証明書が要るのは、certificate_arn を設定すると HTTP が HTTPS に
# リダイレクトされ、ALB の DNS 名で直接叩くと証明書エラーになるため。
resource "aws_acm_certificate" "preview" {
  count = local.preview_domain_enabled ? 1 : 0

  domain_name               = "*.${var.preview_domain}"
  subject_alternative_names = [var.preview_domain]
  validation_method         = "DNS"

  tags = {
    Name = "${local.preview_name}-cert"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ワイルドカードと apex の検証レコードは名前も値も同一になる。2 つの
# for_each 要素が同じレコードを UPSERT するので上書きを許可する。
resource "aws_route53_record" "preview_certificate_validation" {
  for_each = local.preview_domain_enabled ? {
    for dvo in aws_acm_certificate.preview[0].domain_validation_options :
    dvo.domain_name => dvo
  } : {}

  zone_id         = aws_route53_zone.preview[0].zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "preview" {
  count = local.preview_certificate_enabled ? 1 : 0

  certificate_arn         = aws_acm_certificate.preview[0].arn
  validation_record_fqdns = [for r in aws_route53_record.preview_certificate_validation : r.fqdn]
}

# pr-123.preview-… を全部これ 1 本で ALB に向ける。
resource "aws_route53_record" "preview_wildcard" {
  count = local.preview_domain_enabled ? 1 : 0

  zone_id = aws_route53_zone.preview[0].zone_id
  name    = "*.${var.preview_domain}"
  type    = "A"

  alias {
    name    = aws_lb.app.dns_name
    zone_id = aws_lb.app.zone_id

    # ALB 自身のヘルスチェックに任せる。ここを true にするとリスナーの
    # 既定アクション先が unhealthy なときに名前解決ごと落ちる。
    evaluate_target_health = false
  }
}

# apex は既存の dev アプリ (リスナーの既定アクション) に当たる。
resource "aws_route53_record" "preview_apex" {
  count = local.preview_domain_enabled ? 1 : 0

  zone_id = aws_route53_zone.preview[0].zone_id
  name    = var.preview_domain
  type    = "A"

  alias {
    name                   = aws_lb.app.dns_name
    zone_id                = aws_lb.app.zone_id
    evaluate_target_health = false
  }
}
