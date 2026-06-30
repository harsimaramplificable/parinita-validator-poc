#!/usr/bin/env bash
# Add one or more new validator nodes to the running Docker QBFT network.
# Usage: ./add-validator.sh [count]   (default: 1)
#
# Each new validator gets:
#   - A fresh key pair generated via a Besu container
#   - A fixed container IP (172.16.240.<10+N>) matching the docker-compose subnet
#   - An address file (nodes/validator-N/data/address) for governance operations
#   - Enode URLs built with the fixed IP (Besu rejects hostnames in static-nodes)
#   - A rebuilt docker-compose.override.yml via render-override.sh
#   - Votes from all current validators via qbft_proposeValidatorVote
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(dirname "$SCRIPT_DIR")"
cd "$DOCKER_DIR"

set -a; source .env; [[ -f .env.local ]] && source .env.local; set +a

COUNT="${1:-1}"
[[ "$COUNT" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: count must be a positive integer" >&2; exit 1; }

INTERNAL_P2P_PORT=30303
SUBNET_BASE="172.16.240"

# Find the highest existing validator number
last_n=0
for d in nodes/validator-*/; do
  [ -d "$d" ] || continue
  n="${d%/}"; n="${n##nodes/validator-}"
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt "$last_n" ] && last_n="$n"
done

for i in $(seq 1 "$COUNT"); do
  N=$((last_n + i))
  P2P_HOST_PORT=$((30302 + N))
  RPC_HOST_PORT=$((8544  + N))
  METRICS_HOST_PORT=$((9544 + N))
  CONTAINER_IP="${SUBNET_BASE}.$((10 + N))"
  NODE_DIR="$DOCKER_DIR/nodes/validator-$N"

  echo ""
  echo "══════════════════════════════════════════════════"
  echo "  Adding validator-$N  p2p=$P2P_HOST_PORT  rpc=$RPC_HOST_PORT  ip=$CONTAINER_IP"
  echo "══════════════════════════════════════════════════"

  # ── Step 1: Generate key pair ────────────────────────────────────────────────
  echo "--- [1/5] Generating key pair ---"
  mkdir -p "$NODE_DIR/data"
  tmpdir=$(mktemp -d)

  cat > "$tmpdir/config.json" <<JSONEOF
{
  "genesis": {
    "config": {
      "chainId": ${CHAIN_ID:-1337},
      "berlinBlock": 0,
      "qbft": { "blockperiodseconds": 2, "epochlength": 30000, "requesttimeoutseconds": 4 }
    },
    "nonce": "0x0", "timestamp": "0x0", "gasLimit": "0x1C9C380",
    "difficulty": "0x1",
    "mixHash": "0x63746963616c2062797a616e74696e65206661756c7420746f6c6572616e6365",
    "coinbase": "0x0000000000000000000000000000000000000000",
    "alloc": {}
  },
  "blockchain": { "nodes": { "generate": true, "count": 1 } }
}
JSONEOF

  # Besu pre-creates the output dir then errors "already exists" — keys are still
  # generated correctly. Filter the noise and verify output files directly.
  docker run --rm \
    -v "$tmpdir:/workspace" \
    "hyperledger/besu:${BESU_VERSION}" \
    operator generate-blockchain-config \
      --config-file=/workspace/config.json \
      --to=/workspace/out \
      --private-key-file-name=key 2>&1 \
    | grep -v "Output directory already exists" \
    | grep -v "^$" || true

  keydir=$(find "$tmpdir/out/keys" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -1)
  if [ -z "$keydir" ] || [ ! -f "$keydir/key" ]; then
    echo "ERROR: Key generation failed — no key file found in output." >&2
    rm -rf "$tmpdir"; exit 1
  fi

  cp "$keydir/key"     "$NODE_DIR/data/key"
  cp "$keydir/key.pub" "$NODE_DIR/data/key.pub"
  chmod 600 "$NODE_DIR/data/key"

  # Address = the Besu-generated directory name (checksum Ethereum address)
  NEW_ADDR=$(basename "$keydir")
  echo "$NEW_ADDR" > "$NODE_DIR/data/address"

  # Fix ownership on tmpdir files (Besu container runs as root)
  docker run --rm -v "$tmpdir:/target" alpine \
    chown -R "$(id -u):$(id -g)" /target 2>/dev/null || true
  rm -rf "$tmpdir" 2>/dev/null || true

  pub=$(tr -d '[:space:]' < "$NODE_DIR/data/key.pub"); pub="${pub#0x}"
  NEW_ENODE="enode://${pub}@${CONTAINER_IP}:${INTERNAL_P2P_PORT}"
  echo "  address: $NEW_ADDR"
  echo "  enode:   $NEW_ENODE"

  # ── Step 2: Update existing validators' static-nodes.json ──────────────────
  echo "--- [2/5] Updating static-nodes.json for existing validators ---"
  for existing in nodes/validator-*/data/static-nodes.json; do
    [ -f "$existing" ] || continue
    python3 - "$existing" "$NEW_ENODE" <<'PY'
import sys, json
path, enode = sys.argv[1], sys.argv[2]
peers = json.load(open(path))
if enode not in peers:
    peers.append(enode)
    with open(path, 'w') as f:
        json.dump(peers, f, indent=2)
    print(f"  Updated:        {path}")
else:
    print(f"  Already present: {path}")
PY
  done

  # Hot-add peer to running validators (static-nodes.json is read only at startup)
  echo "  Hot-adding peer via admin_addPeer..."
  for v in $(seq 1 "$last_n"); do
    port=$((8544 + v))
    resp=$(curl -sf --max-time 3 -X POST -H "Content-Type: application/json" \
      --data "{\"jsonrpc\":\"2.0\",\"method\":\"admin_addPeer\",\"params\":[\"$NEW_ENODE\"],\"id\":1}" \
      "http://127.0.0.1:$port" 2>/dev/null) || true
    if [ -n "$resp" ]; then
      echo "$resp" | python3 -c \
        "import sys,json; r=json.load(sys.stdin); print(f'    validator-$v → {r.get(\"result\",r.get(\"error\",\"?\"))}')" \
        2>/dev/null || true
    else
      echo "    validator-$v → not running, skipped"
    fi
  done

  # ── Step 3: Build static-nodes.json for the new node (all existing peers) ──
  echo "--- [3/5] Creating static-nodes.json for validator-$N ---"
  python3 - "$DOCKER_DIR" "$N" "$INTERNAL_P2P_PORT" "$SUBNET_BASE" <<'PY'
import sys, json, glob, os

docker_dir, n, p2p_port, subnet = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
peers = []
for pub_file in sorted(glob.glob(os.path.join(docker_dir, "nodes", "validator-*", "data", "key.pub"))):
    vnum = int(pub_file.split(os.sep + "validator-")[1].split(os.sep)[0])
    if vnum == n:
        continue
    raw = open(pub_file).read().strip()
    pub = raw[2:] if raw.startswith("0x") else raw
    ip  = f"{subnet}.{10 + vnum}"
    peers.append(f"enode://{pub}@{ip}:{p2p_port}")
out_path = os.path.join(docker_dir, "nodes", f"validator-{n}", "data", "static-nodes.json")
with open(out_path, "w") as f:
    json.dump(peers, f, indent=2)
print(f"  Wrote {len(peers)} peers to {out_path}")
PY

  # ── Step 4: Copy config.toml and rebuild docker-compose.override.yml ────────
  echo "--- [4/5] Updating docker-compose.override.yml ---"
  cp "$DOCKER_DIR/nodes/validator-1/config.toml" "$NODE_DIR/config.toml"
  bash "$SCRIPT_DIR/render-override.sh"

  # Start the new container
  echo "  Starting besu-validator-$N..."
  docker compose up -d "validator-$N"
  echo "  Waiting 30s for the new node to sync and open RPC..."
  sleep 30

  # ── Step 5: Vote to promote to validator ────────────────────────────────────
  echo "--- [5/5] Voting to add validator-$N (address=$NEW_ADDR) ---"
  for v in $(seq 1 "$last_n"); do
    port=$((8544 + v))
    resp=$(curl -sf --max-time 3 -X POST -H "Content-Type: application/json" \
      --data "{\"jsonrpc\":\"2.0\",\"method\":\"qbft_proposeValidatorVote\",\"params\":[\"$NEW_ADDR\",true],\"id\":1}" \
      "http://127.0.0.1:$port" 2>/dev/null) || true
    if [ -n "$resp" ]; then
      result=$(echo "$resp" | python3 -c \
        "import sys,json; print(json.load(sys.stdin).get('result','ERROR'))" 2>/dev/null || echo "parse error")
      echo "    validator-$v voted: $result"
    else
      echo "    validator-$v: not running, skipped"
    fi
  done

  echo "  Waiting 30s for vote to take effect..."
  sleep 30

  IN_SET=$(curl -s -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"qbft_getValidatorsByBlockNumber","params":["latest"],"id":1}' \
    http://127.0.0.1:8545 \
    | python3 -c \
      "import sys,json; v=[x.lower() for x in json.load(sys.stdin)['result']]; \
       print('YES' if '${NEW_ADDR}'.lower() in v else 'not yet')" 2>/dev/null || echo "?")
  echo "  validator-$N in active set? $IN_SET"

  last_n=$N
done

echo ""
echo "══════════════════════════════════════════════════"
echo "  Done — added $COUNT validator(s)."
echo "  Run 'make validators' to see the current set."
echo "══════════════════════════════════════════════════"
