#------------------------------------------------------------------------------#
# Terraform Remote State
#------------------------------------------------------------------------------#

terraform {
  required_version = ">= 0.12.4"

  backend "s3" {
    profile = "management"
    region  = "eu-central-1"

    encrypt        = true
    bucket         = "rsvx-terraform"
    key            = "citest/tfstate"
    dynamodb_table = "rsvx-terraform-lock-citest"
  }
}

#------------------------------------------------------------------------------#
# Provider: AWS Dev Account
#------------------------------------------------------------------------------#

provider "aws" {
  max_retries = 1337
  region      = "eu-central-1"
  profile     = "devops"
}

#------------------------------------------------------------------------------#
# Additinoal Provider: Old Prod / DNS
#------------------------------------------------------------------------------#

provider "aws" {
  max_retries = 1337
  region      = "eu-central-1"
  profile     = "prod"
  alias       = "dns"
}

#------------------------------------------------------------------------------#
# Test Environment - Default VPC / Subnets
#------------------------------------------------------------------------------#

data "aws_vpc" "test" {
  default = true
}

data "aws_security_group" "test" {
  vpc_id = data.aws_vpc.test.id
  name   = "default"
}

data "aws_subnet_ids" "test" {
  vpc_id = data.aws_vpc.test.id
}

data "aws_subnet" "test" {
  count = length(data.aws_subnet_ids.test.ids)

  id = tolist(data.aws_subnet_ids.test.ids)[count.index]
}

data "aws_route53_zone" "reservix_cloud" {
  name = "reservix.cloud"

  provider = aws.dns
}

data "aws_route53_zone" "reservix_de" {
  name = "reservix.de"

  provider = aws.dns
}

data "aws_route53_zone" "reserfix_de" {
  name = "reserfix.de"

  provider = aws.dns
}


#------------------------------------------------------------------------------#
# DNS Zones
#------------------------------------------------------------------------------#

resource "aws_route53_zone" "dev_product_reservix_cloud" {
  name = "dev.product.reservix.cloud"

  force_destroy = true
}

resource "aws_route53_record" "reservix_cloud" {
  zone_id = data.aws_route53_zone.reservix_cloud.zone_id
  name    = "dev.product.reservix.cloud"
  type    = "NS"
  ttl     = 30

  records = [
    aws_route53_zone.dev_product_reservix_cloud.name_servers.0,
    aws_route53_zone.dev_product_reservix_cloud.name_servers.1,
    aws_route53_zone.dev_product_reservix_cloud.name_servers.2,
    aws_route53_zone.dev_product_reservix_cloud.name_servers.3
  ]

  provider = aws.dns
}

resource "aws_route53_zone" "dev_product_reservix_de" {
  name = "dev.product.reservix.de"

  force_destroy = true
}

resource "aws_route53_record" "reservix_de" {
  zone_id = data.aws_route53_zone.reservix_de.zone_id
  name    = "dev.product.reservix.de"
  type    = "NS"
  ttl     = 30

  records = [
    aws_route53_zone.dev_product_reservix_de.name_servers.0,
    aws_route53_zone.dev_product_reservix_de.name_servers.1,
    aws_route53_zone.dev_product_reservix_de.name_servers.2,
    aws_route53_zone.dev_product_reservix_de.name_servers.3,
  ]

  provider = aws.dns
}

#------------------------------------------------------------------------------#
# Target Group
#------------------------------------------------------------------------------#

resource "aws_lb_target_group" "test" {
  name     = "Test"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.test.id
}

#------------------------------------------------------------------------------#
# ALB Module
#------------------------------------------------------------------------------#

module "alb_test" {
  source = "../"

  config = {
    name                       = "Test"
    log_bucket_name            = "rsvx-devops-test-alb-logs"
    enable_deletion_protection = false
    internal                   = false
    idle_timeout               = 60
    ip_address_type            = "ipv4"
    default_zone_id            = aws_route53_zone.dev_product_reservix_cloud.zone_id
    default_certificate_arn    = null
  }

  network = {
    vpc_id          = data.aws_vpc.test.id
    subnets         = data.aws_subnet_ids.test.ids
    security_groups = data.aws_security_group.test.*.id
  }

  listener_http = {
    protocol = "HTTP"
    port     = 80

    actions = [
      {
        type = "redirect"

        config = {
          port        = 443
          protocol    = "HTTPS"
          status_code = "HTTP_301"
        }
      }
    ]
  }

  listener_https = {
    protocol = "HTTPS"
    port     = 443

    actions = [
      {
        type = "forward"

        config = {
          target_group_arn = aws_lb_target_group.test.arn
        }
      }
    ]

    endpoints = [
      {
        zone_id      = aws_route53_zone.dev_product_reservix_cloud.zone_id
        subdomain    = "*"
        gen_cert     = true
        dns_provider = false
      },
      {
        zone_id      = aws_route53_zone.dev_product_reservix_de.zone_id
        subdomain    = "www"
        gen_cert     = true
        dns_provider = false
      },
      {
        zone_id      = data.aws_route53_zone.reservix_cloud.zone_id
        subdomain    = "alb-dev-dynamic"
        gen_cert     = true
        dns_provider = true
      },
      {
        zone_id      = data.aws_route53_zone.reservix_cloud.zone_id
        subdomain    = "alb-dev-static"
        gen_cert     = false
        dns_provider = true
      },
      {
        zone_id      = data.aws_route53_zone.reserfix_de.zone_id
        subdomain    = "*"
        gen_cert     = true
        dns_provider = true
      }
    ]
  }


  tags = {
    Test = true
  }

  providers = {
    aws.dns = aws.dns
  }
}
