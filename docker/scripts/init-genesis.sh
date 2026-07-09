#!/usr/bin/env bash
# Initialise an N-validator QBFT chain with ALL validators baked into genesis.
#
# Unlike `make init` + `make add-validator`, this uses NO dynamic voting: every
# validator is a member of the set from block 0. That avoids the reconfiguration
# churn (one-at-a-time votes, proposer-rotation waits, round-change storms) that
# stalls dynamic adds past ~30 validators — see notes in the project memory.
#
# Usage:  bash scripts/init-genesis.sh [COUNT]     (default 50)
#
# This regenerates genesis.json and ALL validator keys, and drops any previous
# chain's containers + volumes (the new genesis is incompatible with old data).
# It does NOT touch the 4-validator `make init` / `make start` flow — run that
# instead if you want the small chain.
#
# After this completes:  make start
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(dirname "$SCRIPT_DIR")"
cd "$DOCKER_DIR"

set -a; source .env; [[ -f .env.local ]] && source .env.local; set +a

COUNT="${1:-50}"
[[ "$COUNT" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: COUNT must be a positive integer" >&2; exit 1; }

SUBNET_BASE="172.16.240"
INTERNAL_P2P_PORT=30303
NETWORK_FILES="$DOCKER_DIR/config/network-files"
GENESIS_OUT="$DOCKER_DIR/config/genesis.json"

echo "════════════════════════════════════════════════════════════════"
echo "  Initialising a ${COUNT}-validator GENESIS QBFT chain"
echo "════════════════════════════════════════════════════════════════"

# Container IP is ${SUBNET_BASE}.(10+N); keep it inside the /24.
if [ "$((10 + COUNT))" -ge 255 ]; then
  echo "ERROR: COUNT=$COUNT too large for subnet ${SUBNET_BASE}.0/24 (max ~244)." >&2
  exit 1
fi

# ── Preflight: will COUNT nodes actually fit in this host's RAM? ──────────────
# Each Besu JVM's real RSS is roughly heap + 300-500 MB of off-heap. Running
# more nodes than RAM allows does not fail cleanly — the host swap-thrashes,
# Besu never finishes booting (RPC never binds), and the machine can lock up.
# Reserve headroom for the OS, desktop, docker daemon, and monitoring stack.
OS_RESERVE_MB=3072
to_mb() {  # accepts 768m / 1536M / 1g / 2G / plain MB
  local v="${1,,}"
  case "$v" in
    *g) echo $(( ${v%g} * 1024 )) ;;
    *m) echo "${v%m}" ;;
    *)  echo "$v" ;;
  esac
}
MEM_LIMIT_MB="$(to_mb "${BESU_MEM_LIMIT:-768m}")"
REQUIRED_MB=$(( COUNT * MEM_LIMIT_MB ))
TOTAL_MB=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024 ))
AVAIL_MB=$(( $(awk '/^MemAvailable:/{print $2}' /proc/meminfo) / 1024 ))
BUDGET_MB=$(( TOTAL_MB - OS_RESERVE_MB ))

echo "--- Preflight: memory budget ---"
echo "  host total      : ${TOTAL_MB} MB   (available right now: ${AVAIL_MB} MB)"
echo "  per-node limit  : ${MEM_LIMIT_MB} MB  (heap ${BESU_HEAP:-384m})"
echo "  ${COUNT} nodes need  : ${REQUIRED_MB} MB   (budget ${BUDGET_MB} MB = total - ${OS_RESERVE_MB} MB OS reserve)"

if [ "$REQUIRED_MB" -gt "$BUDGET_MB" ]; then
  MAX_FIT=$(( BUDGET_MB / MEM_LIMIT_MB ))
  echo "" >&2
  echo "ERROR: ${COUNT} nodes x ${MEM_LIMIT_MB} MB = ${REQUIRED_MB} MB exceeds the ${BUDGET_MB} MB budget." >&2
  echo "       This host fits about ${MAX_FIT} node(s) at the current BESU_MEM_LIMIT." >&2
  echo "" >&2
  echo "  Options:" >&2
  echo "    - Lower COUNT:            make init-genesis COUNT=${MAX_FIT}" >&2
  echo "    - Shrink nodes in .env:   BESU_HEAP / BESU_MEM_LIMIT" >&2
  echo "    - Free RAM:               make monitoring-stop" >&2
  echo "    - Use more hosts:         see multi-vm/" >&2
  echo "    - Override (DANGEROUS, can hard-lock the machine): ALLOW_OVERCOMMIT=1 make init-genesis COUNT=${COUNT}" >&2
  [ "${ALLOW_OVERCOMMIT:-0}" = "1" ] || exit 1
  echo "  ALLOW_OVERCOMMIT=1 set — proceeding anyway." >&2
