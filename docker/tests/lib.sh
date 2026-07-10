#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Shared test library for the Besu QBFT docker suite.
#
# Everything here is DYNAMIC: the validator set is discovered from the nodes/
# directory (same rule as scripts/manage.sh), so the tests scale automatically
# as you add or remove validators — no hardcoded "4 nodes / ports 8545-8548".
#
# Source this from any test script:
#     source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(dirname "$TESTS_DIR")"
cd "$DOCKER_DIR"

# ─── Load network parameters (.env, overridable by .env.local) ────────────────
if [[ -f "$DOCKER_DIR/.env" ]]; then
  set -a; source "$DOCKER_DIR/.env"; [[ -f "$DOCKER_DIR/.env.local" ]] && source "$DOCKER_DIR/.env.local"; set +a
fi
EXPECTED_CHAIN_ID="${CHAIN_ID:-1337}"
BLOCK_PERIOD="${BLOCK_PERIOD_SECONDS:-2}"
# QBFT round-0 timeout. On a round failure (e.g. the round's proposer is offline)
# the timeout DOUBLES each round, so waits that must survive an offline proposer
# have to be sized off this, not just the block period.
REQUEST_TIMEOUT="${REQUEST_TIMEOUT_SECONDS:-16}"

# Prefunded Besu dev accounts (PUBLICLY KNOWN KEYS — lab use only).
SENDER_ADDR="0xfe3b557e8fb62b89f4916b721be55ceb828dbd73"
SENDER_KEY="0x8f2a55949038a9610f50fb23b5883af3b4ecb3c3bb792cbcefbd1542c692be63"
RECIPIENT_ADDR="0x627306090abaB3A6e1400e9345bC60c78a8BEf57"

# ─── Colors (disabled when not a TTY or NO_COLOR set) ─────────────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_CYA=$'\033[36m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_CYA=""; C_BLD=""; C_RST=""
fi

# ─── Pass/fail bookkeeping ────────────────────────────────────────────────────
PASS_COUNT=0
FAIL_COUNT=0

hr()      { printf '%s\n' "────────────────────────────────────────────────────────────────"; }
section() { echo; printf "%s%s== %s ==%s\n" "$C_BLD" "$C_CYA" "$*" "$C_RST"; }
info()    { printf "   %s%s%s\n" "$C_BLU" "$*" "$C_RST"; }
note()    { printf "   %s\n" "$*"; }

