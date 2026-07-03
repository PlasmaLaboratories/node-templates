#!/usr/bin/env bash
set -euo pipefail

# Select a network configuration by re-pointing the root .env symlink to config/<network>/.env.
# Run from anywhere; paths resolve from the repo root.

usage() {
  echo "Usage: scripts/use.sh <mainnet|testnet|devnet>" >&2
  exit 1
}

[ $# -eq 1 ] || usage
network="$1"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="config/$network/.env"

[ -f "$repo_root/$target" ] || {
  echo "No such network: $network ($target not found)" >&2
  exit 1
}

ln -sf "$target" "$repo_root/.env"
echo "Selected $network (.env -> $target), docker compose commands will use this configuration"
