N="${1:?usage: $0 <node-number>}"
cd ~/besu-qbft-lab
RPC=$((8544 + N))

./add-fullnode.sh "$N"
./besu-net.sh start "$N"
echo "--- waiting 15s for boot + sync ---" && sleep 15

echo "=== node-$N peer count (expect connected to all validators) ==="
curl -s -X POST --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' "http://127.0.0.1:$RPC" \
  | python3 -c "import sys,json; print(int(json.load(sys.stdin)['result'],16))"

echo "=== heights: node-1 vs node-$N (expect ~equal — node-$N has synced) ==="
for p in 8545 $RPC; do printf "rpc %s: " "$p"
  curl -s -X POST --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' "http://127.0.0.1:$p" \
    | python3 -c "import sys,json; print('block', int(json.load(sys.stdin)['result'],16))"; done

echo "=== validator set as seen BY node-$N (node-$N should be absent — not yet a validator) ==="
curl -s -X POST --data '{"jsonrpc":"2.0","method":"qbft_getValidatorsByBlockNumber","params":["latest"],"id":1}' "http://127.0.0.1:$RPC" \
  | python3 -m json.tool

echo "=== node-$N produces nothing, imports everything (the consensus proof) ==="
echo "Produced lines: $(grep -c 'Produced' logs/node-$N.log || echo 0)"
echo "Imported lines: $(grep -c 'Imported' logs/node-$N.log || echo 0)"
