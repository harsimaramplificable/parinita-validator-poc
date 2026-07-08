#!/usr/bin/env bash
# TEST 01 — Connectivity: every discovered validator answers JSON-RPC and
# reports the expected chain id. Scales to any number of validators.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "TEST 01 — RPC connectivity & chain id"
require_running
info "Expected chain id: $EXPECTED_CHAIN_ID"

while IFS= read -r n; do
  port=$(rpc_port "$n")
  if rpc_reachable "$port"; then
    cid=$(rpc_chainid "$port")
    if [[ "$cid" == "$EXPECTED_CHAIN_ID" ]]; then
      pass "validator-$n (rpc $port) reachable, chain id $cid"
    else
      fail "validator-$n (rpc $port) chain id mismatch: got '$cid', expected '$EXPECTED_CHAIN_ID'"
    fi
  else
    fail "validator-$n (rpc $port) is not reachable"
  fi
done < <(discover_validators)

test_summary