pass() { PASS_COUNT=$((PASS_COUNT+1)); printf "   %s✓ PASS%s %s\n" "$C_GRN" "$C_RST" "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT+1)); printf "   %s✗ FAIL%s %s\n" "$C_RED" "$C_RST" "$*"; }
warn() { printf "   %s! %s%s\n" "$C_YEL" "$*" "$C_RST"; }

# assert_eq <expected> <actual> <message>
assert_eq() {
  if [[ "$1" == "$2" ]]; then pass "$3 (=$2)"; else fail "$3 (expected '$1', got '$2')"; fi
}
# assert_ge <a> <b> <message>   → pass when a >= b
assert_ge() {
  if [[ "$1" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ && "$1" -ge "$2" ]]; then
    pass "$3 ($1 >= $2)"; else fail "$3 (got '$1', need >= '$2')"; fi
}

# Print the summary line and return non-zero if anything failed.
test_summary() {
  echo; hr
  if [[ "$FAIL_COUNT" -eq 0 ]]; then
    printf "%s%s RESULT: ALL %d CHECK(S) PASSED %s\n" "$C_BLD" "$C_GRN" "$PASS_COUNT" "$C_RST"
  else
    printf "%s%s RESULT: %d PASSED, %d FAILED %s\n" "$C_BLD" "$C_RED" "$PASS_COUNT" "$FAIL_COUNT" "$C_RST"
  fi
  hr
  [[ "$FAIL_COUNT" -eq 0 ]]
}

# ─── Validator / topology discovery ───────────────────────────────────────────
# Echo the sorted list of validator numbers that have a key on disk.
discover_validators() {
  for d in "$DOCKER_DIR"/nodes/validator-*/; do
    [[ -d "$d" ]] || continue
    n="${d%/}"; n="${n##*/validator-}"
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    [[ -f "$DOCKER_DIR/nodes/validator-$n/data/key" ]] || continue
    echo "$n"
  done | sort -n
}

validator_count() { discover_validators | wc -l | tr -d ' '; }

rpc_port()        { echo $((8544 + $1)); }
container_name()  { echo "besu-validator-$1"; }

# QBFT liveness math (crash-fault / availability):
#   quorum      = ceil(2N/3)   validators must be online to finalise blocks
#   max_faults  = floor(N/3)   validators may be offline and the chain stays live
qbft_quorum()     { echo $(( (2 * $1 + 2) / 3 )); }   # ceil(2N/3)
qbft_max_faults() { echo $(( $1 / 3 )); }             # floor(N/3)

# ─── JSON-RPC helpers (all take a host port) ──────────────────────────────────
_rpc() { # _rpc <port> <method> [params-json]
  local port="$1" method="$2" params="${3:-[]}"
  curl -s --max-time 5 -X POST -H "Content-Type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$params,\"id\":1}" \
    "http://127.0.0.1:$port"
}

_hex_to_int() { python3 -c "import sys,json; d=json.load(sys.stdin); print(int(d['result'],16))" 2>/dev/null; }

rpc_reachable() { # returns 0 if the node answers
  local port="$1"
  [[ -n "$(_rpc "$port" web3_clientVersion | python3 -c "import sys,json;print(json.load(sys.stdin).get('result',''))" 2>/dev/null)" ]]
}

rpc_block()   { _rpc "$1" eth_blockNumber | _hex_to_int || echo ""; }
rpc_peers()   { _rpc "$1" net_peerCount   | _hex_to_int || echo ""; }
rpc_chainid() { _rpc "$1" eth_chainId     | _hex_to_int || echo ""; }

# On-chain QBFT validator addresses at latest block (one per line).
rpc_validator_set() {
  _rpc "$1" qbft_getValidatorsByBlockNumber '["latest"]' \
    | python3 -c "import sys,json; [print(a) for a in json.load(sys.stdin).get('result',[])]" 2>/dev/null
}

# ─── Liveness probing ─────────────────────────────────────────────────────────
# This network runs with emptyblockperiodseconds set very high, so QBFT only
# seals a block when there are transactions. Height therefore does NOT climb on
# its own — real liveness is proven by submitting a tx and seeing it get mined.

# Make sure the python eth libraries are importable (installs web3, which pulls
# in eth_account, on first use). Returns non-zero if it still can't import.
ensure_pyeth() {
  python3 -c "import eth_account" >/dev/null 2>&1 && return 0
  info "Installing python eth libraries (one-time)…"
  pip install web3 --quiet --break-system-packages >/dev/null 2>&1 || pip install web3 --quiet >/dev/null 2>&1 || true
  python3 -c "import eth_account" >/dev/null 2>&1
}

# poke_tx <port> [count] — submit `count` tiny self-transfers (gasPrice 0) to
# force block production. Uses the "pending" nonce so repeated calls are safe.
poke_tx() {
  local port="$1" count="${2:-3}"
  python3 - "$port" "$count" "$SENDER_ADDR" "$SENDER_KEY" "$RECIPIENT_ADDR" "$EXPECTED_CHAIN_ID" <<'PY' 2>/dev/null
import sys, json, urllib.request
from eth_account import Account
port, count, tx_from, pk, tx_to, chain_id = \
    sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], int(sys.argv[6])
url = f"http://127.0.0.1:{port}"
def rpc(method, params):
    req = urllib.request.Request(url,
        data=json.dumps({"jsonrpc":"2.0","method":method,"params":params,"id":1}).encode(),
        headers={"Content-Type":"application/json"})
    try: return json.load(urllib.request.urlopen(req, timeout=5)).get("result")
    except Exception: return None
acct = Account.from_key(pk)
nh = rpc("eth_getTransactionCount", [tx_from, "pending"])
if nh is None: sys.exit(1)
nonce = int(nh, 16); ok = 0
for i in range(count):
    tx = {"nonce": nonce+i, "to": tx_to, "value": 1, "gas": 21000, "gasPrice": 0, "chainId": chain_id}
    signed = acct.sign_transaction(tx)
    raw = getattr(signed, "raw_transaction", None) or getattr(signed, "rawTransaction")
    if rpc("eth_sendRawTransaction", ["0x"+raw.hex()]): ok += 1
sys.exit(0 if ok else 1)
PY
}

