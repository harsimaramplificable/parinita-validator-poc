cd ~/besu-qbft-lab
./add-fullnode.sh 5          # wire the non-validator
./besu-net.sh start 5        # start it (Besu mints its key on first boot)
echo "--- waiting 15s for boot + sync ---" && sleep 15

echo "=== node-5 peer count (expect 4 — connected to all validators) ==="
curl -s -X POST --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' http://127.0.0.1:8549 \
  | python3 -c "import sys,json; print(int(json.load(sys.stdin)['result'],16))"

echo "=== heights: node-1 vs node-5 (expect ~equal — node-5 has synced) ==="
for p in 8545 8549; do printf "rpc %s: " "$p"
  curl -s -X POST --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://127.0.0.1:$p \
    | python3 -c "import sys,json; print('block', int(json.load(sys.stdin)['result'],16))"; done

echo "=== validator set as seen BY node-5 (expect the original 4, node-5 absent) ==="
curl -s -X POST --data '{"jsonrpc":"2.0","method":"qbft_getValidatorsByBlockNumber","params":["latest"],"id":1}' http://127.0.0.1:8549 \
  | python3 -m json.tool

echo "=== node-5 produces nothing, imports everything (the consensus proof) ==="
printf "Produced lines: " && grep -c "Produced" logs/node-5.log
printf "Imported lines: " && grep -c "Imported" logs/node-5.log
