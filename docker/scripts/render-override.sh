#!/usr/bin/env bash
# Regenerate docker-compose.override.yml from the current nodes/ directory state.
#
# Rule: validators 1..INITIAL_VALIDATOR_COUNT live in docker-compose.yml (base file).
#       Any validator-N with N > INITIAL_VALIDATOR_COUNT AND nodes/validator-N/data/key
#       present gets a service+volume entry in the override.
#
# This script is idempotent — call it after every structural change:
#   add-validator, remove-validator, destroy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(dirname "$SCRIPT_DIR")"
OVERRIDE="$DOCKER_DIR/docker-compose.override.yml"

set -a
source "$DOCKER_DIR/.env"
[[ -f "$DOCKER_DIR/.env.local" ]] && source "$DOCKER_DIR/.env.local"
set +a

python3 - "$DOCKER_DIR" "${INITIAL_VALIDATOR_COUNT:-4}" "172.16.240" "$OVERRIDE" <<'PY'
import sys, os, glob, re

docker_dir    = sys.argv[1]
base_count    = int(sys.argv[2])
subnet        = sys.argv[3]
override_path = sys.argv[4]

# Collect extra validator indices: N > base_count, key file must exist
extras = []
candidates = sorted(
    glob.glob(os.path.join(docker_dir, "nodes", "validator-*")),
    key=lambda p: int(re.search(r'\d+$', p).group())
)
for d in candidates:
    m = re.search(r'validator-(\d+)$', d)
    if not m:
        continue
    n = int(m.group(1))
    if n <= base_count:
        continue
    if not os.path.isfile(os.path.join(d, "data", "key")):
        continue
    extras.append(n)

# NOTE: do NOT redeclare `besu-net` here. This override is auto-merged with the
# base docker-compose.yml on every `docker compose up`. Marking the network
# `external` would override the base definition and stop Compose from ever
# creating it (fails with "network besu-qbft_besu-net ... could not be found"
# after a `make destroy` removes it). Extra-validator services below simply
# attach to `besu-net`, which the base file defines and creates.
lines = [
    "name: besu-qbft",
]

if extras:
    lines.append("volumes:")
    for n in extras:
        lines.append(f"  validator-{n}-data:")
    lines.append("services:")
    for n in extras:
        p2p = 30302 + n
        rpc  = 8544  + n
        met  = 9544  + n
        ip   = f"{subnet}.{10 + n}"
        lines += [
            f"  validator-{n}:",
            f"    image: hyperledger/besu:${{BESU_VERSION:-latest}}",
            f"    container_name: besu-validator-{n}",
            f"    hostname: besu-validator-{n}",
            f"    restart: unless-stopped",
            f"    networks:",
            f"      besu-net:",
            f"        ipv4_address: {ip}",
            f"    healthcheck:",
            f'      test: ["CMD-SHELL", "curl -sf http://localhost:8545/liveness || exit 1"]',
            f"      interval: 30s",
            f"      timeout: 10s",
            f"      retries: 5",
            f"      start_period: 60s",
            f"    logging:",
            f"      driver: json-file",
            f"      options:",
            f'        max-size: "50m"',
            f'        max-file: "5"',
            f"    volumes:",
            f"      - validator-{n}-data:/opt/besu/data",
            f"      - ./nodes/validator-{n}/data/key:/opt/besu/keys/key:ro",
            f"      - ./nodes/validator-{n}/data/static-nodes.json:/opt/besu/data/static-nodes.json:ro",
            f"      - ./config/genesis.json:/opt/besu/genesis.json:ro",
            f"      - ./nodes/validator-{n}/config.toml:/opt/besu/config.toml:ro",
            f"    ports:",
            f'      - "{p2p}:30303/tcp"',
            f'      - "{p2p}:30303/udp"',
            f'      - "{rpc}:8545"',
            f'      - "{met}:9545"',
            f'    command: ["--config-file=/opt/besu/config.toml"]',
        ]
else:
    # Explicit empty mappings — bare "volumes:" / "services:" parse as null
    # and cause Docker Compose merge to fail with "must be a mapping".
    lines += ["volumes: {}", "services: {}"]

with open(override_path, "w") as f:
    f.write("\n".join(lines) + "\n")

label = str(extras) if extras else "(none — base validators only)"
print(f"  Rendered override: extra validators = {label}")
PY
