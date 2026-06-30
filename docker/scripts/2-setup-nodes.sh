#!/usr/bin/env bash
# Distribute generated keys into nodes/validator-N/data/ and write
# static-nodes.json for each node.
#
# Besu requires IP addresses (not hostnames) in enode URLs.
#
# SINGLE-HOST Docker Compose (default):
#   Uses the fixed IPs from .env (VALIDATOR_1_IP … VALIDATOR_4_IP).
#
# MULTI-VM:
#   Set USE_IPS=1 and fill NODE_IP_1 … NODE_IP_N in .env.local.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(dirname "$SCRIPT_DIR")"

set -a
source "$DOCKER_DIR/.env"
[[ -f "$DOCKER_DIR/.env.local" ]] && source "$DOCKER_DIR/.env.local"
set +a

NETWORK_FILES="$DOCKER_DIR/config/network-files"
USE_IPS="${USE_IPS:-0}"
INTERNAL_P2P_PORT=30303

if [ ! -d "$NETWORK_FILES/keys" ]; then
  echo "ERROR: Run scripts/1-generate-keys.sh first." >&2; exit 1
fi

KEYDIRS=()
while IFS= read -r line; do
  KEYDIRS+=("$line")
done < <(printf '%s\n' "$NETWORK_FILES"/keys/0x* | sort)
TOTAL="${#KEYDIRS[@]}"
echo "Found $TOTAL validator key dirs — assigning to node-1 … node-$TOTAL"

declare -a ENODES
for i in $(seq 0 $((TOTAL - 1))); do
  n=$((i + 1))
  NODE_DIR="$DOCKER_DIR/nodes/validator-$n/data"
  mkdir -p "$NODE_DIR"

  cp "${KEYDIRS[$i]}/key"     "$NODE_DIR/key"
  cp "${KEYDIRS[$i]}/key.pub" "$NODE_DIR/key.pub"
  chmod 600 "$NODE_DIR/key"

  # Save the Ethereum address (directory name = checksum address assigned by Besu)
  echo "$(basename "${KEYDIRS[$i]}")" > "$NODE_DIR/address"

  pub=$(tr -d '[:space:]' < "${KEYDIRS[$i]}/key.pub"); pub="${pub#0x}"

  if [ "$USE_IPS" = "1" ]; then
    ip_var="NODE_IP_$n"
    host="${!ip_var:?Variable $ip_var is not set — add it to .env.local}"
  else
    ip_var="VALIDATOR_${n}_IP"
    host="${!ip_var:?Variable $ip_var is not set in .env}"
  fi

  ENODES[$i]="enode://${pub}@${host}:${INTERNAL_P2P_PORT}"
  echo "  validator-$n  addr=$(basename "${KEYDIRS[$i]}")  ip=$host"
done

echo ""
echo "=== Writing static-nodes.json (full mesh, excluding self) ==="
for i in $(seq 0 $((TOTAL - 1))); do
  n=$((i + 1))
  OUT="$DOCKER_DIR/nodes/validator-$n/data/static-nodes.json"
  {
    echo "["
    first=1
    for j in $(seq 0 $((TOTAL - 1))); do
      [ "$j" -eq "$i" ] && continue
      [ "$first" -eq 1 ] && first=0 || echo ","
      printf '  "%s"' "${ENODES[$j]}"
    done
    printf '\n]\n'
  } > "$OUT"
  echo "  validator-$n: wrote static-nodes.json ($((TOTAL - 1)) peers)"
done

echo ""
echo "=== Setup complete ==="
echo "Run 'make start' (or docker compose up -d) to launch the network."
