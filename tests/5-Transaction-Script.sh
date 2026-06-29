pip install web3 --break-system-packages

cd ~/besu-qbft-lab && cat > send-tx.py <<'PY'
#!/usr/bin/env python3
"""Send 1 ETH between two prefunded dev accounts on the local QBFT chain.
Besu does not hold private keys, so we sign locally and submit via
eth_sendRawTransaction. gasPrice=0 (nodes run --min-gas-price=0)."""
from web3 import Web3

RPC        = "http://127.0.0.1:8545"
SENDER     = Web3.to_checksum_address("0xfe3b557e8fb62b89f4916b721be55ceb828dbd73")
SENDER_PK  = "0x8f2a55949038a9610f50fb23b5883af3b4ecb3c3bb792cbcefbd1542c692be63"
RECIPIENT  = Web3.to_checksum_address("0x627306090abaB3A6e1400e9345bC60c78a8BEf57")
AMOUNT_ETH = 1

w3 = Web3(Web3.HTTPProvider(RPC))
if not w3.is_connected():
    raise SystemExit(f"Cannot reach Besu RPC at {RPC} — is the network up?")

def eth(wei): return ("-" if wei<0 else "") + str(w3.from_wei(abs(wei), "ether"))

print(f"chainId {w3.eth.chain_id}, latest block {w3.eth.block_number}")
sb0, rb0 = w3.eth.get_balance(SENDER), w3.eth.get_balance(RECIPIENT)
print(f"BEFORE   sender {eth(sb0)} ETH   recipient {eth(rb0)} ETH")

tx = {
    "to":       RECIPIENT,
    "value":    w3.to_wei(AMOUNT_ETH, "ether"),
    "gas":      21000,
    "gasPrice": 0,
    "nonce":    w3.eth.get_transaction_count(SENDER),
    "chainId":  w3.eth.chain_id,
}
signed = w3.eth.account.sign_transaction(tx, SENDER_PK)
raw = getattr(signed, "raw_transaction", None) or getattr(signed, "rawTransaction")
txh = w3.eth.send_raw_transaction(raw)
print(f"submitted {txh.hex()} — waiting to be mined...")
rcpt = w3.eth.wait_for_transaction_receipt(txh, timeout=60)
print(f"mined in block {rcpt.blockNumber}, status {rcpt.status} (1 = success)")

sb1, rb1 = w3.eth.get_balance(SENDER), w3.eth.get_balance(RECIPIENT)
print(f"AFTER    sender {eth(sb1)} ETH   recipient {eth(rb1)} ETH")
print(f"DELTA    sender {eth(sb1 - sb0)} ETH   recipient +{eth(rb1 - rb0)} ETH")
PY
python3 send-tx.py