# chain_progresses <port> <timeout> [poke_count]
#   Poke the chain, then poll up to <timeout>s for the height to increase,
#   RE-POKING every few seconds (so it still succeeds when a just-restarted node
#   needs a moment to re-peer before pending txs can be mined).
#   Sets globals PROG_FROM / PROG_TO. Returns 0 if it climbed, 1 otherwise.
chain_progresses() {
  local port="$1" timeout="${2:-20}" count="${3:-3}" h0 h i=0 repoke=5
  h0=$(rpc_block "$port"); [[ "$h0" =~ ^[0-9]+$ ]] || h0=0
  PROG_FROM="$h0"; PROG_TO="$h0"
  poke_tx "$port" "$count"
  while (( i < timeout )); do
    h=$(rpc_block "$port")
    if [[ "$h" =~ ^[0-9]+$ ]] && (( h > h0 )); then PROG_TO="$h"; return 0; fi
    sleep 1; i=$((i+1))
    (( i % repoke == 0 )) && poke_tx "$port" "$count"
  done
  [[ "${h:-}" =~ ^[0-9]+$ ]] && PROG_TO="$h"
  return 1
}

# wait_peers <port> <min> [secs] — wait until a node reports >= min peers.
wait_peers() {
  local port="$1" min="$2" secs="${3:-40}" i=0 p
  while (( i < secs )); do
    p=$(rpc_peers "$port"); [[ "$p" =~ ^[0-9]+$ ]] && (( p >= min )) && return 0
    sleep 1; i=$((i+1))
  done
  return 1
}

# ─── Container control (used by the fault-tolerance test) ─────────────────────
node_stop()  { docker stop "$(container_name "$1")" >/dev/null 2>&1; }
node_start() { docker start "$(container_name "$1")" >/dev/null 2>&1; }

# Wait until a node's RPC responds again (or timeout). wait_rpc <port> [secs]
wait_rpc() {
  local port="$1" secs="${2:-40}" i=0
  while (( i < secs )); do rpc_reachable "$port" && return 0; sleep 1; i=$((i+1)); done
  return 1
}

require_running() {
  local n port up=0 total
  total=$(validator_count)
  while IFS= read -r n; do port=$(rpc_port "$n"); rpc_reachable "$port" && up=$((up+1)); done < <(discover_validators)
  if (( up == 0 )); then
    echo "${C_RED}No validators are reachable. Start the network first: make start${C_RST}" >&2
    exit 2
  fi
  info "Discovered $total validator(s); $up reachable via RPC."
}

# wait_all_reachable [secs] — give a freshly started network time to bind RPC on
# EVERY node before asserting. A large validator set (50+) takes far longer for
# all nodes to finish crypto init and bind their RPC listener than a 15-node set
# (the compose healthcheck itself allows a 60s start_period), so a single probe
# right after `make start` races that boot and reports healthy-but-slow nodes as
# unreachable. Polls until every discovered validator answers, or until <secs>
# elapses. Returns 0 if all came up, 1 on timeout — the caller still proceeds so
# a genuinely-dead node surfaces as a per-node failure instead of being hidden.
# Default budget scales with the node count; override with TEST_STARTUP_WAIT.
wait_all_reachable() {
  local n total up i=0 secs
  total=$(validator_count)
  secs="${1:-${TEST_STARTUP_WAIT:-$(( 40 + total * 2 ))}}"
  while (( i < secs )); do
    up=0
    while IFS= read -r n; do rpc_reachable "$(rpc_port "$n")" && up=$((up+1)); done < <(discover_validators)
    if (( up == total )); then
      (( i > 0 )) && info "all $total validator(s) reachable after ${i}s"
      return 0
    fi
    (( i == 0 )) && info "waiting up to ${secs}s for all $total validator(s) to bind RPC ($up up so far)…"
    sleep 2; i=$((i+2))
  done
  warn "startup grace elapsed (${secs}s): $up/$total reachable — proceeding (stragglers will show as failures)"
  return 1
}