elif [ "$REQUIRED_MB" -gt "$AVAIL_MB" ]; then
  echo "  WARNING: fits total RAM but exceeds what is free right now (${AVAIL_MB} MB)."
  echo "           Close apps or run 'make monitoring-stop' before 'make start'."
fi

# Node config.toml is written from this template (self-contained — does not
# depend on any checked-in nodes/validator-*/config.toml being present). Every
# node gets an identical copy; it carries the 50-node QBFT tuning.
REF_CONFIG="$(mktemp)"
cat > "$REF_CONFIG" <<'TOML'
# ─── Paths ────────────────────────────────────────────────────────────────────
data-path="/opt/besu/data"
genesis-file="/opt/besu/genesis.json"
node-private-key-file="/opt/besu/keys/key"

# ─── P2P networking ───────────────────────────────────────────────────────────
# p2p-host is intentionally omitted here so Besu auto-detects the container's IP.
# For multi-VM deployments, pass --p2p-host=<external-ip> as a CLI flag in the
# compose command (see multi-vm/single-node-compose.yml).
p2p-port=30303
p2p-enabled=true

# ─── JSON-RPC HTTP ────────────────────────────────────────────────────────────
rpc-http-enabled=true
rpc-http-host="0.0.0.0"
rpc-http-port=8545
rpc-http-api=["ETH","NET","QBFT","WEB3","ADMIN","TXPOOL"]
rpc-http-cors-origins=["*"]
host-allowlist=["*"]

# ─── Metrics (Prometheus) ─────────────────────────────────────────────────────
metrics-enabled=true
metrics-host="0.0.0.0"
metrics-port=9545

# ─── P2P peering (MUST scale with validator count) ────────────────────────────
# A 50-validator QBFT mesh needs ~49 peer connections per node. Besu's default
# max-peers=25 silently caps connections and starves consensus once the network
# grows past ~25-29 nodes (the exact point block production stalled before).
# Peers are pinned via static-nodes.json, so discovery is disabled: leaving it on
# caused the vert.x discovery thread (RecursivePeerRefreshState) to block for
# seconds under load, which in turn stalled consensus message processing.
max-peers=128
discovery-enabled=false
remote-connections-limit-enabled=false

# ─── Consensus / performance ──────────────────────────────────────────────────
# ─── Sync: small network, do not wait for many peers before mining ───────────
sync-min-peers=1
min-gas-price=0
profile="ENTERPRISE"
logging="INFO"
TOML
trap 'rm -f "$REF_CONFIG" "${TMP_CFG:-}"' EXIT

# ── Tear down any previous chain — old volumes carry an incompatible genesis ──
echo "--- [1/5] Removing any previous chain (containers + volumes) ---"
docker compose down -v 2>/dev/null || true

# Remove stale extra-validator dirs beyond COUNT so render-override.sh does not
# resurrect nodes that are not part of this genesis.
for d in nodes/validator-*/; do
  [ -d "$d" ] || continue
  n="${d%/}"; n="${n##*/validator-}"
  [[ "$n" =~ ^[0-9]+$ ]] || continue
  if [ "$n" -gt "$COUNT" ]; then
    echo "  removing stale $d (beyond COUNT=$COUNT)"
    rm -rf "$d"
  fi
done

# ── Build a qbft-config with the requested validator count ────────────────────
# Templated from the existing config/qbft-config.json so genesis params stay in
# sync (chainId, block period, timeouts, emptyblockperiod, dev-account alloc).
echo "--- [2/5] Building genesis config for ${COUNT} validators ---"
TMP_CFG="$(mktemp)"
python3 - "$DOCKER_DIR/config/qbft-config.json" "$COUNT" "$TMP_CFG" <<'PY'
import json, sys
src, count, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
cfg = json.load(open(src))
cfg["blockchain"]["nodes"]["count"] = count
json.dump(cfg, open(out, "w"), indent=2)
print(f"  count = {count}")
PY

