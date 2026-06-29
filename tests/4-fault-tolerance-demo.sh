cd ~/besu-qbft-lab

sample() { # timestamped block height from node-1, which stays up the whole demo
  local h
  h=$(curl -s -X POST --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://127.0.0.1:8545 \
      | python3 -c "import sys,json; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null)
  echo "  $(date +%H:%M:%S)  height=${h:-NO_RESPONSE}"
}

echo "### PHASE 0 — baseline: 4/4 validators, quorum met (expect climbing) ###"
sample; sleep 4; sample

echo "### PHASE 1 — kill node-4: 3/4 validators, 3 >= quorum 3 (expect STILL climbing) ###"
./besu-net.sh stop 4
sleep 8; sample; sleep 4; sample

echo "### PHASE 2 — kill node-3: 2/4 validators, 2 < quorum 3 (expect FROZEN) ###"
./besu-net.sh stop 3
sleep 12; sample; sleep 6; sample
echo "  -- why frozen: round-change churn on surviving node-1 (round number climbs, no new blocks) --"
grep -iE "RoundChange|round summary|Round:" logs/node-1.log | tail -n 5

echo "### PHASE 3 — restart node-3: back to 3/4, quorum restored (expect RESUME from frozen height) ###"
./besu-net.sh start 3
sleep 12; sample; sleep 4; sample

echo "### PHASE 4 — restart node-4: full health ###"
./besu-net.sh start 4
sleep 6; ./besu-net.sh status
