cd ~/besu-qbft-lab && cat > besu-net.sh <<'SCRIPT'
#!/usr/bin/env bash
# Besu QBFT lab network control: start/stop/status, all nodes or one by number.
set -uo pipefail
LAB="$HOME/besu-qbft-lab"; cd "$LAB"; mkdir -p logs pids

p2p_port() { echo $((30302 + $1)); }
rpc_port() { echo $((8544  + $1)); }
node_pids() { pgrep -f "rpc-http-port=$(rpc_port "$1")" || true; }

start_one() {
  local n=$1
  if [ -n "$(node_pids "$n")" ]; then
    echo "node-$n already running (pid $(node_pids "$n" | tr '\n' ' '))"; return; fi
  local p2p rpc; p2p=$(p2p_port "$n"); rpc=$(rpc_port "$n")
  ( cd "node-$n" && nohup besu \
      --data-path=data --genesis-file=../genesis.json --node-private-key-file=data/key \
      --p2p-port="$p2p" --rpc-http-enabled --rpc-http-host=127.0.0.1 --rpc-http-port="$rpc" \
      --rpc-http-api=ETH,NET,QBFT,WEB3,ADMIN --rpc-http-cors-origins="*" \
      --host-allowlist="*" --min-gas-price=0 --profile=ENTERPRISE \
      > "$LAB/logs/node-$n.log" 2>&1 & echo $! > "$LAB/pids/node-$n.pid" )
  sleep 4
  if [ -n "$(node_pids "$n")" ]; then echo "Started node-$n  p2p=$p2p rpc=$rpc  -> logs/node-$n.log"
  else echo "node-$n FAILED to start — last log lines:"; tail -n 6 "logs/node-$n.log" 2>/dev/null; fi
}

stop_one() {
  local n=$1 pids; pids="$(node_pids "$n")"
  if [ -z "$pids" ]; then echo "node-$n: not running"; rm -f "pids/node-$n.pid"; return; fi
  echo "$pids" | xargs -r kill 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8; do [ -z "$(node_pids "$n")" ] && break; sleep 1; done
  if [ -n "$(node_pids "$n")" ]; then echo "$(node_pids "$n")" | xargs -r kill -9 2>/dev/null; sleep 1; fi
  rm -f "pids/node-$n.pid"; echo "node-$n: stopped"
}

status() {
  for n in 1 2 3 4; do local pids; pids="$(node_pids "$n")"
    if [ -n "$pids" ]; then echo "node-$n: UP   (pid $(echo $pids | tr '\n' ' '), rpc $(rpc_port $n))"
    else echo "node-$n: down"; fi; done
}

cmd="${1:-}"; target="${2:-}"
case "$cmd" in
  start)  if [ -n "$target" ]; then start_one "$target"; else for n in 1 2 3 4; do start_one "$n"; done; fi ;;
  stop)   if [ -n "$target" ]; then stop_one  "$target"; else for n in 1 2 3 4; do stop_one  "$n"; done; fi ;;
  status) status ;;
  *) echo "Usage: $0 {start|stop|status} [node-number]"; exit 1 ;;
esac
SCRIPT
chmod +x besu-net.sh && ./besu-net.sh start
echo "--- waiting 15s for peering + resume ---" && sleep 15
echo "=== status ===" && ./besu-net.sh status
echo "=== peers ===" && for p in 8545 8546 8547 8548; do
  printf "rpc %s peers: " "$p"
  curl -s -X POST --data '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' http://127.0.0.1:$p \
    | python3 -c "import sys,json; print(int(json.load(sys.stdin)['result'],16))" 2>/dev/null || echo "(starting)"
done
echo "=== climbing ===" && for i in 1 2; do
  curl -s -X POST --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://127.0.0.1:8545 \
    | python3 -c "import sys,json; print('block', int(json.load(sys.stdin)['result'],16))"; sleep 3; done
