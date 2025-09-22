# vault/config/vault.hcl
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1   # Nomad handles TLS via Traefik / internal network
}

storage "file" {
  path = "/vault/data"
}

api_addr = "http://vault.service.consul:8200"
ui       = true

# Enable KV v2 for secrets
default_lease_ttl = "168h"
max_lease_ttl     = "720h"
