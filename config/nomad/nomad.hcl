data_dir  = "/opt/nomad"
bind_addr = "0.0.0.0"

server {
  enabled          = true
  bootstrap_expect = 1
}

client {
  enabled           = true
  services          = true

  dns_config {
    allow_stale  = true
    max_stale    = "30s"
    node_cache   = true
    only_passing = true
  }
}

consul {
  address = "127.0.0.1:8500"
  enable_service_registration = true
  client_service_name = "nomad-client"
  namespace = "default"
  enable_script_checks = true
}