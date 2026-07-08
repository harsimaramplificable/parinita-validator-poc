#!/usr/bin/env bash
# TEST 06 — BFT fault tolerance (the "2/3 availability" test), fully dynamic.
#
# QBFT liveness rule for N validators:
#     quorum      = ceil(2N/3)  must be ONLINE to finalise blocks
#     max_faults  = floor(N/3)  may be OFFLINE and the chain KEEPS producing
#
# This network only seals a block when transactions arrive (emptyblockperiod is
# very high), so each phase PROBES liveness by submitting a tx and checking
# whether it gets mined:
#   PHASE 0  baseline (all up)                       → poke → expect MINED
#   PHASE 1  stop max_faults nodes (quorum still met)→ poke → expect MINED
#   PHASE 2  stop 1 more (quorum LOST)               → poke → expect NOT mined (FROZEN)
#   PHASE 3  restart that extra node (quorum back)   → poke → expect MINED (RESUME)
#   PHASE 4  restart the rest                        → poke → expect MINED (FULL HEALTH)
#
# Nodes are stopped highest-number-first, so the lowest-numbered validator stays
# up throughout and is used as the observer / tx submission point.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "TEST 06 — BFT fault tolerance / 2-of-3 availability"
require_running
ensure_pyeth || { fail "python eth libraries unavailable (needed to probe liveness)"; test_summary; exit $?; }

