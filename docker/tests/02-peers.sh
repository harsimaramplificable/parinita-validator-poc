#!/usr/bin/env bash
# TEST 02 — Peering: in a fully-meshed QBFT network every node should see
# (N-1) peers. Expected count is derived from the discovered validator set.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "TEST 02 — Peer connectivity (full mesh)"
require_running
wait_all_reachable   # every node must be up before the mesh can be complete

total=$(validator_count)
expected=$(( total - 1 ))
# The mesh keeps forming for a while after the last node binds RPC — a 50-node
# full mesh is ~2450 connections. Give each node this long to reach the expected
# peer count before failing; wait_peers returns the instant it's met, so once the
# mesh is up the remaining nodes cost nothing. Override with PEER_SETTLE_WAIT.
PEER_WAIT="${PEER_SETTLE_WAIT:-$(( 30 + total ))}"
info "Validators discovered: $total  →  each node should see $expected peer(s)"

while IFS= read -r n; do
  port=$(rpc_port "$n")
  if ! rpc_reachable "$port"; then warn "validator-$n (rpc $port) unreachable — skipped"; continue; fi
  wait_peers "$port" "$expected" "$PEER_WAIT"   # tolerate mesh-formation lag
  peers=$(rpc_peers "$port")
  assert_ge "${peers:-0}" "$expected" "validator-$n peer count"
done < <(discover_validators)

test_summary
