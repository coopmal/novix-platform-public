#!/bin/bash
set -euo pipefail

VAULT_ADDR=${VAULT_ADDR:-"http://127.0.0.1:8200"}
INIT_FILE="./vault-init.txt"
SEALED_FILE="./vault-unseal.gpg"
GPG_PASSPHRASE_FILE="./vault-passphrase.txt"
POLICIES_DIR="./policies"

export VAULT_ADDR

# Wait for Vault to be ready (max 60s)
echo "Waiting for Vault to be available at $VAULT_ADDR ..."
for i in {1..12}; do
  if vault status > /dev/null 2>&1; then
    break
  fi
  sleep 5
done

if ! vault status > /dev/null 2>&1; then
  echo "Vault is not reachable after 60 seconds."
  exit 1
fi

if vault status | grep -q 'Initialized.*true'; then
  echo "Vault is already initialized."
else
  echo "Initializing Vault..."
  vault operator init -key-shares=1 -key-threshold=1 > "$INIT_FILE"
  echo "Vault initialized. Keys saved in $INIT_FILE"

  UNSEAL_KEY=$(grep 'Unseal Key 1:' "$INIT_FILE" | awk '{print $4}')
  ROOT_TOKEN=$(grep 'Initial Root Token:' "$INIT_FILE" | awk '{print $4}')

  # Generate passphrase if not already set
  if [ ! -f "$GPG_PASSPHRASE_FILE" ]; then
    head -c 32 /dev/urandom | base64 > "$GPG_PASSPHRASE_FILE"
    chmod 600 "$GPG_PASSPHRASE_FILE"
    echo "Generated Vault GPG passphrase at $GPG_PASSPHRASE_FILE"
  fi

  # Encrypt unseal key with gpg symmetric encryption
  echo -n "$UNSEAL_KEY" | gpg --batch --yes \
      --passphrase-file "$GPG_PASSPHRASE_FILE" \
      -c -o "$SEALED_FILE"

  chmod 600 "$SEALED_FILE"
  echo "Unseal key encrypted and stored at $SEALED_FILE"
fi

# Always unseal Vault on startup
if [ -f "$SEALED_FILE" ]; then
  echo "Decrypting unseal key..."
  UNSEAL_KEY=$(gpg --batch --yes --quiet \
      --passphrase-file "$GPG_PASSPHRASE_FILE" \
      -d "$SEALED_FILE")
  vault operator unseal "$UNSEAL_KEY"
fi

# Login with root token (from init file)
if [ -f "$INIT_FILE" ]; then
  ROOT_TOKEN=$(grep 'Initial Root Token:' "$INIT_FILE" | awk '{print $4}')
  vault login "$ROOT_TOKEN"
fi

echo "Vault initialization and auto-unseal complete."


echo "Enabling secret engines and auth methods (idempotent)..."

enable_secret() {
  local path="$1"
  local type="$2"
  if ! vault secrets list -format=json | jq -e ".[\"$path/\"]" >/dev/null; then
    vault secrets enable -path="$path" "$type"
  else
    echo "Secret engine $path already enabled."
  fi
}

enable_auth() {
  local type="$1"
  if ! vault auth list -format=json | jq -e ".[\"$type/\"]" >/dev/null; then
    vault auth enable "$type"
  else
    echo "Auth method $type already enabled."
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


echo "Creating Vault policies..."
if [ -d "$POLICIES_DIR" ]; then
  for policy_file in "$POLICIES_DIR"/*.hcl; do
    policy_name=$(basename "$policy_file" .hcl)
    echo "Writing policy $policy_name from $policy_file"
    vault policy write "$policy_name" "$policy_file"
  done
else
  echo "No policies directory found, skipping..."
fi

echo "Vault initialization and configuration complete."
echo "You can now use the keys and tokens from $INIT_FILE to access Vault."
