#------------------------------------------------------------------------------#
# Global
#------------------------------------------------------------------------------#
# TODO
# enable_deletion_protection = bool
# internal                   = bool
# idle_timeout               = bool
#------------------------------------------------------------------------------#

variable "config" {
  description = "ALB settings"
  type = object({
    enable_deletion_protection = bool
    internal                   = bool
    idle_timeout               = number
    name                       = string
    log_bucket_name            = string
    ip_address_type            = string
    default_zone_id            = string
    default_certificate_arn    = string
  })
}

variable "default_tags" {
  description = "Default set of tags"
  default = {
    Terraform = "true"
  }
}

variable "tags" {
  description = "Set of tags"
  type        = map(string)
  default     = {}
}

#------------------------------------------------------------------------------#
# Network
#------------------------------------------------------------------------------#

variable "network" {
  description = "VPC settings"
  type = object({
    vpc_id          = string
    subnets         = list(string)
    security_groups = list(string)
  })
}

#------------------------------------------------------------------------------#
# Listeners
#------------------------------------------------------------------------------#

variable "listener_http" {
  description = "Listerners"
  default = {
    port    = 80
    actions = []
  }
  type = object({
    port = number
    actions = list(object({
      type   = string
      config = map(any)
    }))
  })
}

variable "listener_https" {
  description = "Listerners"
  default = {
    port      = 443
    actions   = []
    endpoints = []
  }
  type = object({
    port = number
    actions = list(object({
      type   = string
      config = map(any)
    }))
    endpoints = list(object({
      zone_id      = string
      subdomain    = string
      gen_cert     = bool
      dns_provider = bool
    }))
  })
}
