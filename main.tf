#------------------------------------------------------------------------------#
# Additional Providers
#------------------------------------------------------------------------------#

provider "aws" {
  alias = "dns"
}

#------------------------------------------------------------------------------#
# Locals
#------------------------------------------------------------------------------#

locals {
  endpoints_dns_provider = [
    for endpoint in var.listener_https.endpoints :
    endpoint
    if endpoint.dns_provider == true
  ]

  endpoints_local_provider = [
    for endpoint in var.listener_https.endpoints :
    endpoint
    if endpoint.dns_provider == false
  ]
}

#------------------------------------------------------------------------------#
# Logs
#------------------------------------------------------------------------------#

data "aws_elb_service_account" "main" {}

data "aws_iam_policy_document" "log_bucket" {
  statement {
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${var.config.log_bucket_name}/AWSLogs/*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_elb_service_account.main.id}:root"]
    }
  }
}

resource "aws_s3_bucket" "log_bucket" {
  bucket        = var.config.log_bucket_name
  policy        = data.aws_iam_policy_document.log_bucket.json
  force_destroy = true
}

#------------------------------------------------------------------------------#
# ALB
#------------------------------------------------------------------------------#

resource "aws_lb" "main" {
  load_balancer_type = "application"
  enable_http2       = true

  name                       = var.config.name
  internal                   = var.config.internal
  enable_deletion_protection = var.config.enable_deletion_protection

  subnets         = var.network.subnets
  security_groups = var.network.security_groups

  idle_timeout    = var.config.idle_timeout
  ip_address_type = var.config.ip_address_type

  access_logs {
    enabled = true
    bucket  = aws_s3_bucket.log_bucket.id
    prefix  = ""
  }

  tags = var.default_tags
}

output "alb" {
  description = "Attribute object of aws_lb.main"
  value       = aws_lb.main
}

#------------------------------------------------------------------------------#
# Default DNS
#------------------------------------------------------------------------------#

data "aws_route53_zone" "default" {
  zone_id = var.config.default_zone_id
}

resource "aws_route53_record" "default_ipv4" {
  zone_id = data.aws_route53_zone.default.id
  name    = ""
  type    = "A"

  alias {
    name    = aws_lb.main.dns_name
    zone_id = aws_lb.main.zone_id

    evaluate_target_health = true
  }

  allow_overwrite = true
}

resource "aws_route53_record" "default_ipv6" {
  count = var.config.ip_address_type == "dualstack" ? 1 : 0

  zone_id = data.aws_route53_zone.default.id
  name    = ""
  type    = "AAAA"

  alias {
    name    = aws_lb.main.dns_name
    zone_id = aws_lb.main.zone_id

    evaluate_target_health = true
  }

  allow_overwrite = true
}

#------------------------------------------------------------------------------#
# Default Certificate
#------------------------------------------------------------------------------#

resource "aws_acm_certificate" "default" {
  count = var.config.default_certificate_arn == null ? 1 : 0

  domain_name       = replace(data.aws_route53_zone.default.name, "/.$/", "")
  validation_method = "DNS"
}

resource "aws_route53_record" "default_certificate_validation" {
  count = var.config.default_certificate_arn == null ? 1 : 0

  zone_id = data.aws_route53_zone.default.id
  name    = aws_acm_certificate.default[0].domain_validation_options[0].resource_record_name
  type    = aws_acm_certificate.default[0].domain_validation_options[0].resource_record_type
  records = [aws_acm_certificate.default[0].domain_validation_options[0].resource_record_value]
  ttl     = 60

  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "default" {
  count = var.config.default_certificate_arn == null ? 1 : 0

  certificate_arn         = aws_acm_certificate.default[0].arn
  validation_record_fqdns = [aws_route53_record.default_certificate_validation[0].fqdn]
}

#------------------------------------------------------------------------------#
# HTTP Listener
#------------------------------------------------------------------------------#

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = var.listener_http.port
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = [for action in var.listener_http.actions : {
      type   = action.type
      config = action.config
    } if action.type == "forward"]

    content {
      type             = default_action.value.type
      target_group_arn = default_action.value.config.target_group_arn
    }
  }

  dynamic "default_action" {
    for_each = [for action in var.listener_http.actions : {
      type   = action.type
      config = action.config
    } if action.type == "redirect"]

    content {
      type = default_action.value.type

      redirect {
        host        = lookup(default_action.value.config, "host", null)
        path        = lookup(default_action.value.config, "path", null)
        port        = lookup(default_action.value.config, "port", null)
        protocol    = lookup(default_action.value.config, "protocol", null)
        query       = lookup(default_action.value.config, "query", null)
        status_code = lookup(default_action.value.config, "status_code", null)
      }
    }
  }

  dynamic "default_action" {
    for_each = [for action in var.listener_http.actions : {
      type           = action.type
      fixed_response = action.config
    } if action.type == "fixed-response"]

    content {
      type = default_action.type

      fixed_response {
        content_type = lookup(default_action.value.config, "content_type", null)
        message_body = lookup(default_action.value.config, "message_body", null)
        status_code  = lookup(default_action.value.config, "status_code", null)
      }
    }
  }
}

#------------------------------------------------------------------------------#
# HTTPS Listener
#------------------------------------------------------------------------------#
# TODO:
# lookup(default_action.value.config, key, null) -> TICKET
#------------------------------------------------------------------------------#

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = var.listener_https.port
  protocol          = "HTTPS"
  certificate_arn   = var.config.default_certificate_arn == null ? aws_acm_certificate.default[0].arn : var.config.default_certificate_arn

  dynamic "default_action" {
    for_each = [for action in var.listener_https.actions : {
      type   = action.type
      config = action.config
    } if action.type == "forward"]

    content {
      type             = default_action.value.type
      target_group_arn = default_action.value.config.target_group_arn
    }
  }

  dynamic "default_action" {
    for_each = [for action in var.listener_https.actions : {
      type     = action.type
      redirect = action.config
    } if action.type == "redirect"]

    content {
      type = default_action.type

      redirect {
        host        = lookup(default_action.value.config, "host", null)
        path        = lookup(default_action.value.config, "path", null)
        port        = lookup(default_action.value.config, "port", null)
        protocol    = lookup(default_action.value.config, "protocol", null)
        query       = lookup(default_action.value.config, "query", null)
        status_code = lookup(default_action.value.config, "status_code", null)
      }
    }
  }

  dynamic "default_action" {
    for_each = [for action in var.listener_https.actions : {
      type           = action.type
      fixed_response = action.config
    } if action.type == "fixed-response"]

    content {
      type = default_action.type

      fixed_response {
        content_type = lookup(default_action.value.config, "content_type", null)
        message_body = lookup(default_action.value.config, "message_body", null)
        status_code  = lookup(default_action.value.config, "status_code", null)
      }
    }
  }

  dynamic "default_action" {
    for_each = [for action in var.listener_https.actions : {
      type                 = action.type
      authenticate_cognito = action.config
    } if action.type == "authenticate-cognito"]

    content {
      type = default_action.type

      authenticate_cognito {

        authentication_request_extra_params = lookup(default_action.value.config, "authentication_request_extra_params", null)
        on_unauthenticated_request          = lookup(default_action.value.config, "on_unauthenticated_request", null)
        scope                               = lookup(default_action.value.config, "scope", null)
        session_cookie_name                 = lookup(default_action.value.config, "session_cookie_name", null)
        session_timeout                     = lookup(default_action.value.config, "session_timeout", null)
        user_pool_arn                       = lookup(default_action.value.config, "user_pool_arn", null)
        user_pool_client_id                 = lookup(default_action.value.config, "user_pool_client_id", null)
        user_pool_domain                    = lookup(default_action.value.config, "user_pool_domain", null)

      }
    }
  }

  dynamic "default_action" {
    for_each = [for action in var.listener_https.actions : {
      type              = action.type
      authenticate_oidc = action.config
    } if action.type == "authenticate-oidc"]

    content {
      type = default_action.type

      authenticate_oidc {
        authentication_request_extra_params = lookup(default_action.value.config, "authentication_request_extra_params", null)
        authorization_endpoint              = lookup(default_action.value.config, "authorization_endpoint", null)
        client_id                           = lookup(default_action.value.config, "client_id", null)
        client_secret                       = lookup(default_action.value.config, "client_secret", null)
        issuer                              = lookup(default_action.value.config, "issuer", null)
        on_unauthenticated_request          = lookup(default_action.value.config, "on_unauthenticated_request", null)
        scope                               = lookup(default_action.value.config, "scope", null)
        session_cookie_name                 = lookup(default_action.value.config, "session_cookie_name", null)
        session_timeout                     = lookup(default_action.value.config, "session_timeout", null)
        token_endpoint                      = lookup(default_action.value.config, "token_endpoint", null)
        user_info_endpoint                  = lookup(default_action.value.config, "user_info_endpoint", null)
      }
    }
  }
}

#------------------------------------------------------------------------------#
# Certifiactes
#------------------------------------------------------------------------------#

resource "aws_lb_listener_certificate" "local_provider" {
  count = length(data.aws_route53_zone.local_provider_gen_cert.*.id)

  listener_arn    = aws_lb_listener.https.arn
  certificate_arn = aws_acm_certificate.local_provider[count.index].arn
}

resource "aws_lb_listener_certificate" "dns_provider" {
  count = length(data.aws_route53_zone.dns_provider_gen_cert.*.id)

  listener_arn    = aws_lb_listener.https.arn
  certificate_arn = aws_acm_certificate.dns_provider[count.index].arn
}
