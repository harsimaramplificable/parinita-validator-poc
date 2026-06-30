#!/usr/bin/env bash
# Generate QBFT validator keys and genesis.json using an ephemeral Besu container.
# Run once from the docker/ directory before starting the network.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(dirname "$SCRIPT_DIR")"

set -a; source "$DOCKER_DIR/.env"; set +a

NETWORK_FILES="$DOCKER_DIR/config/network-files"
GENESIS_OUT="$DOCKER_DIR/config/genesis.json"

# Guard: genesis already in place
if [ -f "$GENESIS_OUT" ]; then
  echo "genesis.json already exists — delete config/genesis.json to regenerate."
  exit 0
fi

# Guard: keys present but genesis lost — restore from network-files
if [ -f "$NETWORK_FILES/genesis.json" ] && [ -d "$NETWORK_FILES/keys" ]; then
  echo "Keys already present in config/network-files — restoring genesis.json only."
  cp "$NETWORK_FILES/genesis.json" "$GENESIS_OUT"
  echo "genesis.json restored."
else
  echo "=== Pulling hyperledger/besu:${BESU_VERSION} ==="
  docker pull "hyperledger/besu:${BESU_VERSION}"

  echo ""
  echo "=== Generating keys and genesis via Besu container ==="

  # Remove any leftover output dir (handles root-owned files from previous runs)
  docker run --rm -v "$DOCKER_DIR/config:/target" alpine sh -c "rm -rf /target/network-files"

  # Besu creates the output directory itself then immediately complains it exists —
  # this is a known Besu bug; the keys ARE generated despite the error, so we
  # capture output, filter the noise, and validate the actual files.
  keygen_out=$(docker run --rm \
    -v "$DOCKER_DIR/config/qbft-config.json:/config/qbft-config.json:ro" \
    -v "$DOCKER_DIR/config:/output" \
    "hyperledger/besu:${BESU_VERSION}" \
    operator generate-blockchain-config \
      --config-file=/config/qbft-config.json \
      --to=/output/network-files \
      --private-key-file-name=key 2>&1) || true

  # Print output, suppressing the spurious "already exists" line
  echo "$keygen_out" | grep -v "Output directory already exists" | grep -v "^$" || true

  if [ ! -f "$NETWORK_FILES/genesis.json" ] || [ ! -d "$NETWORK_FILES/keys" ]; then
    echo "ERROR: Key generation failed — genesis.json or keys missing." >&2
    echo "$keygen_out" >&2
    exit 1
  fi

  # Fix ownership without sudo — run chown inside a container as root
  docker run --rm \
    -v "$DOCKER_DIR/config:/target" alpine \
    chown -R "$(id -u):$(id -g)" /target/network-files 2>/dev/null || true

  cp "$NETWORK_FILES/genesis.json" "$GENESIS_OUT"
fi

echo ""
echo "=== Generated validator addresses ==="
ls -1 "$NETWORK_FILES/keys/"

echo ""
echo "=== genesis.json extraData (encodes validator set) ==="
python3 -c "import json; print(json.load(open('$DOCKER_DIR/config/genesis.json'))['extraData'])"

echo ""
echo "Done. Run scripts/2-setup-nodes.sh next."
