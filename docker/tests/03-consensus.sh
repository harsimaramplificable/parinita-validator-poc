#!/usr/bin/env bash
# TEST 03 — Consensus liveness & agreement:
#   (a) the chain finalises a block when poked (blocks CAN be produced)
#   (b) all reachable nodes agree on height (within a small drift tolerance)
#
# NOTE: this network runs with emptyblockperiodseconds very high, so the height
# only advances when transactions arrive — liveness is probed by submitting one.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "TEST 03 — Consensus: block production & agreement"
require_running
ensure_pyeth || { fail "python eth libraries unavailable (needed to probe liveness)"; test_summary; exit $?; }

# Observe from the lowest-numbered reachable validator.
obs=""; while IFS= read -r n; do rpc_reachable "$(rpc_port "$n")" && { obs="$n"; break; }; done < <(discover_validators)
obs_port=$(rpc_port "$obs")

# (a) chain finalises a block when poked
info "validator-$obs height now: $(rpc_block "$obs_port")  (submitting a tx to trigger a block…)"
if chain_progresses "$obs_port" "$(( BLOCK_PERIOD * 5 + 6 ))"; then
  pass "chain produces blocks when poked ($PROG_FROM → $PROG_TO)"
else
  fail "chain did not produce a block after being poked ($PROG_FROM held) — consensus stalled"
fi

# (b) all nodes agree (allow small drift for propagation lag)
sleep "$(( BLOCK_PERIOD + 1 ))"
drift_max="${CONSENSUS_DRIFT:-3}"
declare -a heights=()
while IFS= read -r n; do
  port=$(rpc_port "$n")
  rpc_reachable "$port" || { warn "validator-$n unreachable — skipped"; continue; }
  b=$(rpc_block "$port"); heights+=("$b")
  note "validator-$n (rpc $port): block ${b:-?}"
done < <(discover_validators)

min=""; max=""
for b in "${heights[@]}"; do
  [[ "$b" =~ ^[0-9]+$ ]] || continue
  [[ -z "$min" || "$b" -lt "$min" ]] && min="$b"
  [[ -z "$max" || "$b" -gt "$max" ]] && max="$b"
done
if [[ -n "$min" && -n "$max" ]]; then
  spread=$(( max - min ))
  if (( spread <= drift_max )); then pass "all nodes agree (spread $spread <= $drift_max blocks)"
  else fail "nodes disagree (spread $spread > $drift_max blocks) — possible fork/lag"; fi
else
  fail "could not read block height from any node"
fi

test_summary
