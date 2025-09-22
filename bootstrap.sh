#!/bin/bash
set -e

echo "=== Start Novix Security Platform Bootstrap ==="

# Ensure non-interactive mode
export DEBIAN_FRONTEND=noninteractive

# === Install Docker Engine (unattended) ===
if ! command -v docker &>/dev/null; then
    echo "=== Installing Docker Engine ==="

    apt-get update -y
    apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        rsync \
        lsb-release \
        software-properties-common

    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    systemctl enable docker
    systemctl start docker

    echo "=== Docker installation completed ==="
else
    echo "Docker already installed, skipping..."
fi

# Ensure bootstrap-running user can use Docker without sudo
if ! groups "${SUDO_USER:-$(whoami)}" | grep -q "\bdocker\b"; then
    usermod -aG docker "${SUDO_USER:-$(whoami)}"
    echo "Added user ${SUDO_USER:-$(whoami)} to docker group."
fi

# === Install HashiCorp Nomad & Vault ===
echo "=== Setup HashiCorp repos ==="
if [ ! -f /usr/share/keyrings/hashicorp-archive-keyring.gpg ]; then
    wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
fi

if [ ! -f /etc/apt/sources.list.d/hashicorp.list ]; then
    UBUNTU_CODENAME=$(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs)
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $UBUNTU_CODENAME main" | tee /etc/apt/sources.list.d/hashicorp.list
fi

apt update -y
for pkg in nomad vault; do
    if ! command -v $pkg &>/dev/null; then
        apt install -y $pkg
    else
        echo "$pkg already installed, skipping..."
    fi
done

apt update -y
apt upgrade -y

# === Setup paths ===
ROOT_PATH="$(pwd)"
CONFIG_PATH="$ROOT_PATH/config"
VOLUMES_PATH="$ROOT_PATH/volumes"

# === Create volume folders ===
echo "Creating volume folders..."
mkdir -p \
  "$VOLUMES_PATH/wazuh/manager/data" \
  "$VOLUMES_PATH/wazuh/manager/logs" \
  "$VOLUMES_PATH/wazuh/indexer/data" \
  "$VOLUMES_PATH/wazuh/indexer/logs" \
  "$VOLUMES_PATH/wazuh/dashboard/data" \
  "$VOLUMES_PATH/wazuh/dashboard/logs" \
  "$ROOT_PATH/certs/wazuh" \
  "$VOLUMES_PATH/clamav/data" \
  "$VOLUMES_PATH/traefik/acme" \
  "$VOLUMES_PATH/vault/data" \
  "$VOLUMES_PATH/vault/logs" \
  "$VOLUMES_PATH/consul/data" \
  "$VOLUMES_PATH/redis/data"

# === Set folder permissions ===
echo "Setting permissions..."
chown -R root:root "$CONFIG_PATH"
chmod -R 755 "$CONFIG_PATH"

chown -R 1000:1000 "$VOLUMES_PATH/wazuh"
chmod -R 755 "$VOLUMES_PATH/wazuh"

chown -R 65532:65532 "$VOLUMES_PATH/clamav"
chmod -R 755 "$VOLUMES_PATH/clamav"

# Traefik logs directory writable by container user
chown -R root:root "$VOLUMES_PATH/traefik"
chmod -R 775 "$VOLUMES_PATH/traefik"

chown -R root:root "$VOLUMES_PATH/vault" "$VOLUMES_PATH/consul" "$VOLUMES_PATH/redis"
chmod -R 755 "$VOLUMES_PATH/vault" "$VOLUMES_PATH/consul" "$VOLUMES_PATH/redis"

# === Copy initial config files for services (if volume empty) ===
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
        echo "Copying initial configs for $svc..."
        rsync -av --progress --exclude='logs' "$src/" "$dest/"
    else
        echo "$svc volume already has data, skipping copy"
    fi
done

# === Vault systemd service ===
echo "Configure Vault systemd service..."
cat > /etc/systemd/system/vault.service <<EOF
[Unit]
Description=Vault Server
After=network.target docker.service
Requires=network.target docker.service

[Service]
User=root
Group=root
Environment=ROOT_PATH=$ROOT_PATH
Environment=CONFIG_PATH=$CONFIG_PATH
Environment=VOLUMES_PATH=$VOLUMES_PATH
Environment=VAULT_ADDR=http://127.0.0.1:8200

ExecStartPre=\$CONFIG_PATH/vault/vault-init.sh precheck
ExecStart=/usr/local/bin/vault server -config=\$CONFIG_PATH/vault/vault.hcl
ExecStartPost=\$CONFIG_PATH/vault/vault-init.sh postcheck
Restart=on-failure
RestartSec=10s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# === Nomad systemd service ===
echo "Configure Nomad systemd service..."
mkdir -p /etc/nomad.d
cp -v "$CONFIG_PATH/nomad/nomad.hcl" /etc/nomad.d/nomad.hcl

cat > /etc/systemd/system/nomad.service <<EOF
[Unit]
Description=Nomad Agent
After=network.target docker.service
Requires=docker.service

