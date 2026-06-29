# Generate the keys and genesis
cd ~/besu-qbft-lab
besu operator generate-blockchain-config \
  --config-file=qbftConfigFile.json \
  --to=networkFiles \
  --private-key-file-name=key
  
  
# Checkpoint
cd ~/besu-qbft-lab

# 1. Your four validator addresses (the key directory names)
echo "=== Validators ===" && ls -1 networkFiles/keys

# 2. The extraData that encodes them into genesis
echo "=== extraData ===" && python3 -c "import json; print(json.load(open('networkFiles/genesis.json'))['extraData'])"
