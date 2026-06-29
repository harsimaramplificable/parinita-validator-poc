cd ~/besu-qbft-lab && cat > vote-validator.sh <<'SCRIPT'
#!/usr/bin/env bash
# Cast a QBFT add/remove validator vote on a majority (>50%) of current validators.
set -euo pipefail
LAB="$HOME/besu-qbft-lab"; cd "$LAB"
TARGET="${1:?usage: vote-validator.sh <0xaddress> add|remove}"
ACTION="${2:?usage: vote-validator.sh <0xaddress> add|remove}"
case "$ACTION" in
  add)    BOOL=true ;;
  remove) BOOL=false ;;
  *) echo "action must be 'add' or 'remove'" >&2; exit 1 ;;
esac
rpc() { echo "http://127.0.0.1:$((8544 + $1))"; }
N=$(curl -s -X POST --data '{"jsonrpc":"2.0","method":"qbft_getValidatorsByBlockNumber","params":["latest"],"id":1}' "$(rpc 1)" \
    | python3 -c "import sys,json; print(len(json.load(sys.stdin)['result']))")
NEED=$(( N/2 + 1 ))
echo "Current validators: $N  ->  votes needed (>50%): $NEED"
echo "Proposing to '$ACTION' $TARGET from node-1..node-$NEED:"
for n in $(seq 1 "$NEED"); do
  res=$(curl -s -X POST \
        --data "{\"jsonrpc\":\"2.0\",\"method\":\"qbft_proposeValidatorVote\",\"params\":[\"$TARGET\",$BOOL],\"id\":1}" \
        "$(rpc "$n")" | python3 -c "import sys,json; print(json.load(sys.stdin).get('result'))")
  echo "  node-$n (rpc $((8544+n))): proposeValidatorVote -> $res"
done
echo "Done. Proposers embed these votes over the next few blocks; the set updates"
echo "once >50% have included the vote. Check with qbft_getValidatorsByBlockNumber."
SCRIPT
chmod +x vote-validator.sh && echo "installed"