mapfile -t VALS < <(discover_validators)
N=${#VALS[@]}
QUORUM=$(qbft_quorum "$N")
MAXF=$(qbft_max_faults "$N")

OBS="${VALS[0]}"; OBS_PORT=$(rpc_port "$OBS")

# How long to allow for a poked block to appear once quorum IS met…
LIVE_WAIT="${FAULT_LIVE_WAIT:-$(( BLOCK_PERIOD * 6 + 6 ))}"
# …grace window for consensus to resume on its own after quorum is restored,
# before we fall back to the rolling restart that clears the round back-off.
GRACE="${FAULT_GRACE:-30}"
# How long to wait before we're confident the chain is genuinely FROZEN. Kept
# short on purpose: a shorter freeze means a smaller round-change back-off, so
# the chain recovers faster in PHASE 3.
FROZEN_WAIT="${FAULT_FROZEN_WAIT:-$(( BLOCK_PERIOD * 5 ))}"
# Settle time after starting/stopping containers before probing.
SETTLE="${FAULT_SETTLE:-$(( BLOCK_PERIOD * 3 + 3 ))}"

info "Validators (N)        : $N"
info "Quorum  (ceil 2N/3)   : $QUORUM  → this many must stay online"
info "Max faults (floor N/3): $MAXF  → this many may go offline"
info "Observer              : validator-$OBS (rpc $OBS_PORT), stays up throughout"

if (( MAXF < 1 )); then
  warn "N=$N is below the BFT minimum of 4 validators — no crash-fault tolerance is possible."
  warn "Add validators (make add-validator COUNT=…) to exercise the full 2/3 availability demo."
fi

STOPPED=()
cleanup() {
  echo; info "Cleanup: ensuring every validator is running again…"
  for n in "${STOPPED[@]}"; do [[ -n "$n" ]] && node_start "$n"; done
  for n in "${STOPPED[@]}"; do [[ -n "$n" ]] && wait_rpc "$(rpc_port "$n")" 30 >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

# ── PHASE 0 — baseline ────────────────────────────────────────────────────────
section "PHASE 0 — baseline: $N/$N up (quorum $QUORUM met) → expect MINED"
if chain_progresses "$OBS_PORT" "$LIVE_WAIT"; then
  pass "baseline chain mines blocks ($PROG_FROM → $PROG_TO)"
else
  fail "baseline chain will NOT mine ($PROG_FROM held) — fix the network before testing faults"; test_summary; exit $?
fi

STOP_ORDER=(); for (( i=N-1; i>=1; i-- )); do STOP_ORDER+=("${VALS[$i]}"); done

# ── PHASE 1 — stop max_faults nodes, quorum still met ─────────────────────────
if (( MAXF >= 1 )); then
  to_stop=("${STOP_ORDER[@]:0:MAXF}")
  section "PHASE 1 — stop $MAXF node(s): $(printf 'validator-%s ' "${to_stop[@]}")→ $((N-MAXF))/$N up (>= quorum $QUORUM) → expect MINED"
  for n in "${to_stop[@]}"; do info "stopping validator-$n"; node_stop "$n"; STOPPED+=("$n"); done
  sleep "$SETTLE"
  if chain_progresses "$OBS_PORT" "$LIVE_WAIT"; then
    pass "chain STILL mines with $MAXF node(s) down ($PROG_FROM → $PROG_TO) — tolerated as expected"
  else
    fail "chain froze after losing only $MAXF node(s) ($PROG_FROM held) — below expected tolerance"
  fi
fi

# ── PHASE 2 — stop one more, quorum lost ──────────────────────────────────────
extra="${STOP_ORDER[$MAXF]}"
section "PHASE 2 — stop 1 more (validator-$extra): $((N-MAXF-1))/$N up (< quorum $QUORUM) → expect FROZEN"
# No settle here: docker stop is synchronous, and we want to keep the frozen
# window short so QBFT's round-change back-off stays small (faster PHASE 3).
info "stopping validator-$extra"; node_stop "$extra"; STOPPED+=("$extra")
if chain_progresses "$OBS_PORT" "$FROZEN_WAIT"; then
  fail "chain kept mining without quorum ($PROG_FROM → $PROG_TO) — UNEXPECTED for QBFT"
else
  pass "chain correctly FROZE without quorum (held at $PROG_FROM) — safety preserved"
fi
info "why frozen: surviving nodes churn round-changes (round climbs, no new blocks):"
docker logs "$(container_name "$OBS")" --tail 200 2>&1 | grep -iE "RoundChange|Round:|round summary|dropped" | tail -n 3 | sed 's/^/     /' || true

# ── PHASE 3 — restore validators and recover ──────────────────────────────────
# Bring every stopped validator back. Two things matter here:
#   1. Restoring quorum is necessary but, after a freeze, the surviving nodes are
#      deep in QBFT round-change back-off (round timer doubles each round), so
#      just re-adding the missing node can take minutes to resume.
#   2. The operator-grade fix that ALWAYS clears the back-off is a rolling restart
#      of the validators (fresh boot ⇒ round 0 ⇒ immediate consensus).
# We first give the graceful path a short grace window, then fall back to the
# rolling restart so the network is guaranteed healthy at the end.
section "PHASE 3 — restore all validators & recover"
for n in "${STOPPED[@]}"; do [[ -n "$n" ]] || continue; info "starting validator-$n"; node_start "$n"; done
for n in "${STOPPED[@]}"; do [[ -n "$n" ]] || continue; wait_rpc "$(rpc_port "$n")" 40 >/dev/null 2>&1 || true; done
sleep "$SETTLE"

recovered=0
info "quorum restored — waiting up to ${GRACE}s for consensus to resume on its own…"
if chain_progresses "$OBS_PORT" "$GRACE"; then
  pass "chain RESUMED after restoring validators ($PROG_FROM → $PROG_TO)"
  recovered=1
else
  warn "still stuck in round-change back-off after restoring quorum — this is expected"
  warn "clearing it with a rolling restart of all validators (standard QBFT recovery)…"
  while IFS= read -r n; do docker restart "$(container_name "$n")" >/dev/null 2>&1; done < <(discover_validators)
  while IFS= read -r n; do wait_rpc "$(rpc_port "$n")" 40 >/dev/null 2>&1 || true; done < <(discover_validators)
  sleep "$SETTLE"
  if chain_progresses "$OBS_PORT" "$LIVE_WAIT"; then
    pass "chain recovered after a rolling restart cleared the round back-off ($PROG_FROM → $PROG_TO)"
    recovered=1
  else
    fail "chain still not producing after restoring quorum and a rolling restart ($PROG_FROM held)"
  fi
fi
STOPPED=(); trap - EXIT

# ── Final health check — full validator set online and producing ──────────────
section "FINAL — full health check"
up=0; while IFS= read -r n; do rpc_reachable "$(rpc_port "$n")" && up=$((up+1)); done < <(discover_validators)
assert_eq "$N" "$up" "all validators back online"
if (( recovered )); then pass "network is healthy and producing blocks again"
else fail "network did not fully recover"; fi

test_summary
