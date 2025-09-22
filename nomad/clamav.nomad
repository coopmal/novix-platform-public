job "clamav" {
  datacenters = ["dc1"]
  type        = "service"

  group "clamav-group" {
    count = 1

    network {
      mode = "bridge"

      port "clamd" {
        static   = 3310
        to       = 3310
        protocol = "tcp"
      }
      port "dns" {
        static = 8600
      }
    }

    service {
      name = "clamav"
      port = "clamd"
      tags = ["antivirus", "tcp"]
      check {
        name     = "clamav tcp check"
        type     = "tcp"
        interval = "10s"
        timeout  = "2s"
      }
    }

    # === Persistent Volumes ===
    volume "clamav-data" {
      type      = "host"
      read_only = false
      source    = "./volumes/clamav/data"
    }

    volume "clamav-config" {
      type      = "host"
      read_only = true
      source    = "./config/clamav"
    }

    task "clamd" {
      driver = "docker"

      config {
        image = "clamav/clamav:latest"
        dns_config {
          nameservers = ["consul.service.consul:8600"]
          searches    = ["service.consul"]
        }
        ports = ["clamd"]
        command = "clamd"
        args    = ["--foreground=true"]
        volumes = [
          "clamav-data:/var/lib/clamav",
          "clamav-config:/etc/clamav"
        ]
      }

      env {
        CLAMD_TCP_PORT = "3310"
        CLAMD_LOCAL    = "false"
      }

      volume_mount {
        volume      = "clamav-data"
        destination = "/var/lib/clamav"
        read_only   = false
      }

      volume_mount {
        volume      = "clamav-config"
        destination = "/etc/clamav"
        read_only   = false
      }

      resources {
        network {
          mbits = 10
          port "clamd" {}
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