[Service]
ExecStart=/usr/local/bin/nomad agent -config=/etc/nomad.d
Restart=on-failure
RestartSec=10s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable services
systemctl daemon-reload
systemctl enable --now vault
systemctl enable --now nomad

# === Wait for Docker, Vault, Nomad readiness ===
echo "Waiting for Docker daemon..."
timeout=60; elapsed=0
while ! docker info &>/dev/null; do sleep 2; elapsed=$((elapsed+2)); [ $elapsed -ge $timeout ] && { echo "Docker not ready"; exit 1; }; done

echo "Waiting for Vault..."
vault_timeout=60; vault_elapsed=0
while ! vault status &>/dev/null; do sleep 2; vault_elapsed=$((vault_elapsed+2)); [ $vault_elapsed -ge $vault_timeout ] && { echo "Vault not ready"; exit 1; }; done

echo "Waiting for Nomad agent..."
nomad_timeout=60; nomad_elapsed=0
while ! nomad status &>/dev/null; do sleep 2; nomad_elapsed=$((nomad_elapsed+2)); [ $nomad_elapsed -ge $nomad_timeout ] && { echo "Nomad not ready"; exit 1; }; done


# === Wazuh Config Setup (Vault-backed, Git-safe) ===
WAZUH_VOLUME="$VOLUMES_PATH/wazuh/manager/data"
OSSEC_TEMPLATE="$WAZUH_VOLUME/ossec.conf.template"
OSSEC_FINAL="$WAZUH_VOLUME/ossec.conf"
SECRETS_PATH="$CONFIG_PATH/secrets"

# --- Copy template if missing ---
if [ ! -f "$OSSEC_TEMPLATE" ]; then
    echo "Copying ossec.conf.template to Wazuh volume..."
    cp -a "$CONFIG_PATH/wazuh/manager/ossec.conf.template" "$OSSEC_TEMPLATE"
fi

# --- Read secrets from files ---
WAZUH_DASHBOARD_PASSWORD=$(<"$SECRETS_PATH/wazuh-dashboard.txt")
WAZUH_CLUSTER_KEY=$(<"$SECRETS_PATH/wazuh-cluster.txt")


# --- Create Vault KV secrets if missing (idempotent) ---
vault kv get -field=dashboard_password secret/wazuh &>/dev/null || \
vault kv put secret/wazuh dashboard_password="$WAZUH_DASHBOARD_PASSWORD"
vault kv get -field=cluster_key secret/wazuh &>/dev/null || \
vault kv put secret/wazuh cluster_key="$WAZUH_CLUSTER_KEY"
# vault kv get -field=client_id secret/wazuh &>/dev/null || \
# vault kv put secret/wazuh client_id="$O365_CLIENT_ID"
# vault kv get -field=client_secret secret/wazuh &>/dev/null || \
# vault kv put secret/wazuh client_secret="$O365_CLIENT_SECRET"
# vault kv get -field=tenant_id secret/wazuh &>/dev/null || \
# vault kv put secret/wazuh tenant_id="$O365_TENANT_ID"

# --- Pull secrets from Vault for injection ---
WAZUH_DASHBOARD_PASSWORD=$(vault kv get -field=dashboard_password secret/wazuh)
WAZUH_CLUSTER_KEY=$(vault kv get -field=cluster_key secret/wazuh)
#O365_CLIENT_ID=$(vault kv get -field=client_id secret/wazuh)
#O365_CLIENT_SECRET=$(vault kv get -field=client_secret secret/wazuh)
#O365_TENANT_ID=$(vault kv get -field=tenant_id secret/wazuh)

# --- Inject secrets into ossec.conf ---
sed -e "s|{{WAZUH_DASHBOARD_PASSWORD}}|$WAZUH_DASHBOARD_PASSWORD|g" \
    -e "s|{{WAZUH_CLUSTER_KEY}}|$WAZUH_CLUSTER_KEY|g" \
    -e "s|{{O365_CLIENT_ID}}|$O365_CLIENT_ID|g" \
    -e "s|{{O365_CLIENT_SECRET}}|$O365_CLIENT_SECRET|g" \
    -e "s|{{O365_TENANT_ID}}|$O365_TENANT_ID|g" \
    "$OSSEC_TEMPLATE" > "$OSSEC_FINAL"

# --- Set secure permissions ---
chown 1000:1000 "$OSSEC_FINAL"
chmod 600 "$OSSEC_FINAL"

echo "Wazuh ossec.conf generated with secrets injected from Vault."


# === Start Nomad jobs ===
echo "Starting all Nomad jobs..."
chmod +x "${CONFIG_PATH}/nomad/nomad-jobs.sh"
bash "${CONFIG_PATH}/nomad/nomad-jobs.sh" start

echo "=== Novix Security Platform Bootstrap completed ==="
echo "Volumes are ready under $VOLUMES_PATH"
echo "Vault UI: http://localhost:8200 (TLS disabled for now)"
