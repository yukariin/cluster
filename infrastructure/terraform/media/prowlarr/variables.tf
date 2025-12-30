variable "PROWLARR_API_KEY" {
  type      = string
  sensitive = true
}

variable "LIDARR_API_KEY" {
  type      = string
  sensitive = true
}

variable "RADARR_API_KEY" {
  type      = string
  sensitive = true
}

variable "SONARR_API_KEY" {
  type      = string
  sensitive = true
}

variable "prowlarr_url" {
  type    = string
  default = "http://prowlarr.media.svc.cluster.local"
}

variable "lidarr_url" {
  type    = string
  default = "http://lidarr.media.svc.cluster.local"
}

variable "radarr_url" {
  type    = string
  default = "http://radarr.media.svc.cluster.local"
}

variable "sonarr_url" {
  type    = string
  default = "http://sonarr.media.svc.cluster.local"
}
