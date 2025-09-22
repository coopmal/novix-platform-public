job "redis" {
  datacenters = ["dc1"]
  type        = "service"

  group "redis" {
    count = 1

    network {
      mode = "bridge"

      port "db" {
        static = 6379
        to     = 6379
      }
    }

    service {
      name = "redis"
      port = "db"
      tags = ["cache", "tcp"]
      check {
        name     = "redis tcp check"
        type     = "tcp"
        interval = "10s"
        timeout  = "2s"
      }
    }

    # === Persistent Volumes ===
    volume "redis-data" {
      type      = "host"
      read_only = false
      source    = "./volumes/redis/data"
    }

    task "redis" {
      driver = "docker"

      config {
        image = "redis:7-alpine"
        dns_config {
          nameservers = ["consul.service.consul:8600"]
          searches    = ["service.consul"]
        }
        ports = ["db"]
        volumes = [
          "redis-data:/data"
        ]
        args = ["redis-server", "--save", "60", "1", "--loglevel", "notice"]
      }

      volume_mount {
        volume      = "redis-data"
        destination = "/data"
        read_only   = false
      }

      resources {
        network {
          mbits = 10
          port "db" {}
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
