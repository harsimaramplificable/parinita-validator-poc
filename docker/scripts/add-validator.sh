#!/usr/bin/env bash
# Add one or more new validator nodes to a running Docker QBFT network.
# Usage: ./add-validator.sh [count]   (default: 1)
#
# Handles emptyblockperiodseconds=9999999 by pumping transactions after each
# vote round so QBFT produces blocks and tallies the votes. Validators are
# added one at a time; each is confirmed in the active set before the next
# one begins.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(dirname "$SCRIPT_DIR")"
cd "$DOCKER_DIR"

set -a; source .env; [[ -f .env.local ]] && source .env.local; set +a

COUNT="${1:-1}"
[[ "$COUNT" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: count must be a positive integer" >&2; exit 1; }

INTERNAL_P2P_PORT=30303
SUBNET_BASE="172.16.240"

# ── Besu genesis dev accounts (PUBLICLY KNOWN KEYS – lab use only) ───────────
# These are pre-funded in genesis alloc and used only to pump transactions
# that keep block production alive when emptyblockperiodseconds is huge.
PUMP_FROM="0xfe3b557e8fb62b89f4916b721be55ceb828dbd73"
PUMP_KEY="0x8f2a55949038a9610f50fb23b5883af3b4ecb3c3bb792cbcefbd1542c692be63"
PUMP_TO="0x627306090abaB3A6e1400e9345bC60c78a8BEf57"

# ── Pre-flight: eth_account must be importable ────────────────────────────────
if ! python3 -c "from eth_account import Account" 2>/dev/null; then
  echo "ERROR: Python 'eth_account' package not found." >&2
  echo "  Install it with:  pip3 install eth-account" >&2
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# current_block PORT
#   Returns the latest block number as a decimal integer, or 0 on failure.
# ─────────────────────────────────────────────────────────────────────────────
current_block() {
  curl -sf --max-time 3 -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    "http://127.0.0.1:$1" \
    | python3 -c "import sys,json; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null \
    || echo "0"
}

# ─────────────────────────────────────────────────────────────────────────────
# pump_txns PORT [COUNT]
#   Signs and submits COUNT simple ETH transfers from the genesis dev account
#   to create pending transactions so QBFT actually produces blocks.
#   Uses "pending" nonce so repeated calls within the same block are safe.
# ─────────────────────────────────────────────────────────────────────────────
pump_txns() {
  local port="$1"
  local n="${2:-5}"
  echo "  [pump] Sending $n transactions on port $port to trigger block production..."
  python3 - "$port" "$n" "$PUMP_FROM" "$PUMP_KEY" "$PUMP_TO" "${CHAIN_ID:-1337}" <<'PY'
import sys, json, urllib.request
from eth_account import Account

port, count, tx_from, pk, tx_to, chain_id = \
    sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], int(sys.argv[6])
url = f"http://127.0.0.1:{port}"

def rpc(method, params):
    req = urllib.request.Request(
        url,
        data=json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        return json.load(urllib.request.urlopen(req, timeout=5))["result"]
    except Exception as e:
        print(f"    rpc error: {e}")
        return None

acct = Account.from_key(pk)
nonce_hex = rpc("eth_getTransactionCount", [tx_from, "pending"])
if nonce_hex is None:
    sys.exit(0)
nonce = int(nonce_hex, 16)

ok = 0
for i in range(count):
    tx = {
        "nonce": nonce + i,
        "to": tx_to,
        "value": 1,
        "gas": 21000,
        "gasPrice": 0,
        "chainId": chain_id,
    }
    signed = acct.sign_transaction(tx)
    # eth_account <0.8 uses rawTransaction; >=0.8 uses raw_transaction
    raw_bytes = getattr(signed, "raw_transaction", None) or getattr(signed, "rawTransaction")
    raw = "0x" + raw_bytes.hex()
    txhash = rpc("eth_sendRawTransaction", [raw])
    if txhash:
        ok += 1
print(f"    submitted {ok}/{count} transactions")
PY
}

# ─────────────────────────────────────────────────────────────────────────────
# wait_for_new_block PORT BASELINE [TIMEOUT_SECS]
#   Polls until block number > BASELINE.  Returns 0 on success, 1 on timeout.
# ─────────────────────────────────────────────────────────────────────────────
wait_for_new_block() {
  local port="$1"
  local baseline="$2"
  local timeout="${3:-60}"
  local elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    blk=$(current_block "$port")
    if [ "$blk" -gt "$baseline" ] 2>/dev/null; then
      echo "  [block] advanced to $blk (was $baseline)"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  echo "  [block] WARNING: no new block after ${timeout}s (still at $baseline)"
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# wait_for_validator_in_set ADDR RPC_PORT [MAX_ROUNDS]
#   Polls the chain for ADDR in qbft_getValidatorsByBlockNumber.
#   Each round: pump transactions → wait for a new block → check set.
#   Returns 0 when the validator is confirmed, 1 if MAX_ROUNDS exhausted.
# ─────────────────────────────────────────────────────────────────────────────
wait_for_validator_in_set() {
  local addr="$1"
  local port="$2"
  local max_rounds="${3:-12}"

  for round in $(seq 1 "$max_rounds"); do
    in_set=$(curl -sf --max-time 5 -X POST -H "Content-Type: application/json" \
      --data '{"jsonrpc":"2.0","method":"qbft_getValidatorsByBlockNumber","params":["latest"],"id":1}' \
      "http://127.0.0.1:$port" \
      | python3 -c "
import sys, json
data = json.load(sys.stdin)
vals = [x.lower() for x in data.get('result', [])]
print('YES' if '${addr}'.lower() in vals else 'NO')
" 2>/dev/null || echo "?")

    if [ "$in_set" = "YES" ]; then
      echo "  [confirm] Validator ${addr:0:10}... is in the active set."
      return 0
    fi

    echo "  [confirm] Round $round/$max_rounds: not yet in set — pumping transactions..."
    baseline=$(current_block "$port")
    pump_txns "$port" 6
    wait_for_new_block "$port" "$baseline" 30 || true
    sleep 2
  done

  echo "  [confirm] ERROR: validator ${addr:0:10}... NOT confirmed after $max_rounds rounds." >&2
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Find the highest existing validator number
# ─────────────────────────────────────────────────────────────────────────────
last_n=0
for d in nodes/validator-*/; do
  [ -d "$d" ] || continue
  n="${d%/}"; n="${n##nodes/validator-}"
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt "$last_n" ] && last_n="$n"
done

# Use validator-1's RPC as the stable reference for chain queries
REF_RPC_PORT=8545

# ─────────────────────────────────────────────────────────────────────────────
# Main loop — one validator at a time
# ─────────────────────────────────────────────────────────────────────────────
for i in $(seq 1 "$COUNT"); do
  N=$((last_n + i))
  P2P_HOST_PORT=$((30302 + N))
  RPC_HOST_PORT=$((8544  + N))
  METRICS_HOST_PORT=$((9544 + N))
  CONTAINER_IP="${SUBNET_BASE}.$((10 + N))"
  NODE_DIR="$DOCKER_DIR/nodes/validator-$N"

  echo ""
  echo "══════════════════════════════════════════════════════════════"
  echo "  Adding validator-$N  ($i/$COUNT)  p2p=$P2P_HOST_PORT  rpc=$RPC_HOST_PORT  ip=$CONTAINER_IP"
  echo "══════════════════════════════════════════════════════════════"

  # ── Step 1: Generate key pair ──────────────────────────────────────────────
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

  NEW_ADDR=$(basename "$keydir")
  echo "$NEW_ADDR" > "$NODE_DIR/data/address"

  docker run --rm -v "$tmpdir:/target" alpine \
    chown -R "$(id -u):$(id -g)" /target 2>/dev/null || true
  rm -rf "$tmpdir" 2>/dev/null || true

  pub=$(tr -d '[:space:]' < "$NODE_DIR/data/key.pub"); pub="${pub#0x}"
  NEW_ENODE="enode://${pub}@${CONTAINER_IP}:${INTERNAL_P2P_PORT}"
  echo "  address : $NEW_ADDR"
  echo "  enode   : $NEW_ENODE"

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
    print(f"  Updated:         {path}")
else:
    print(f"  Already present: {path}")
PY
  done

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

  # ── Step 3: Build static-nodes.json for the new node ──────────────────────
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

  # ── Step 4: Update config and start the new container ─────────────────────
  echo "--- [4/5] Updating docker-compose.override.yml and starting validator-$N ---"
  cp "$DOCKER_DIR/nodes/validator-1/config.toml" "$NODE_DIR/config.toml"
  bash "$SCRIPT_DIR/render-override.sh"

  docker compose up -d "validator-$N"

  echo "  Waiting for validator-$N to come online (RPC port $RPC_HOST_PORT)..."
  for attempt in $(seq 1 30); do
    blk=$(curl -sf --max-time 2 -X POST -H "Content-Type: application/json" \
      --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
      "http://127.0.0.1:$RPC_HOST_PORT" \
      | python3 -c "import sys,json; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null || echo "")
    if [ -n "$blk" ]; then
      echo "  validator-$N is up at block $blk"
      break
    fi
    sleep 2
  done

  # ── Step 5: Vote then wait for votes to be tallied ────────────────────────
  echo "--- [5/5] Voting to add validator-$N (address=$NEW_ADDR) ---"

  VOTE_COUNT=0
  for v in $(seq 1 "$last_n"); do
    port=$((8544 + v))
    resp=$(curl -sf --max-time 3 -X POST -H "Content-Type: application/json" \
      --data "{\"jsonrpc\":\"2.0\",\"method\":\"qbft_proposeValidatorVote\",\"params\":[\"$NEW_ADDR\",true],\"id\":1}" \
      "http://127.0.0.1:$port" 2>/dev/null) || true
    if [ -n "$resp" ]; then
      result=$(echo "$resp" | python3 -c \
        "import sys,json; print(json.load(sys.stdin).get('result','ERROR'))" 2>/dev/null || echo "parse error")
      echo "    validator-$v voted: $result"
      VOTE_COUNT=$((VOTE_COUNT + 1))
    else
      echo "    validator-$v: not running, skipped"
    fi
  done

  echo "  $VOTE_COUNT vote(s) cast. Waiting for blocks to tally them..."

  # Pump an initial batch of transactions so block production starts immediately.
  baseline=$(current_block "$REF_RPC_PORT")
  pump_txns "$REF_RPC_PORT" 8
  wait_for_new_block "$REF_RPC_PORT" "$baseline" 30 || true

  # Poll until the new validator appears in the active set, pumping more
  # transactions each round if the chain stalls again.
  if wait_for_validator_in_set "$NEW_ADDR" "$REF_RPC_PORT" 15; then
    echo ""
    echo "  ✔ validator-$N (${NEW_ADDR:0:12}...) is now in the active set."
    last_n=$N
  else
    echo "" >&2
    echo "  ✘ validator-$N was NOT added within the expected window." >&2
    echo "    Check votes with: make validators" >&2
    echo "    Pending votes: qbft_getPendingVotes on any running node." >&2
    echo "    Aborting further additions to avoid an inconsistent validator count." >&2
    exit 1
  fi

done

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Done — added $COUNT validator(s)."
echo "  Run 'make validators' (or ./scripts/manage.sh validators) to verify."
echo "══════════════════════════════════════════════════════════════"
