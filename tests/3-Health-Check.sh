cd ~/besu-qbft-lab
echo "================================================================"
echo "=== 1. Confirm the block number is climbing ===" && for i in 1 2 3; do
  curl -s -X POST --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://127.0.0.1:8545 \
    | python3 -c "import sys,json; print('block', int(json.load(sys.stdin)['result'],16))"; sleep 3; done
echo "================================================================"
echo "=== 2. Confirm all nodes agree ===" && for p in 8545 8546 8547 8548; do
  printf "rpc %s: " "$p"
  curl -s -X POST --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://127.0.0.1:$p \
    | python3 -c "import sys,json; print('block', int(json.load(sys.stdin)['result'],16))"
done
echo "================================================================"
echo "=== 3. List the validators from the chain itself ===" && curl -s -X POST --data '{"jsonrpc":"2.0","method":"qbft_getValidatorsByBlockNumber","params":["latest"],"id":1}' http://127.0.0.1:8545 | python3 -m json.tool
echo "================================================================"
echo "=== 4. Recent blocks (node-1 log) ===" && grep -iE "Imported|Produced" logs/node-1.log | tail -n 5
