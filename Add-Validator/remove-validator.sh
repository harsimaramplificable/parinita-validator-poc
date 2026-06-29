N="${1:?usage: $0 <node-number>}"
cd ~/besu-qbft-lab
RPC=$((8544 + N))

echo "=== validators BEFORE ===" && curl -s -X POST --data '{"jsonrpc":"2.0","method":"qbft_getValidatorsByBlockNumber","params":["latest"],"id":1}' http://127.0.0.1:8545 | python3 -m json.tool

# Re-derive node-N's address (safe even in a fresh shell)
NODE_ADDR=$(python3 - <<PY
import json, urllib.request
from eth_utils import keccak, to_checksum_address
req = urllib.request.Request("http://127.0.0.1:${RPC}",
    data=json.dumps({"jsonrpc":"2.0","method":"admin_nodeInfo","params":[],"id":1}).encode(),
    headers={"Content-Type":"application/json"})
enode = json.load(urllib.request.urlopen(req))["result"]["enode"]
pub = bytes.fromhex(enode.split("//")[1].split("@")[0])
print(to_checksum_address("0x" + keccak(pub)[-20:].hex()))
PY
)
echo "removing node-$N ($NODE_ADDR)"
./vote-validator.sh "$NODE_ADDR" remove

echo "--- waiting ~20s ---"; sleep 20

echo "=== validators AFTER (node-$N should be gone) ===" && curl -s -X POST --data '{"jsonrpc":"2.0","method":"qbft_getValidatorsByBlockNumber","params":["latest"],"id":1}' http://127.0.0.1:8545 | python3 -m json.tool
echo "=== node-$N still a validator? (expect NO) ===" && curl -s -X POST --data '{"jsonrpc":"2.0","method":"qbft_getValidatorsByBlockNumber","params":["latest"],"id":1}' http://127.0.0.1:8545 | python3 -c "import sys,json; v=[x.lower() for x in json.load(sys.stdin)['result']]; print('YES' if '${NODE_ADDR}'.lower() in v else 'NO')"
echo "=== confirm node-$N stopped proposing (two counts ~10s apart should match) ===" && a=$(grep -c "Produced" logs/node-$N.log || echo 0); sleep 10; b=$(grep -c "Produced" logs/node-$N.log || echo 0); echo "Produced: $a then $b -> $([ "$a" = "$b" ] && echo 'stable — no longer a validator' || echo 'still climbing — removal not applied yet, wait and recheck')"
