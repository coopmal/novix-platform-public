job "vault" {
  datacenters = ["dc1"]
  type = "service"

  group "vault-group" {
    count = 1

    network {
      mode = "bridge"
      port "vault" {
        static = 8200
        to     = 8200
      }
    }

    service {
      name = "vault"
      port = "vault"

      check {
        type     = "tcp"
        interval = "10s"
        timeout  = "2s"
      }
    }

    # === Volumes in repo-root /volumes ===
    volume "vault-data" {
      type      = "host"
      read_only = false
      source    = "./volumes/vault/data"
    }

    volume "vault-config" {
      type      = "host"
      read_only = true
      source    = "./config/vault"
    }

    volume "vault-logs" {
      type      = "host"
      read_only = false
      source    = "./volumes/vault/logs"
    }

    task "vault" {
      driver = "docker"

      config {
        image = "vault:1.16.0"

        dns_config {
          nameservers = ["consul.service.consul:8600"]
          searches    = ["service.consul"]
        }

        ports = ["vault"]

        volumes = [
          "vault-data:/vault/data",
          "vault-config:/vault/config",
          "vault-logs:/vault/logs"
        ]

        args = [
          "server",
          "-config=/vault/config/vault.hcl"
        ]
      }

      env {
        VAULT_ADDR = "http://vault.service.consul:8200"
      }

      volume_mount {
        volume      = "vault-config"
        destination = "/vault/config"
        read_only   = true
      }

      volume_mount {
        volume      = "vault-data"
        destination = "/vault/data"
        read_only   = false
      }

      volume_mount {
        volume      = "vault-logs"
        destination = "/vault/logs"
        read_only   = false
      }

      resources {
        network {
          mbits = 10
          port "vault" {}
        }
      }

      restart {
        attempts = 3
        interval = "5m"
        delay    = "15s"
        mode     = "delay"
      }
    }
  }
}
