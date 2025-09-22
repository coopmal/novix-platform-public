#!/bin/bash
set -euo pipefail

echo "=== Start Novix Security Platform Bootstrap ==="

# -------------------------------
# Environment
# -------------------------------
export DEBIAN_FRONTEND=noninteractive
ROOT_PATH="$(pwd)"
CONFIG_PATH="$ROOT_PATH/config"
VOLUMES_PATH="$ROOT_PATH/volumes"

VAULT_WORKDIR="$CONFIG_PATH/vault"
NOMAD_WORKDIR="$CONFIG_PATH/nomad"

VAULT_BIN=$(command -v vault)
NOMAD_BIN=$(command -v nomad)

# -------------------------------
# Install Docker Engine if missing
# -------------------------------
if ! command -v docker &>/dev/null; then
    echo "Installing Docker Engine..."
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg rsync lsb-release software-properties-common
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        | tee /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
fi

# Add user to docker group
if ! groups "${SUDO_USER:-$(whoami)}" | grep -q "\bdocker\b"; then
    usermod -aG docker "${SUDO_USER:-$(whoami)}"
    echo "Added user ${SUDO_USER:-$(whoami)} to docker group."
fi

# -------------------------------
# Install HashiCorp Vault & Nomad if missing
# -------------------------------
if [ ! -f /usr/share/keyrings/hashicorp-archive-keyring.gpg ]; then
    wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
fi
UBUNTU_CODENAME=$(lsb_release -cs)
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $UBUNTU_CODENAME main" \
    | tee /etc/apt/sources.list.d/hashicorp.list
apt update -y
for pkg in vault nomad; do
    if ! command -v $pkg &>/dev/null; then
        apt install -y $pkg
    fi
done

# -------------------------------
# Create volume directories
# -------------------------------
mkdir -p \
  "$VOLUMES_PATH/wazuh/manager/data" "$VOLUMES_PATH/wazuh/manager/logs" \
  "$VOLUMES_PATH/wazuh/indexer/data" "$VOLUMES_PATH/wazuh/indexer/logs" \
  "$VOLUMES_PATH/wazuh/dashboard/data" "$VOLUMES_PATH/wazuh/dashboard/logs" \
  "$ROOT_PATH/certs/wazuh" \
  "$VOLUMES_PATH/clamav/data" \
  "$VOLUMES_PATH/traefik/acme" \
  "$VOLUMES_PATH/vault/data" "$VOLUMES_PATH/vault/logs" \
  "$VOLUMES_PATH/consul/data" \
  "$VOLUMES_PATH/redis/data"

# Set ownership and permissions idempotently
chown -R root:root "$CONFIG_PATH" && chmod -R 755 "$CONFIG_PATH"
chown -R 1000:1000 "$VOLUMES_PATH/wazuh" && chmod -R 755 "$VOLUMES_PATH/wazuh"
chown -R 65532:65532 "$VOLUMES_PATH/clamav" && chmod -R 755 "$VOLUMES_PATH/clamav"
chown -R root:root "$VOLUMES_PATH/traefik" && chmod -R 775 "$VOLUMES_PATH/traefik"
chown -R root:root "$VOLUMES_PATH/vault" "$VOLUMES_PATH/consul" "$VOLUMES_PATH/redis" && chmod -R 755 "$VOLUMES_PATH/vault" "$VOLUMES_PATH/consul" "$VOLUMES_PATH/redis"

# -------------------------------
# Copy initial config files if volume empty
# -------------------------------
declare -A SERVICE_CONFIGS=(
  ["wazuh-manager"]="$CONFIG_PATH/wazuh/manager:$VOLUMES_PATH/wazuh/manager/data"
  ["wazuh-indexer"]="$CONFIG_PATH/wazuh/indexer:$VOLUMES_PATH/wazuh/indexer/data"
  ["wazuh-dashboard"]="$CONFIG_PATH/wazuh/dashboard:$VOLUMES_PATH/wazuh/dashboard/data"
  ["clamav"]="$CONFIG_PATH/clamav:$VOLUMES_PATH/clamav/data"
  ["traefik"]="$CONFIG_PATH/traefik:$VOLUMES_PATH/traefik/acme"
)

for svc in "${!SERVICE_CONFIGS[@]}"; do
    src="${SERVICE_CONFIGS[$svc]%%:*}"
    dest="${SERVICE_CONFIGS[$svc]##*:}"
    if [ ! -d "$dest" ] || [ -z "$(ls -A "$dest")" ]; then
        rsync -av --exclude='logs' "$src/" "$dest/"
    fi
done

# -------------------------------
# Ensure init scripts executable
# -------------------------------
chmod +x "$VAULT_WORKDIR/vault-init.sh"
chmod +x "$NOMAD_WORKDIR/nomad-jobs.sh"

