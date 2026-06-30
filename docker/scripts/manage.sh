#!/usr/bin/env bash
# Network management: start | stop | restart | status | logs | peers | validators | block | clean
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(dirname "$SCRIPT_DIR")"
cd "$DOCKER_DIR"

# JSON-RPC host port for validator N: 8544+N (matches docker-compose.yml and render-override.sh)
rpc_port() { echo $((8544 + $1)); }

# Discover all validator numbers that have a key file in nodes/
all_validators() {
  for d in nodes/validator-*/; do
    [[ -d "$d" ]] || continue
    n="${d%/}"; n="${n##*/validator-}"
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    [[ -f "nodes/validator-$n/data/key" ]] || continue
    echo "$n"
  done | sort -n
}

rpc_call() {
  local port=$1 method=$2
  curl -s -X POST \
    -H "Content-Type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":[\"latest\"],\"id\":1}" \
    "http://127.0.0.1:$port"
}

block_number() {
  rpc_call "$1" eth_blockNumber \
    | python3 -c "import sys,json; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null || echo "?"
}

peer_count() {
  curl -s -X POST \
    -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' \
    "http://127.0.0.1:$1" \
    | python3 -c "import sys,json; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null || echo "?"
}

cmd="${1:-help}"

case "$cmd" in
  start)
    echo "=== Starting besu-qbft network ==="
    docker compose up -d
    echo ""
    echo "--- Waiting 20s for nodes to peer ---"
    sleep 20
    bash "$0" status
    ;;

  stop)
    echo "=== Stopping besu-qbft network ==="
    docker compose down
    ;;

  restart)
    bash "$0" stop
    bash "$0" start
    ;;

  status)
    echo "=== Container status ==="
    docker compose ps
    echo ""
    echo "=== RPC health (host ports) ==="
    while IFS= read -r n; do
      port=$(rpc_port "$n")
      blk=$(block_number "$port")
      peers=$(peer_count "$port")
      printf "  validator-%-3s rpc=%-5s  block=%-6s peers=%s\n" "$n" "$port" "$blk" "$peers"
    done < <(all_validators)
    ;;

  logs)
    node="${2:-}"
    if [ -n "$node" ]; then
      docker compose logs -f "validator-$node"
    else
      docker compose logs -f
    fi
    ;;

  validators)
    echo "=== Current validator set (from chain) ==="
    curl -s -X POST \
      -H "Content-Type: application/json" \
      --data '{"jsonrpc":"2.0","method":"qbft_getValidatorsByBlockNumber","params":["latest"],"id":1}' \
      http://127.0.0.1:8545 | python3 -m json.tool
    ;;

  peers)
    echo "=== Peer count per node ==="
    while IFS= read -r n; do
      port=$(rpc_port "$n")
      peers=$(peer_count "$port")
      echo "  validator-$n (rpc $port): $peers peer(s)"
    done < <(all_validators)
    ;;

  block)
    echo "=== Block numbers (should all agree) ==="
    while IFS= read -r n; do
      port=$(rpc_port "$n")
      blk=$(block_number "$port")
      echo "  validator-$n (rpc $port): block $blk"
    done < <(all_validators)
    ;;

  clean)
    echo "WARNING: This removes all containers AND named volumes (blockchain data will be lost)."
    read -rp "Continue? [y/N] " ans
    [[ "${ans,,}" == "y" ]] || { echo "Aborted."; exit 0; }
    docker compose down -v
    ;;

  help|*)
    cat <<'USAGE'
Usage: manage.sh <command> [options]

  start              Start all validator nodes
  stop               Stop all validator nodes
  restart            Stop then start
  status             Show container status, block number, peer count
  logs [node-num]    Follow logs (all nodes, or a specific one)
  validators         Query current QBFT validator set from chain
  peers              Show peer count per node
  block              Show block number per node
  clean              Destroy containers and volumes (data loss!)
USAGE
    ;;
esac
