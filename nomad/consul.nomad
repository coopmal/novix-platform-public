job "consul" {
  datacenters = ["dc1"]
  type        = "system"  # system jobs run on every node

  group "consul" {
    count = 1

    network {
      mode = "host"

      port "http" {
        static = 8500
      }

      port "dns" {
        static = 8600
      }
    }

    task "consul" {
      driver = "docker"

      config {
        image = "hashicorp/consul:latest"
        args = [
          "agent",
          "-server",
          "-bootstrap-expect=1",
          "-data-dir=/consul/data",
          "-client=0.0.0.0",
          "-ui",
          "-bind=0.0.0.0",
          "-retry-join=127.0.0.1"
        ]

        ports = ["http", "dns"]
        volumes = [
          "consul-data:/consul/data"
        ]
      }

      volume_mount {
        volume      = "consul-data"
        destination = "/consul/data"
        read_only   = false
      }

      resources {
        cpu    = 500
        memory = 256
        network {
          mbits = 10
          port "http" {}
          port "dns" {}
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

  # === Persistent Volumes ===
  volume "consul-data" {
    type      = "host"
    read_only = false
    source    = "./volumes/consul/data"
  }
}
