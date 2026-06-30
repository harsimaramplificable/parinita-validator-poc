# Hyperledger Besu QBFT Lab

A private Ethereum network running the QBFT (Quorum Byzantine Fault Tolerant) consensus protocol on Hyperledger Besu. Two deployment modes are provided:

- **Bare-metal / local** — four validator processes on a single host (scripts `1-*.sh` through `5-*.sh`)
- **Docker** — four containerised validators managed by Docker Compose with a `Makefile` interface

---

## Table of Contents

1. [Architecture](#architecture)
2. [Prerequisites](#prerequisites)
3. [Bare-Metal Setup (Local)](#bare-metal-setup-local)
4. [Docker Setup](#docker-setup)
5. [Docker — All Commands Reference](#docker--all-commands-reference)
6. [Validator Governance](#validator-governance)
7. [Multi-VM Deployment](#multi-vm-deployment)
8. [Monitoring (Prometheus + Grafana)](#monitoring-prometheus--grafana)
9. [Tests & Health Checks](#tests--health-checks)
10. [Port Reference](#port-reference)
11. [Troubleshooting](#troubleshooting)

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  QBFT Network  (chainId 1337)                                    │
│                                                                  │
│  validator-1  ──── validator-2                                   │
│      │    \      /    │                                          │
│      │     \   /      │                                          │
│  validator-4  ──── validator-3                                   │
│                                                                  │
│  Quorum = floor(2N/3) + 1  →  for N=4, quorum = 3               │
│  BFT tolerance: survives 1 faulty/offline node                   │
└──────────────────────────────────────────────────────────────────┘
```

Each node holds its own ECDSA key pair. Consensus requires ≥3 of 4 nodes to agree on each block.

---

## Prerequisites

### Bare-metal

| Requirement | Version |
|-------------|---------|
| Java | OpenJDK 25+ |
| Hyperledger Besu | 26.6.1 |
| Python 3 | any recent |
| curl | system package |

### Docker

| Requirement | Notes |
|-------------|-------|
| Docker Engine | 24+ recommended |
| Docker Compose v2 | bundled with Docker Desktop / `docker compose` plugin |
| `make` | standard build tool |
| Python 3 | used in helper scripts |
| `curl` | used in helper scripts |

---

## Bare-Metal Setup (Local)

Run scripts in order from the repo root. Each script is idempotent — re-running is safe unless noted.

### Step 1 — Install Java and Besu

```bash
bash 1-installation.sh
```

Installs OpenJDK 25, downloads Besu 26.6.1, adds `/opt/besu/bin` to `PATH`, and verifies the install.

> **Important:** After running, unset the `BESU_VERSION` env var or start a new shell — it conflicts with the Besu CLI.

### Step 2 — Create project and write genesis config

```bash
bash 2-setup.sh
```

Creates `~/besu-qbft-lab/` and writes `qbftConfigFile.json` with chainId 1337, 4 validators, and three pre-funded dev accounts.

### Step 3 — Generate keys and genesis

```bash
bash 3-init.sh
```

Runs `besu operator generate-blockchain-config` to produce `networkFiles/` containing a `genesis.json` and one key pair per validator.

**Checkpoint** — verify output:

```bash
cd ~/besu-qbft-lab
echo "=== Validators ===" && ls -1 networkFiles/keys
echo "=== extraData ===" && python3 -c "import json; print(json.load(open('networkFiles/genesis.json'))['extraData'])"
```

### Step 4 — Distribute keys and build static-nodes mesh

```bash
bash 4-network-setup.sh
```

Copies each key pair into `node-1/` through `node-4/`, builds a full-mesh `static-nodes.json` for each node (listing the other three enodes), and places the shared `genesis.json` at the lab root.

**Checkpoint** — verify file structure:

```bash
cd ~/besu-qbft-lab
echo "=== structure ===" && find node-1 node-2 node-3 node-4 -type f | sort
echo "=== node-1 static-nodes.json ===" && cat node-1/data/static-nodes.json
echo "=== genesis check ===" && diff -q genesis.json networkFiles/genesis.json && echo "genesis matches"
```

### Step 5 — Launch network

```bash
bash 5-launch-network.sh
```

Installs `besu-net.sh` into `~/besu-qbft-lab/`, starts all four nodes in the background (logs go to `logs/node-N.log`), waits 15 s for peering, then prints status, peer counts, and two block-height samples.

### Controlling the bare-metal network

```bash
cd ~/besu-qbft-lab

./besu-net.sh start           # start all nodes
./besu-net.sh start 2         # start only node-2
./besu-net.sh stop            # stop all nodes
./besu-net.sh stop 3          # stop only node-3
./besu-net.sh status          # show running status of all nodes
```

### Adding validators (bare-metal)

```bash
# From the repo root
./add-validators.sh 1         # add one validator
./add-validators.sh 3         # add three validators in sequence
```

Each new validator is first joined as a non-validator (syncs the chain), then voted in via `qbft_proposeValidatorVote`.

---

## Docker Setup

All Docker operations are run from the `docker/` directory.

```bash
cd docker/
```

### One-time initialisation

```bash
make init
```

This runs two steps in sequence:

| Step | Command | What it does |
|------|---------|--------------|
| 1 | `make generate-keys` | Runs Besu in a container to generate 4 key pairs and `genesis.json` |
| 2 | `make setup-nodes` | Distributes keys, writes `static-nodes.json`, copies `config.toml` to each node directory |

### Start the network

```bash
make start
```

Starts all four validator containers and waits 20 s for them to peer. Runs `make status` automatically.

### Verify the network is healthy

```bash
make status      # container state + block number + peer count per node
make block       # block height across all nodes (should all agree)
make peers       # peer count per node (each should see 3)
make validators  # list the active QBFT validator set from the chain
```

---

## Docker — All Commands Reference

Run these from the `docker/` directory.

### Setup

```bash
make init              # [1+2] Full one-time setup: generate keys + distribute nodes
make generate-keys     # [1] Generate QBFT validator keys and genesis.json only
make setup-nodes       # [2] Distribute keys and create static-nodes.json only
make clean-keys        # Remove generated keys/genesis (allows re-running init)
```

### Network lifecycle

```bash
make start             # Start all validator containers
make stop              # Stop all validator containers
make restart           # Stop then start all containers
```

### Status and inspection

```bash
make status            # Container status, block number, peer count
make block             # Block height per node
make peers             # Peer count per node
make validators        # Active QBFT validator set from the chain
make logs              # Follow logs from all nodes (Ctrl+C to exit)
make logs NODE=2       # Follow logs for validator-2 only
```

### Validator governance

```bash
make add-validator COUNT=1     # Add one new validator
make add-validator COUNT=3     # Add three validators in sequence
make remove-validator NODE=5   # Remove validator-5 from the network
```

### Monitoring

```bash
make monitoring-start  # Start Prometheus + Grafana alongside the chain
make monitoring-stop   # Stop Prometheus + Grafana (chain keeps running)
```

### Cleanup

```bash
make clean             # Stop containers and delete volumes (chain data lost — prompts for confirmation)
make clean-keys        # Remove generated keys/genesis only (containers untouched)
make destroy           # FULL wipe: containers, volumes, keys, genesis, all node data (requires typing "yes")
```

### Direct Docker Compose commands

```bash
docker compose up -d                          # start all nodes
docker compose down                           # stop all nodes
docker compose down -v                        # stop and delete volumes
docker compose ps                             # container status
docker compose logs -f                        # follow all logs
docker compose logs -f validator-2            # follow validator-2 logs
docker exec -it besu-validator-1 bash        # shell into a container
```

---

## Validator Governance

QBFT uses on-chain voting to add or remove validators. A proposal requires votes from a simple majority of the current validator set (`floor(N/2)+1`).

### Add a validator (Docker)

```bash
cd docker/
make add-validator COUNT=1
```

What the script does internally:
1. Generates a new key pair via a temporary Besu container
2. Updates `static-nodes.json` on all existing nodes and hot-adds the peer via `admin_addPeer`
3. Builds `static-nodes.json` for the new node listing all existing peers
4. Copies `config.toml`, rebuilds `docker-compose.override.yml`, starts the new container
5. Waits 30 s for sync, then casts `qbft_proposeValidatorVote(address, true)` from each existing validator
6. Waits 30 s and confirms the address appears in `qbft_getValidatorsByBlockNumber`

### Remove a validator (Docker)

```bash
cd docker/
make remove-validator NODE=5
```

Casts `qbft_proposeValidatorVote(address, false)` from all other validators, stops the container, and (for validators added beyond the initial four) removes the node directory, Docker volume, and enode from all `static-nodes.json` files.

> **Note:** Base validators 1–4 are defined in `docker-compose.yml`. Removing them only stops the container; edit `docker-compose.yml` manually to permanently remove the service.

### Manual vote via JSON-RPC

```bash
# Propose adding an address (true = add, false = remove)
curl -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"qbft_proposeValidatorVote","params":["0xADDRESS",true],"id":1}' \
  http://127.0.0.1:8545

# Check current validator set
curl -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"qbft_getValidatorsByBlockNumber","params":["latest"],"id":1}' \
  http://127.0.0.1:8545 | python3 -m json.tool
```

---

## Multi-VM Deployment

Run each validator on a separate VM. All VMs must be able to reach each other on P2P port 30303 (TCP+UDP).

### Prerequisites

- SSH key-based auth from your local machine to each VM
- Docker installed on each VM
- Keys already generated locally: `make -C docker init`

### Deploy a node to a remote VM

```bash
cd multi-vm/

# Deploy validator-2 to a remote VM
./deploy.sh 2 ubuntu@34.12.34.56
```

This rsyncs the compose files and only that node's key to the remote, creates `.env.local` from `.env.example`, and starts the container.

### Configure each remote VM

On first deploy, edit `/opt/besu-qbft/.env.local` on the remote VM:

```bash
NODE_NUMBER=2                   # which validator this VM runs
NODE_HOST=34.12.34.56           # this VM's external IP
NODE_IP_1=10.0.0.1              # external IP of VM running validator-1
NODE_IP_2=10.0.0.2              # this VM
NODE_IP_3=10.0.0.3
NODE_IP_4=10.0.0.4
P2P_PORT=30303
RPC_PORT=8545
METRICS_PORT=9545
BESU_VERSION=26.6.1
```

Then start the container on the remote:

```bash
ssh ubuntu@34.12.34.56
cd /opt/besu-qbft
docker compose --env-file .env.local -f single-node-compose.yml up -d
docker compose --env-file .env.local -f single-node-compose.yml ps
```

---

## Monitoring (Prometheus + Grafana)

The monitoring stack attaches to the existing `besu-net` bridge network and scrapes metrics from all validator nodes.

### Start monitoring

```bash
cd docker/
make monitoring-start
```

| Service | URL | Default credentials |
|---------|-----|---------------------|
| Grafana | http://localhost:3000 | admin / admin |
| Prometheus | http://localhost:9090 | — |

### Stop monitoring (chain keeps running)

```bash
make monitoring-stop
```

### Configuration

- Prometheus scrape config: [docker/monitoring/prometheus/prometheus.yml](docker/monitoring/prometheus/prometheus.yml)
- Ports and password: edit `GRAFANA_ADMIN_PASSWORD`, `GRAFANA_PORT`, `PROMETHEUS_PORT` in [docker/.env](docker/.env)

---

## Tests & Health Checks

All test scripts are in `tests/` and target the bare-metal network at `~/besu-qbft-lab`.

### 1. Network Setup Checkpoint

Verify file structure and genesis after Step 4:

```bash
bash tests/1-Network-Setup-Checkpoint.sh
```

Expected: 12 files across `node-1..node-4`, three enodes in each `static-nodes.json`, genesis files match.

### 2. Launch Network Checkpoint

Verify peering after Step 5:

```bash
bash tests/2-Lunch-Network-Checkpoint.sh
```

Expected: all four nodes up, each showing 3 peers.

### 3. Health Check

Confirm the chain is producing blocks and all nodes agree:

```bash
bash tests/3-Health-Check.sh
```

Checks:
- Block number is climbing (sampled three times, 3 s apart)
- All four RPC ports report the same block height
- `qbft_getValidatorsByBlockNumber` returns four validators
- Recent `Imported`/`Produced` log entries on node-1

### 4. Fault Tolerance Demo

Live demonstration of QBFT's 3-of-4 quorum requirement:

```bash
bash tests/4-fault-tolerance-demo.sh
```

| Phase | State | Expected behaviour |
|-------|-------|--------------------|
| 0 | 4/4 nodes up | Blocks climbing |
| 1 | node-4 stopped (3/4) | Still climbing — quorum met |
| 2 | node-3 stopped (2/4) | **Frozen** — quorum lost |
| 3 | node-3 restarted (3/4) | Resumes from frozen height |
| 4 | node-4 restarted (4/4) | Full health restored |

### 5. Transaction Test

Send 1 ETH between two dev accounts and verify the receipt:

```bash
pip install web3 --break-system-packages
bash tests/5-Transaction-Script.sh
```

Expected output: transaction hash, block number it was mined in, `status=1`, and balance delta of ±1 ETH on both accounts.

### Ad-hoc JSON-RPC checks

```bash
# Block number (all nodes should agree)
for p in 8545 8546 8547 8548; do
  printf "rpc %s: " "$p"
  curl -s -X POST --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    http://127.0.0.1:$p | python3 -c "import sys,json; print(int(json.load(sys.stdin)['result'],16))"
done

# Peer count per node
for p in 8545 8546 8547 8548; do
  printf "rpc %s peers: " "$p"
  curl -s -X POST --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' \
    http://127.0.0.1:$p | python3 -c "import sys,json; print(int(json.load(sys.stdin)['result'],16))"
done

# Current validator set
curl -s -X POST --data '{"jsonrpc":"2.0","method":"qbft_getValidatorsByBlockNumber","params":["latest"],"id":1}' \
  http://127.0.0.1:8545 | python3 -m json.tool

# Chain ID
curl -s -X POST --data '{"jsonrpc":"2.0","method":"net_version","params":[],"id":1}' \
  http://127.0.0.1:8545
```

---

## Port Reference

### Docker (host-side ports)

| Node | P2P TCP/UDP | JSON-RPC HTTP | Prometheus metrics |
|------|-------------|---------------|--------------------|
| validator-1 | 30303 | 8545 | 9545 |
| validator-2 | 30304 | 8546 | 9546 |
| validator-3 | 30305 | 8547 | 9547 |
| validator-4 | 30306 | 8548 | 9548 |
| validator-N | 30302+N | 8544+N | 9544+N |

### Container IPs (Docker bridge subnet 172.16.240.0/24)

| Node | Container IP |
|------|--------------|
| validator-1 | 172.16.240.11 |
| validator-2 | 172.16.240.12 |
| validator-3 | 172.16.240.13 |
| validator-4 | 172.16.240.14 |
| validator-N | 172.16.240.(10+N) |

### Bare-metal

| Node | P2P | JSON-RPC |
|------|-----|----------|
| node-1 | 30303 | 8545 |
| node-2 | 30304 | 8546 |
| node-3 | 30305 | 8547 |
| node-4 | 30306 | 8548 |

---

## Troubleshooting

### Chain is frozen / no new blocks

A QBFT chain freezes when fewer than `floor(2N/3)+1` validators are reachable. For a 4-node network, at least 3 must be running.

```bash
make status        # check container status
make peers         # check peer connectivity
make validators    # confirm validator set
```

### Node won't start

```bash
make logs NODE=1   # inspect startup errors
docker compose ps  # check exit codes
```

Common causes:
- `config/genesis.json` missing — run `make init`
- Port already in use — check `lsof -i :8545`
- Stale volume with incompatible chain data — run `make destroy` then `make init`

### New validator not joining the validator set

The candidate must be running and synced **before** votes are cast. The `add-validator.sh` script enforces a 30 s wait, but a slow machine may need longer. Check:

```bash
make validators          # is the address in the set?
make logs NODE=<N>       # look for "Importing block" entries on the new node
```

### Permissions error on key files

Besu requires the key file to be readable only by its process owner. If Docker generates root-owned files:

```bash
sudo chown -R $USER:$USER docker/nodes/
```

### Resetting everything (Docker)

```bash
cd docker/
make destroy
make init
make start
```
