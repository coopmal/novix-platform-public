task "wait-for-certs" {
  driver = "raw_exec"

  config {
    command = "/bin/sh"
    args = [
      "-c",
      <<EOT
      echo "Waiting for Wazuh manager certs in Vault..."
      while ! vault kv get -field=fullchain secret/wazuh/manager >/dev/null 2>&1; do
        sleep 5
      done
      echo "Certs found!"
      EOT
    ]
  }

  env {
    VAULT_ADDR  = "http://vault.service.consul:8200"
    VAULT_TOKEN = "${NOMAD_SECRET_VAULT_TOKEN}"
  }

  # Exit once certs are ready
  lifecycle {
    hook = "prestart"
  }
}
