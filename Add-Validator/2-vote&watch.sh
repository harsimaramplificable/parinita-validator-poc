N="${1:?usage: $0 <node-number>}"
cd ~/besu-qbft-lab
RPC=$((8544 + N))

# 1. Derive node-N's validator address from its live enode (no log dependency)
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
echo "node-$N validator address: $NODE_ADDR"
[ -n "$NODE_ADDR" ] || { echo "ERROR: empty — is node-$N up on $RPC? check ./besu-net.sh status" >&2; exit 1; }

# 2. Cast the add vote on a majority of current validators
./vote-validator.sh "$NODE_ADDR" add

# 3. Let proposer turns embed the votes
echo "--- waiting ~20s ---"; sleep 20

# 4. Verify the set grew and node-N is now proposing
echo "=== validators AFTER (node-$N should now be in the set) ==="
curl -s -X POST --data '{"jsonrpc":"2.0","method":"qbft_getValidatorsByBlockNumber","params":["latest"],"id":1}' http://127.0.0.1:8545 | python3 -m json.tool
echo "=== node-$N in the set? ==="
curl -s -X POST --data '{"jsonrpc":"2.0","method":"qbft_getValidatorsByBlockNumber","params":["latest"],"id":1}' http://127.0.0.1:8545 | python3 -c "import sys,json; v=[x.lower() for x in json.load(sys.stdin)['result']]; print('YES' if '${NODE_ADDR}'.lower() in v else 'NOT YET')"
echo "=== node-$N Produced count (was 0; expect > 0 after being voted in) ==="
echo "Produced lines: $(grep -c 'Produced' logs/node-$N.log || echo 0)"
