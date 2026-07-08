#!/usr/bin/env bash
# TEST 04 — Validator set integrity:
#   (a) the on-chain QBFT validator set size matches the number of nodes on disk
#   (b) every reachable node reports the SAME validator set
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "TEST 04 — On-chain validator set"
require_running

total=$(validator_count)
info "Validators on disk: $total"

# (a) size on the observation node
obs=""; while IFS= read -r n; do rpc_reachable "$(rpc_port "$n")" && { obs="$n"; break; }; done < <(discover_validators)
set0="$(rpc_validator_set "$(rpc_port "$obs")" | sort)"
size0=$(printf '%s\n' "$set0" | grep -c . || true)
note "on-chain set reported by validator-$obs:"
printf '%s\n' "$set0" | sed 's/^/     /'
assert_eq "$total" "$size0" "on-chain validator count matches nodes on disk"

# (b) consistency across all reachable nodes
mismatch=0
while IFS= read -r n; do
  port=$(rpc_port "$n"); rpc_reachable "$port" || continue
  seti="$(rpc_validator_set "$port" | sort)"
  [[ "$seti" == "$set0" ]] || { mismatch=$((mismatch+1)); note "validator-$n reports a DIFFERENT set"; }
done < <(discover_validators)
assert_eq "0" "$mismatch" "all reachable nodes report an identical validator set"

test_summary
