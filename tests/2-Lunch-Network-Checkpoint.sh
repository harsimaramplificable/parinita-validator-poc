cd ~/besu-qbft-lab

# 1. Are all four nodes up?
echo "=== status ===" && ./besu-net.sh status

# 2. node-1's own enode banner (proves its identity + P2P port)
echo "=== enode ===" && grep -m1 -i "enode://" logs/node-1.log

# 3. Peer count at each node — every node should see the other 3
echo "=== peers ===" && for p in 8545 8546 8547 8548; do
  printf "rpc %s peers: " "$p"
  curl -s -X POST --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' http://127.0.0.1:$p \
    | python3 -c "import sys,json; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null || echo "(no response yet)"
done