# -------------------------------
# Deploy systemd templates
# -------------------------------
# Vault
sed -e "s|{{VAULT_WORKDIR}}|$VAULT_WORKDIR|g" \
    -e "s|{{VAULT_BIN}}|$VAULT_BIN|g" \
    "$VAULT_WORKDIR/templates/vault.service.template" \
    > /etc/systemd/system/vault.service

sed -e "s|{{VAULT_WORKDIR}}|$VAULT_WORKDIR|g" \
    "$VAULT_WORKDIR/templates/vault-init.service.template" \
    > /etc/systemd/system/vault-init.service

# Nomad
sed -e "s|{{NOMAD_WORKDIR}}|$NOMAD_WORKDIR|g" \
    -e "s|{{NOMAD_BIN}}|$NOMAD_BIN|g" \
    "$NOMAD_WORKDIR/templates/nomad.service.template" \
    > /etc/systemd/system/nomad.service

sed -e "s|{{NOMAD_WORKDIR}}|$NOMAD_WORKDIR|g" \
    "$NOMAD_WORKDIR/templates/nomad-init.service.template" \
    > /etc/systemd/system/nomad-init.service

systemctl daemon-reload
systemctl enable --now vault vault-init nomad nomad-init

# -------------------------------
# Wait for Docker
# -------------------------------
echo "Waiting for Docker daemon..."
timeout=60
elapsed=0
while ! docker info &>/dev/null; do
    sleep 2
    elapsed=$((elapsed + 2))
    if [ $elapsed -ge $timeout ]; then
        echo "Docker not ready after $timeout seconds"
        exit 1
    fi
done

# -------------------------------
# Wait for Vault
# -------------------------------
echo "Waiting for Vault to be ready..."
vault_timeout=120
vault_elapsed=0
until vault status &>/dev/null; do
    sleep 2
    vault_elapsed=$((vault_elapsed + 2))
    if [ $vault_elapsed -ge $vault_timeout ]; then
        echo "Vault not ready after $vault_timeout seconds"
        systemctl status vault
        exit 1
    fi
done
echo "Vault is ready."

# -------------------------------
# Wait for Nomad
# -------------------------------
echo "Waiting for Nomad agent..."
nomad_timeout=60
nomad_elapsed=0
until nomad node status &>/dev/null; do
    sleep 2
    nomad_elapsed=$((nomad_elapsed + 2))
    if [ $nomad_elapsed -ge $nomad_timeout ]; then
        echo "Nomad agent not ready after $nomad_timeout seconds"
        systemctl status nomad
        exit 1
    fi
done
echo "Nomad agent is ready."

# -------------------------------
# Vault-backed Wazuh secrets
# -------------------------------
WAZUH_VOLUME="$VOLUMES_PATH/wazuh/manager/data"
OSSEC_TEMPLATE="$WAZUH_VOLUME/ossec.conf.template"
OSSEC_FINAL="$WAZUH_VOLUME/ossec.conf"
SECRETS_PATH="$CONFIG_PATH/secrets"

# Copy template if missing
[ ! -f "$OSSEC_TEMPLATE" ] && cp -a "$CONFIG_PATH/wazuh/manager/ossec.conf.template" "$OSSEC_TEMPLATE"

# Read secrets
WAZUH_DASHBOARD_PASSWORD=$(<"$SECRETS_PATH/wazuh-dashboard.txt")
WAZUH_CLUSTER_KEY=$(<"$SECRETS_PATH/wazuh-cluster.txt")

# Put secrets to Vault if missing
vault kv get -field=dashboard_password secret/wazuh &>/dev/null || \
vault kv put secret/wazuh dashboard_password="$WAZUH_DASHBOARD_PASSWORD"
vault kv get -field=cluster_key secret/wazuh &>/dev/null || \
vault kv put secret/wazuh cluster_key="$WAZUH_CLUSTER_KEY"

# Pull secrets from Vault
WAZUH_DASHBOARD_PASSWORD=$(vault kv get -field=dashboard_password secret/wazuh)
WAZUH_CLUSTER_KEY=$(vault kv get -field=cluster_key secret/wazuh)

# Inject secrets
sed -e "s|{{WAZUH_DASHBOARD_PASSWORD}}|$WAZUH_DASHBOARD_PASSWORD|g" \
    -e "s|{{WAZUH_CLUSTER_KEY}}|$WAZUH_CLUSTER_KEY|g" \
    "$OSSEC_TEMPLATE" > "$OSSEC_FINAL"
chown 1000:1000 "$OSSEC_FINAL"
chmod 600 "$OSSEC_FINAL"

echo "Wazuh ossec.conf generated with secrets injected from Vault."

# -------------------------------
# Start Nomad jobs
# -------------------------------
echo "Starting Nomad jobs..."
bash "$NOMAD_WORKDIR/nomad-jobs.sh" start

echo "=== Novix Security Platform Bootstrap completed ==="
echo "Volumes under $VOLUMES_PATH"
echo "Vault UI: http://localhost:8200 (TLS disabled)"
