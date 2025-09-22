#!/bin/bash
set -euo pipefail

VAULT_ADDR=${VAULT_ADDR:-"http://127.0.0.1:8200"}
INIT_FILE="./vault-init.txt"
SEALED_FILE="./vault-unseal.gpg"
GPG_PASSPHRASE_FILE="./vault-passphrase.txt"
POLICIES_DIR="./policies"

export VAULT_ADDR

# === Initialize Vault if not already initialized ===
if ! vault status | grep -q 'Initialized.*true'; then
  echo "Initializing Vault..."
  vault operator init -key-shares=1 -key-threshold=1 > "$INIT_FILE"
  echo "Vault initialized. Keys saved in $INIT_FILE"

  UNSEAL_KEY=$(grep 'Unseal Key 1:' "$INIT_FILE" | awk '{print $4}')
  ROOT_TOKEN=$(grep 'Initial Root Token:' "$INIT_FILE" | awk '{print $4}')

  # Generate GPG passphrase
  if [ ! -f "$GPG_PASSPHRASE_FILE" ]; then
    head -c 32 /dev/urandom | base64 > "$GPG_PASSPHRASE_FILE"
    chmod 600 "$GPG_PASSPHRASE_FILE"
  fi

  # Encrypt unseal key
  echo -n "$UNSEAL_KEY" | gpg --batch --yes --passphrase-file "$GPG_PASSPHRASE_FILE" -c -o "$SEALED_FILE"
  chmod 600 "$SEALED_FILE"
fi

# === Auto-unseal on startup ===
if [ -f "$SEALED_FILE" ]; then
  UNSEAL_KEY=$(gpg --batch --yes --quiet --passphrase-file "$GPG_PASSPHRASE_FILE" -d "$SEALED_FILE")
  vault operator unseal "$UNSEAL_KEY"
fi

# === Login with root token ===
if [ -f "$INIT_FILE" ]; then
  ROOT_TOKEN=$(grep 'Initial Root Token:' "$INIT_FILE" | awk '{print $4}')
  vault login "$ROOT_TOKEN"
fi

# === Enable secrets & auth methods ===
enable_secret() { local path="$1"; local type="$2"
  if ! vault secrets list -format=json | jq -e ".[\"$path/\"]" >/dev/null; then
    vault secrets enable -path="$path" "$type"
  fi
}

enable_auth() { local type="$1"
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

# === Apply policies ===
if [ -d "$POLICIES_DIR" ]; then
  for policy_file in "$POLICIES_DIR"/*.hcl; do
    vault policy write "$(basename "$policy_file" .hcl)" "$policy_file"
  done
fi

echo "Vault auto-unseal and configuration complete."
