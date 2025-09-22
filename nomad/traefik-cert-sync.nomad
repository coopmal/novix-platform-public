job "traefik-cert-sync" {
  datacenters = ["dc1"]
  type        = "service"

  group "cert-sync-group" {
    count = 1

    network { mode = "bridge" }

    # === Task: sync Traefik ACME certs to Vault ===
    task "acme-to-vault" {
      driver = "docker"

      config {
        image   = "appropriate/curl"  # lightweight alpine with jq + curl
        command = "/bin/sh"
        args = [
          "-c",
          <<EOT
          while true; do
            # Extract certs from Traefik acme.json
            FULLCHAIN=$(jq -r '.["Certificates"][] | select(.Domain.main=="wazuh.acetos.be") | .Certificate' /traefik/acme/acme.json)
            PRIVKEY=$(jq -r '.["Certificates"][] | select(.Domain.main=="wazuh.acetos.be") | .Key' /traefik/acme/acme.json)

            # Push to Vault under secret/wazuh/manager
            vault kv put secret/wazuh/manager fullchain="$FULLCHAIN" privkey="$PRIVKEY"

            sleep 3600  # re-check hourly
          done
          EOT
        ]
        volumes = ["traefik-acme:/traefik/acme"]
      }

      volume_mount {
        volume      = "traefik-acme"
        destination = "/traefik/acme"
        read_only   = true
      }

      env {
        VAULT_ADDR  = "http://vault.service.consul:8200"
        VAULT_TOKEN = "${NOMAD_SECRET_VAULT_TOKEN}"
      }

      restart { attempts = 3 interval = "5m" delay = "15s" mode = "delay" }
    }

    # === Volumes in repo-root ===
    volume "traefik-acme" {
      type      = "host"
      source    = "./volumes/traefik/acme"
      read_only = false
    }
  }
}