# ── Regenerate genesis + keys via an ephemeral Besu container ─────────────────
echo "--- [3/5] Generating ${COUNT} validator keys + genesis.json ---"
docker run --rm -v "$DOCKER_DIR/config:/target" alpine \
  sh -c "rm -rf /target/network-files /target/genesis.json" 2>/dev/null || true
rm -f "$GENESIS_OUT"

docker pull "hyperledger/besu:${BESU_VERSION}" >/dev/null

keygen_out=$(docker run --rm \
  -v "$TMP_CFG:/config/qbft-config.json:ro" \
  -v "$DOCKER_DIR/config:/output" \
  "hyperledger/besu:${BESU_VERSION}" \
  operator generate-blockchain-config \
    --config-file=/config/qbft-config.json \
    --to=/output/network-files \
    --private-key-file-name=key 2>&1) || true
echo "$keygen_out" | grep -v "Output directory already exists" | grep -v "^$" || true

if [ ! -f "$NETWORK_FILES/genesis.json" ] || [ ! -d "$NETWORK_FILES/keys" ]; then
  echo "ERROR: key generation failed." >&2
  echo "$keygen_out" >&2
  exit 1
fi

# Fix ownership without sudo (Besu writes as root inside the container).
docker run --rm -v "$DOCKER_DIR/config:/target" alpine \
  chown -R "$(id -u):$(id -g)" /target/network-files 2>/dev/null || true
cp "$NETWORK_FILES/genesis.json" "$GENESIS_OUT"

# ── Distribute keys + static-nodes.json + config.toml to every node ───────────
echo "--- [4/5] Laying down keys, static-nodes.json, config.toml for ${COUNT} nodes ---"
python3 - "$DOCKER_DIR" "$COUNT" "$SUBNET_BASE" "$INTERNAL_P2P_PORT" "$REF_CONFIG" <<'PY'
import json, os, glob, sys, shutil
docker_dir, count, subnet, p2p, ref_cfg = (
    sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), sys.argv[5])

keydirs = sorted(glob.glob(os.path.join(docker_dir, "config", "network-files", "keys", "0x*")))
if len(keydirs) != count:
    sys.exit(f"ERROR: expected {count} key dirs, found {len(keydirs)}")

# Precompute every node's enode (IP = subnet.(10+index), index is 1-based).
nodes = []
for i, kd in enumerate(keydirs, start=1):
    pub = open(os.path.join(kd, "key.pub")).read().strip()
    pub = pub[2:] if pub.startswith("0x") else pub
    ip = f"{subnet}.{10 + i}"
    nodes.append((i, kd, pub, f"enode://{pub}@{ip}:{p2p}"))

for i, kd, _, _ in nodes:
    ndir = os.path.join(docker_dir, "nodes", f"validator-{i}")
    ddir = os.path.join(ndir, "data")
    os.makedirs(ddir, exist_ok=True)
    shutil.copy(os.path.join(kd, "key"),     os.path.join(ddir, "key"))
    shutil.copy(os.path.join(kd, "key.pub"), os.path.join(ddir, "key.pub"))
    os.chmod(os.path.join(ddir, "key"), 0o600)
    with open(os.path.join(ddir, "address"), "w") as f:
        f.write(os.path.basename(kd) + "\n")

    # Every node uses the same tuned config.toml (validator-1's is the reference).
    dst_cfg = os.path.join(ndir, "config.toml")
    if os.path.abspath(dst_cfg) != os.path.abspath(ref_cfg):
        shutil.copy(ref_cfg, dst_cfg)

    # Full-mesh static-nodes.json (all peers except self).
    peers = [enode for (j, _, _, enode) in nodes if j != i]
    with open(os.path.join(ddir, "static-nodes.json"), "w") as f:
        json.dump(peers, f, indent=2)

print(f"  laid down validator-1 … validator-{count}  ({count - 1} static peers each)")
PY

# ── Render override so validators 5..COUNT get compose services ───────────────
echo "--- [5/5] Rendering docker-compose.override.yml (validators 5..${COUNT}) ---"
bash "$SCRIPT_DIR/render-override.sh"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Ready: ${COUNT}-validator genesis chain."
echo ""
echo "  Launch all ${COUNT} validators:   make start"
echo "  Watch the set:                   make validators"
echo ""
echo "  NOTE: emptyblockperiodseconds is high (matching qbft-config.json),"
echo "  so blocks are produced on transactions. Run 'make test' or send a tx"
echo "  to see the block number advance."
echo "════════════════════════════════════════════════════════════════"
