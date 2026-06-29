cd ~/besu-qbft-lab

echo "=== validators BEFORE (expect 5) ===" && curl -s -X POST --data '{"jsonrpc":"2.0","method":"qbft_getValidatorsByBlockNumber","params":["latest"],"id":1}' http://127.0.0.1:8545 | python3 -m json.tool

# re-derive node-5's address (safe even in a fresh shell)
NODE5=$(python3 - <<'PY'
import json, urllib.request
from eth_utils import keccak, to_checksum_address
req = urllib.request.Request("http://127.0.0.1:8549",
    data=json.dumps({"jsonrpc":"2.0","method":"admin_nodeInfo","params":[],"id":1}).encode(),
    headers={"Content-Type":"application/json"})
enode = json.load(urllib.request.urlopen(req))["result"]["enode"]
pub = bytes.fromhex(enode.split("//")[1].split("@")[0])
print(to_checksum_address("0x" + keccak(pub)[-20:].hex()))
PY
)
echo "removing $NODE5"
./vote-validator.sh "$NODE5" remove

echo "--- waiting ~20s ---"; sleep 20

echo "=== validators AFTER (expect 4, node-5 gone) ===" && curl -s -X POST --data '{"jsonrpc":"2.0","method":"qbft_getValidatorsByBlockNumber","params":["latest"],"id":1}' http://127.0.0.1:8545 | python3 -m json.tool
echo "=== node-5 still a validator? (expect NO) ===" && curl -s -X POST --data '{"jsonrpc":"2.0","method":"qbft_getValidatorsByBlockNumber","params":["latest"],"id":1}' http://127.0.0.1:8545 | python3 -c "import sys,json; v=[x.lower() for x in json.load(sys.stdin)['result']]; print('YES' if '$NODE5'.lower() in v else 'NO')"
echo "=== confirm node-5 stopped proposing (two counts ~10s apart should match) ===" && a=$(grep -c "Produced" logs/node-5.log); sleep 10; b=$(grep -c "Produced" logs/node-5.log); echo "Produced: $a then $b -> $([ "$a" = "$b" ] && echo 'stable — no longer a validator' || echo 'still climbing — removal not applied yet, wait and recheck')"
