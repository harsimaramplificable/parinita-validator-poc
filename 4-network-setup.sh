cd ~/besu-qbft-lab && cat > setup-network.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# Distribute the generated keys into node-1..node-4 and build the static-nodes full mesh.
# Run from ~/besu-qbft-lab AFTER generate-blockchain-config has produced networkFiles/.

LAB="$HOME/besu-qbft-lab"
cd "$LAB"

P2P_PORTS=(30303 30304 30305 30306)
HOST="127.0.0.1"

# 1. Shared genesis up to the lab root — every node loads this identical file
cp networkFiles/genesis.json "$LAB/genesis.json"

# 2. Collect the 4 validator key dirs, sorted by address for a deterministic node mapping
mapfile -t KEYDIRS < <(printf '%s\n' networkFiles/keys/0x* | sort)
[ "${#KEYDIRS[@]}" -eq 4 ] || { echo "Expected 4 key dirs, found ${#KEYDIRS[@]}" >&2; exit 1; }

# 3. Make node dirs, copy each key pair in, assemble each node's enode URL
declare -a ENODES
echo "Assigning validators to nodes:"
for i in 0 1 2 3; do
  n=$((i+1))
  mkdir -p "node-$n/data"
  cp "${KEYDIRS[$i]}/key"     "node-$n/data/key"
  cp "${KEYDIRS[$i]}/key.pub" "node-$n/data/key.pub"
  pub=$(tr -d '[:space:]' < "${KEYDIRS[$i]}/key.pub"); pub=${pub#0x}
  ENODES[$i]="enode://${pub}@${HOST}:${P2P_PORTS[$i]}"
  echo "  node-$n  <-  $(basename "${KEYDIRS[$i]}")   p2p=${P2P_PORTS[$i]}  rpc=$((8545+i))"
done

# 4. Full-mesh static-nodes.json — each node lists the OTHER three (self excluded)
for i in 0 1 2 3; do
  n=$((i+1)); out="node-$n/data/static-nodes.json"
  echo "[" > "$out"; first=1
  for j in 0 1 2 3; do
    [ "$j" -eq "$i" ] && continue
    [ "$first" -eq 1 ] && first=0 || echo "," >> "$out"
    printf '  "%s"' "${ENODES[$j]}" >> "$out"
  done
  printf '\n]\n' >> "$out"
done

echo
echo "Done. Files created:"
find node-1 node-2 node-3 node-4 -type f | sort
SCRIPT
chmod +x setup-network.sh && ./setup-network.sh

