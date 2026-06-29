cd ~/besu-qbft-lab && cat > besu-net.sh <<'SCRIPT'
#!/usr/bin/env bash
# Besu QBFT lab network control. Auto-discovers every node-* directory.
set -uo pipefail
LAB="$HOME/besu-qbft-lab"; cd "$LAB"; mkdir -p logs pids
all_nodes() { for d in node-*; do [ -d "$d" ] && echo "${d#node-}"; done | sort -n; }
p2p_port() { echo $((30302 + $1)); }
rpc_port() { echo $((8544  + $1)); }
node_pids() { pgrep -f "rpc-http-port=$(rpc_port "$1")" || true; }
start_one() {
  local n=$1
  if [ -n "$(node_pids "$n")" ]; then echo "node-$n already running (pid $(node_pids "$n" | tr '\n' ' '))"; return; fi
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
  for n in $(all_nodes); do local pids; pids="$(node_pids "$n")"
    if [ -n "$pids" ]; then echo "node-$n: UP   (pid $(echo $pids | tr '\n' ' '), rpc $(rpc_port $n))"
    else echo "node-$n: down"; fi; done
}
cmd="${1:-}"; target="${2:-}"
case "$cmd" in
  start)  if [ -n "$target" ]; then start_one "$target"; else for n in $(all_nodes); do start_one "$n"; done; fi ;;
  stop)   if [ -n "$target" ]; then stop_one  "$target"; else for n in $(all_nodes); do stop_one  "$n"; done; fi ;;
  status) status ;;
  nodes)  echo "managed nodes: $(all_nodes | tr '\n' ' ')" ;;
  *) echo "Usage: $0 {start|stop|status|nodes} [node-number]"; exit 1 ;;
esac
SCRIPT
chmod +x besu-net.sh

cat > add-fullnode.sh <<'SCRIPT'
#!/usr/bin/env bash
# Create a NON-VALIDATOR full/RPC node and wire it to the 4 validators.
set -euo pipefail
LAB="$HOME/besu-qbft-lab"; cd "$LAB"
N="${1:-5}"; P2P=$((30302 + N)); RPC=$((8544 + N)); HOST="127.0.0.1"
[ -d "node-$N" ] && { echo "node-$N already exists — pick another number" >&2; exit 1; }
mkdir -p "node-$N/data"
out="node-$N/data/static-nodes.json"; echo "[" > "$out"; first=1
for v in 1 2 3 4; do
  [ -f "node-$v/data/key.pub" ] || { echo "missing node-$v/data/key.pub" >&2; exit 1; }
  pub=$(tr -d '[:space:]' < "node-$v/data/key.pub"); pub=${pub#0x}
  vp2p=$((30302 + v))
  [ "$first" -eq 1 ] && first=0 || echo "," >> "$out"
  printf '  "enode://%s@%s:%s"' "$pub" "$HOST" "$vp2p" >> "$out"
done
printf '\n]\n' >> "$out"
echo "Created node-$N (p2p=$P2P rpc=$RPC) as a NON-VALIDATOR full node."
echo "It will dial all four validators on first start, sync the chain, and serve"
echo "RPC on port $RPC — but it holds no validator key, so it takes no part in consensus."
echo "--- node-$N/data/static-nodes.json ---"; cat "$out"
SCRIPT
chmod +x add-fullnode.sh && echo "installed"
