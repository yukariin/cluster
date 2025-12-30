variable "authentik_url" {
  type        = string
  description = "authentik url used to connect"
  default     = "http://authentik-server.security.svc.cluster.local:80"
}

variable "AUTHENTIK_BOOTSTRAP_TOKEN" {
  type        = string
  description = "authentik token used for authentication to api"
  sensitive   = true
}

variable "authentik_host" {
  type        = string
  description = "public url for authentik"
}

variable "oauth2_applications" {
  type = map(object({
    url           = optional(string)
    group         = string
    client_type   = string
    client_id     = string
    client_secret = string
    redirect_uris = list(map(string))
  }))
}

variable "groups" {
  type = map(object({
    name      = string
    parent    = optional(string)
    superuser = optional(bool)
  }))
}

variable "users" {
  type = map(object({
    name   = string
    email  = string
    groups = list(string)
  }))
}
