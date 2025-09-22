job "traefik" {
  datacenters = ["dc1"]
  type        = "service"

  group "traefik" {
    count = 1

    network {
      mode = "bridge"

      port "http" {
        static = 80
        to     = 80
      }

      port "https" {
        static = 443
        to     = 443
      }

      # TCP entrypoints for passthrough
      port "wazuh-1514" { static = 1514 to = 1514 }
      port "wazuh-1515" { static = 1515 to = 1515 }
      port "wazuh-1516" { static = 1516 to = 1516 }
      port "wazuh-55000" { static = 55000 to = 55000 }

      port "admin" {
        static = 8080
        to     = 8080
      }

      port "dns" {
        static = 8600
      }
    }

    service {
      name = "traefik-http"
      port = "http"
      tags = ["http"]
      check {
        name     = "traefik-http"
        type     = "http"
        path     = "/ping"
        interval = "10s"
        timeout  = "2s"
      }
    }

    service {
      name = "traefik-https"
      port = "https"
      tags = ["https"]
      check {
        name     = "HTTPS health check"
        type     = "tcp"
        interval = "10s"
        timeout  = "2s"
      }
    }

    service {
      name = "traefik-admin"
      port = "admin"
      tags = ["admin"]
      check {
        name     = "Admin port health check"
        type     = "tcp"
        interval = "10s"
        timeout  = "2s"
      }
    }

    # === Volumes in repo-root ===
    volume "traefik-config" {
      type      = "host"
      read_only = false
      source    = "./config/traefik"
    }

    volume "traefik-acme" {
      type      = "host"
      read_only = false
      source    = "./volumes/traefik/acme"
    }

    task "traefik" {
      driver = "docker"

      config {
        image = "traefik:latest"
        dns_config {
          nameservers = ["consul.service.consul:8600"]
          searches    = ["service.consul"]
        }

        ports = ["http", "https", "admin", "wazuh-1514", "wazuh-1515", "wazuh-1516", "wazuh-55000"]

        volumes = [
          "traefik-config:/etc/traefik",
          "traefik-acme:/etc/traefik/acme"
        ]

        args = [
          "--configFile=/etc/traefik/traefik.yml"
        ]
      }

      volume_mount {
        volume      = "traefik-config"
        destination = "/etc/traefik"
        read_only   = false
      }

      volume_mount {
        volume      = "traefik-acme"
        destination = "/etc/traefik/acme"
        read_only   = false
      }

      env {
        "CONSUL_HTTP_ADDR" = "http://host.docker.internal:8500"
      }

      resources {
        network {
          mbits = 50
          port "http" {}
          port "https" {}
          port "wazuh-1514" {}
          port "wazuh-1515" {}
          port "wazuh-1516" {}
          port "wazuh-55000" {}
          port "admin" {}
        }
      }

      restart {
        attempts = 3
        interval = "5m"
        delay    = "10s"
        mode     = "delay"
      }
    }
  }
}
