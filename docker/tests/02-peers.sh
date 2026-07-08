#!/usr/bin/env bash
# TEST 02 — Peering: in a fully-meshed QBFT network every node should see
# (N-1) peers. Expected count is derived from the discovered validator set.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "TEST 02 — Peer connectivity (full mesh)"
require_running

total=$(validator_count)
expected=$(( total - 1 ))
info "Validators discovered: $total  →  each node should see $expected peer(s)"

while IFS= read -r n; do
  port=$(rpc_port "$n")
  if ! rpc_reachable "$port"; then warn "validator-$n (rpc $port) unreachable — skipped"; continue; fi
  peers=$(rpc_peers "$port")
  assert_ge "${peers:-0}" "$expected" "validator-$n peer count"
done < <(discover_validators)

test_summary
