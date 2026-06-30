#!/usr/bin/env bash
# Remove a validator from the QBFT network via governance vote, then clean up.
# Usage: ./remove-validator.sh <node-number>
#   e.g. ./remove-validator.sh 5
#
# For base validators (1..INITIAL_VALIDATOR_COUNT): only casts the governance vote
# and stops the container — their compose definition lives in docker-compose.yml.
# For extra validators (N > INITIAL_VALIDATOR_COUNT): also removes the node directory,
# docker volume, static-nodes.json entries, and rebuilds docker-compose.override.yml.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(dirname "$SCRIPT_DIR")"
cd "$DOCKER_DIR"

set -a; source .env; [[ -f .env.local ]] && source .env.local; set +a

N="${1:?usage: $0 <node-number>}"
[[ "$N" =~ ^[0-9]+$ ]] || { echo "ERROR: node number must be a positive integer" >&2; exit 1; }

BASE_COUNT="${INITIAL_VALIDATOR_COUNT:-4}"
RPC_HOST_PORT=$((8544 + N))
INTERNAL_P2P_PORT=30303
SUBNET_BASE="172.16.240"

# ── Resolve the validator's Ethereum address ─────────────────────────────────
ADDR_FILE="nodes/validator-$N/data/address"
if [[ -f "$ADDR_FILE" ]]; then
  NODE_ADDR=$(cat "$ADDR_FILE")
  echo "  address (from file): $NODE_ADDR"
else
  # Fallback: derive from RPC (requires eth_utils; node must be running)
  echo "  address file not found — deriving from admin_nodeInfo RPC..."
  NODE_ADDR=$(curl -s --max-time 5 -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"admin_nodeInfo","params":[],"id":1}' \
    "http://127.0.0.1:$RPC_HOST_PORT" \
    | python3 - <<'PY'
import sys, json
try:
    from eth_utils import keccak, to_checksum_address
    info = json.load(sys.stdin)["result"]
    pub  = bytes.fromhex(info["enode"].split("//")[1].split("@")[0])
    print(to_checksum_address("0x" + keccak(pub)[-20:].hex()))
except Exception as e:
    sys.exit(f"ERROR: could not derive address ({e}). Run make init to create address files.")
PY
  )
  echo "  address (from RPC): $NODE_ADDR"
fi

echo ""
echo "=== Validators BEFORE ==="
curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"qbft_getValidatorsByBlockNumber","params":["latest"],"id":1}' \
  http://127.0.0.1:8545 | python3 -m json.tool

# ── Cast removal votes from all other active validators ──────────────────────
echo ""
echo "Removing validator-$N  address=$NODE_ADDR"
echo "Sending removal votes from all remaining validators..."

for d in nodes/validator-*/; do
  [ -d "$d" ] || continue
  v="${d%/}"; v="${v##nodes/validator-}"
  [ "$v" = "$N" ] && continue
  [[ -f "nodes/validator-$v/data/key" ]] || continue
  port=$((8544 + v))
  resp=$(curl -sf --max-time 3 -X POST -H "Content-Type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"qbft_proposeValidatorVote\",\"params\":[\"$NODE_ADDR\",false],\"id\":1}" \
    "http://127.0.0.1:$port" 2>/dev/null) || true
  if [ -n "$resp" ]; then
    result=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result','ERROR'))" 2>/dev/null || echo "?")
    echo "  validator-$v → $result"
  else
    echo "  validator-$v → not running, skipped"
  fi
done

echo ""
echo "Waiting 30s for vote to take effect..."
sleep 30

echo ""
echo "=== Validators AFTER ==="
curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"qbft_getValidatorsByBlockNumber","params":["latest"],"id":1}' \
  http://127.0.0.1:8545 | python3 -m json.tool

IS_VALIDATOR=$(curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"qbft_getValidatorsByBlockNumber","params":["latest"],"id":1}' \
  http://127.0.0.1:8545 \
  | python3 -c \
    "import sys,json; v=[x.lower() for x in json.load(sys.stdin)['result']]; \
     print('YES' if '${NODE_ADDR}'.lower() in v else 'NO')" 2>/dev/null || echo "?")

echo "validator-$N still in active set? $IS_VALIDATOR"

# ── Stop the container ───────────────────────────────────────────────────────
echo ""
echo "Stopping container besu-validator-$N..."
docker compose stop "validator-$N" 2>/dev/null || \
  docker stop "besu-validator-$N" 2>/dev/null || true

# ── Clean up extra-validator resources ───────────────────────────────────────
if [ "$N" -gt "$BASE_COUNT" ]; then
  # Build the enode so we can scrub it from static-nodes.json on other validators
  if [[ -f "nodes/validator-$N/data/key.pub" ]]; then
    pub=$(tr -d '[:space:]' < "nodes/validator-$N/data/key.pub"); pub="${pub#0x}"
    REMOVED_ENODE="enode://${pub}@${SUBNET_BASE}.$((10 + N)):${INTERNAL_P2P_PORT}"

    echo "Removing enode from peers' static-nodes.json..."
    for snf in nodes/validator-*/data/static-nodes.json; do
      [[ -f "$snf" ]] || continue
      python3 - "$snf" "$REMOVED_ENODE" <<'PY'
import sys, json
path, enode = sys.argv[1], sys.argv[2]
peers = json.load(open(path))
new_peers = [p for p in peers if p != enode]
if len(new_peers) < len(peers):
    with open(path, 'w') as f:
        json.dump(new_peers, f, indent=2)
    print(f"  Updated: {path}")
PY
    done
  fi

  echo "Removing node data directory nodes/validator-$N/data/ ..."
  rm -rf "nodes/validator-$N/data"

  echo "Removing docker volume besu-qbft_validator-${N}-data ..."
  docker volume rm "besu-qbft_validator-${N}-data" 2>/dev/null || true

  echo "Rebuilding docker-compose.override.yml..."
  bash "$SCRIPT_DIR/render-override.sh"
else
  echo ""
  echo "NOTE: validator-$N is a base validator (defined in docker-compose.yml)."
  echo "  Its compose service definition was NOT removed — it will restart on 'make start'."
  echo "  To fully remove a base validator, edit docker-compose.yml manually."
fi

echo ""
echo "Done. Run 'make validators' to confirm the current set."
