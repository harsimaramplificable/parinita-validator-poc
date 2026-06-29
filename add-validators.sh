#!/usr/bin/env bash
# Orchestrate adding COUNT validators to an existing besu-qbft-lab network.
# Usage: ./add-validators.sh <count>
#   e.g. ./add-validators.sh 1    # add one more validator
#        ./add-validators.sh 10   # add ten validators in sequence
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB="$HOME/besu-qbft-lab"

COUNT="${1:?usage: $0 <count>  (number of validators to add, e.g. 1 or 10)}"
[[ "$COUNT" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: count must be a positive integer" >&2; exit 1; }

# One-time setup: install besu-net.sh and add-fullnode.sh into the lab
if [ ! -f "$LAB/besu-net.sh" ] || [ ! -f "$LAB/add-fullnode.sh" ]; then
  echo "--- [setup] Installing lab scripts (besu-net.sh, add-fullnode.sh) ---"
  bash "$SCRIPT_DIR/add-non-validator-node/1-update-node-setup.sh"
fi

# One-time setup: install vote-validator.sh into the lab
if [ ! -f "$LAB/vote-validator.sh" ]; then
  echo "--- [setup] Installing vote-validator.sh ---"
  bash "$SCRIPT_DIR/Add-Validator/1-vote-validator.sh"
fi

# Determine the next available node number from existing node-* directories
LAST_N=0
for d in "$LAB"/node-*/; do
  [ -d "$d" ] || continue
  n="${d%/}"; n="${n##*/node-}"
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt "$LAST_N" ] && LAST_N="$n"
done
NEXT_N=$((LAST_N + 1))

echo ""
echo "============================================================"
echo "  Adding $COUNT validator(s): node-$NEXT_N through node-$((NEXT_N + COUNT - 1))"
echo "============================================================"

for i in $(seq 1 "$COUNT"); do
  N=$((NEXT_N + i - 1))
  P2P=$((30302 + N))
  RPC=$((8544  + N))

  echo ""
  echo "============================================================"
  echo "  Validator $i / $COUNT  —  node-$N  (p2p=$P2P  rpc=$RPC)"
  echo "============================================================"

  echo ""
  echo "--- [1/2] Provision and launch node-$N as a non-validator ---"
  bash "$SCRIPT_DIR/add-non-validator-node/2-launch-network.sh" "$N"

  echo ""
  echo "--- [2/2] Vote node-$N into the validator set ---"
  bash "$SCRIPT_DIR/Add-Validator/2-vote&watch.sh" "$N"

  echo ""
  echo "  node-$N is now a validator."
done

echo ""
echo "============================================================"
echo "  Done — added $COUNT validator(s)."
echo "  Current network status:"
bash "$LAB/besu-net.sh" status
echo "============================================================"
