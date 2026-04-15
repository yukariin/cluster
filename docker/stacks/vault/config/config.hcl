ui = true
disable_mlock = true

storage "raft" {
  path    = "/vault/data"
  node_id = "node1"
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"

  tls_disable = true
}

api_addr = "http://127.0.0.1:8200"
cluster_addr = "http://127.0.0.1:8201"

log_level = "info"
