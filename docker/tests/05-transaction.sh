#!/usr/bin/env bash
# TEST 05 — Transaction lifecycle: sign locally, submit via eth_sendRawTransaction,
# wait for the receipt, and confirm balances moved. gasPrice=0 (min-gas-price=0).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "TEST 05 — Value transfer end-to-end"
require_running

# Submit against the lowest-numbered reachable validator.
obs=""; while IFS= read -r n; do rpc_reachable "$(rpc_port "$n")" && { obs="$n"; break; }; done < <(discover_validators)
RPC_URL="http://127.0.0.1:$(rpc_port "$obs")"
info "Submitting via validator-$obs ($RPC_URL)"

if ! python3 -c "import web3" >/dev/null 2>&1; then
  ensure_pyeth >/dev/null 2>&1 || true
  python3 -c "import web3" >/dev/null 2>&1 \
    || { fail "web3 not installed and auto-install failed"; test_summary; exit $?; }
fi

RPC_URL="$RPC_URL" SENDER="$SENDER_ADDR" KEY="$SENDER_KEY" RECIPIENT="$RECIPIENT_ADDR" \
python3 - <<'PY'
import os, sys
from web3 import Web3

w3 = Web3(Web3.HTTPProvider(os.environ["RPC_URL"]))
if not w3.is_connected():
    print("   \033[31m✗ FAIL\033[0m cannot reach RPC"); sys.exit(1)

sender    = Web3.to_checksum_address(os.environ["SENDER"])
recipient = Web3.to_checksum_address(os.environ["RECIPIENT"])
key       = os.environ["KEY"]
amount    = w3.to_wei(1, "ether")

def eth(wei): return str(w3.from_wei(wei, "ether"))

sb0, rb0 = w3.eth.get_balance(sender), w3.eth.get_balance(recipient)
print(f"   chainId {w3.eth.chain_id}, height {w3.eth.block_number}")
print(f"   BEFORE  sender {eth(sb0)}  recipient {eth(rb0)}")

tx = {"to": recipient, "value": amount, "gas": 21000, "gasPrice": 0,
      "nonce": w3.eth.get_transaction_count(sender), "chainId": w3.eth.chain_id}
signed = w3.eth.account.sign_transaction(tx, key)
raw = getattr(signed, "raw_transaction", None) or getattr(signed, "rawTransaction")
txh = w3.eth.send_raw_transaction(raw)
print(f"   submitted {txh.hex()} — waiting for receipt…")
rcpt = w3.eth.wait_for_transaction_receipt(txh, timeout=60)

sb1, rb1 = w3.eth.get_balance(sender), w3.eth.get_balance(recipient)
print(f"   AFTER   sender {eth(sb1)}  recipient {eth(rb1)}")

ok = rcpt.status == 1 and (rb1 - rb0) == amount
if ok:
    print(f"   \033[32m✓ PASS\033[0m tx mined in block {rcpt.blockNumber}, recipient +{eth(rb1-rb0)} ETH")
    sys.exit(0)
else:
    print(f"   \033[31m✗ FAIL\033[0m status={rcpt.status} delta={eth(rb1-rb0)}")
    sys.exit(1)
PY
rc=$?
if [[ $rc -eq 0 ]]; then PASS_COUNT=$((PASS_COUNT+1)); else FAIL_COUNT=$((FAIL_COUNT+1)); fi

test_summary
