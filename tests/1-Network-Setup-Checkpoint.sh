cd ~/besu-qbft-lab

# 1. The full file structure (should be 12 files)
echo "=== structure ===" && find node-1 node-2 node-3 node-4 -type f | sort

# 2. One node's peer list — should list the OTHER three nodes
echo "=== node-1 static-nodes.json ===" && cat node-1/data/static-nodes.json

# 3. Confirm the root genesis matches the generated one
echo "=== genesis check ===" && diff -q genesis.json networkFiles/genesis.json && echo "genesis matches"
