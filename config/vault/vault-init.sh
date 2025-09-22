#!/bin/bash
set -euo pipefail

VAULT_ADDR=${VAULT_ADDR:-"http://127.0.0.1:8200"}
INIT_FILE="./vault-init.txt"
SEALED_FILE="./vault-unseal.gpg"
GPG_PASSPHRASE_FILE="./vault-passphrase.txt"
POLICIES_DIR="./policies"

export VAULT_ADDR

# Wait for Vault to be ready (max 60s)
for i in {1..12}; do
    if vault status > /dev/null 2>&1; then
        break
    fi
    sleep 5
done

if ! vault status > /dev/null 2>&1; then
    echo "Vault not reachable after 60s"
    exit 1
fi

# Initialize Vault only once
if vault status | grep -q 'Initialized.*true'; then
    echo "Vault already initialized"
else
    echo "Initializing Vault..."
    vault operator init -key-shares=1 -key-threshold=1 > "$INIT_FILE"
    
    UNSEAL_KEY=$(grep 'Unseal Key 1:' "$INIT_FILE" | awk '{print $4}')
    ROOT_TOKEN=$(grep 'Initial Root Token:' "$INIT_FILE" | awk '{print $4}')

    # Generate passphrase if not exists
    if [ ! -f "$GPG_PASSPHRASE_FILE" ]; then
        head -c 32 /dev/urandom | base64 > "$GPG_PASSPHRASE_FILE"
        chmod 600 "$GPG_PASSPHRASE_FILE"
    fi

    # Encrypt unseal key
    echo -n "$UNSEAL_KEY" | gpg --batch --yes --passphrase-file "$GPG_PASSPHRASE_FILE" -c -o "$SEALED_FILE"
    chmod 600 "$SEALED_FILE"
    echo "Vault initialized and unseal key encrypted"
fi

# Auto-unseal if sealed
if vault status | grep -q 'Sealed.*true'; then
    UNSEAL_KEY=$(gpg --batch --yes --quiet --passphrase-file "$GPG_PASSPHRASE_FILE" -d "$SEALED_FILE")
    vault operator unseal "$UNSEAL_KEY"
fi

# Login with root token
if [ -f "$INIT_FILE" ]; then
    ROOT_TOKEN=$(grep 'Initial Root Token:' "$INIT_FILE" | awk '{print $4}')
    vault login "$ROOT_TOKEN"
fi

# Enable secret engines (idempotent)
enable_secret() {
    local path="$1"
    local type="$2"
    if ! vault secrets list -format=json | jq -e ".[\"$path/\"]" >/dev/null; then
        vault secrets enable -path="$path" "$type"
    fi
}

enable_auth() {
    local type="$1"
    if ! vault auth list -format=json | jq -e ".[\"$type/\"]" >/dev/null; then
        vault auth enable "$type"
    fi
}

enable_secret secret kv-v2
enable_secret database database
enable_secret aws aws
enable_secret kv kv-v1
enable_secret ssh ssh
enable_secret pki pki
enable_secret transit transit
enable_secret consul consul
enable_secret nomad nomad
enable_secret identity identity
enable_secret certs certs

enable_auth approle
enable_auth ldap
enable_auth jwt
enable_auth oidc
enable_auth github
enable_auth token

# Write policies
if [ -d "$POLICIES_DIR" ]; then
    for policy_file in "$POLICIES_DIR"/*.hcl; do
        policy_name=$(basename "$policy_file" .hcl)
        vault policy write "$policy_name" "$policy_file"
    done
fi

echo "Vault init and auto-unseal complete"
