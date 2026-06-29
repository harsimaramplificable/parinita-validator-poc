cd ~/besu-qbft-lab

# 1. Derive node-5's validator address from its live enode (no log dependency)
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
echo "node-5 validator address: $NODE5"
[ -n "$NODE5" ] || echo "ERROR: empty — is node-5 up on 8549? check ./besu-net.sh status"

# 2. Cast the add vote on a majority of current validators
./vote-validator.sh "$NODE5" add

# 3. Let proposer turns embed the votes
echo "--- waiting ~20s ---"; sleep 20

# 4. Verify the set grew to 5 and node-5 is now proposing
echo "=== validators AFTER (expect 5, incl node-5) ==="
curl -s -X POST --data '{"jsonrpc":"2.0","method":"qbft_getValidatorsByBlockNumber","params":["latest"],"id":1}' http://127.0.0.1:8545 | python3 -m json.tool
echo "=== node-5 in the set? ===" && curl -s -X POST --data '{"jsonrpc":"2.0","method":"qbft_getValidatorsByBlockNumber","params":["latest"],"id":1}' http://127.0.0.1:8545 | python3 -c "import sys,json; v=[x.lower() for x in json.load(sys.stdin)['result']]; print('YES' if '$NODE5'.lower() in v else 'NOT YET')"
echo "=== node-5 Produced count (was 0; expect > 0 now) ===" && grep -c "Produced" logs/node-5.log
