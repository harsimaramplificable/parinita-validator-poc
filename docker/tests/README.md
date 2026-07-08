# Besu QBFT test suite

Advanced, **auto-scaling** tests for the dockerised QBFT network. Every test
discovers the current validator set from `nodes/validator-*/data/key` (the same
rule `scripts/manage.sh` uses), so there is **nothing hardcoded to 4 nodes** —
add validators with `make add-validator COUNT=N` and the tests adapt: expected
peer counts, the on-chain validator count, and the BFT quorum/fault bounds all
recompute from the discovered `N`.

## Running

All commands are run from the `docker/` directory and need a **running network**
(`make start`).

| Command | What it runs |
| --- | --- |
| `make test` | The full suite (tests 01–06) |
| `make test-fast` | Everything except the slow fault-tolerance test |
| `make test-connectivity` | 01 — RPC reachable + chain id on every validator |
| `make test-peers` | 02 — full peer mesh (each node sees `N-1` peers) |
| `make test-consensus` | 03 — blocks are produced (when poked) and all nodes agree |
| `make test-validators` | 04 — on-chain validator set matches the nodes on disk and is consistent |
| `make test-tx` | 05 — send a value transfer and confirm it is mined |
| `make test-fault` | 06 — BFT 2/3 availability (stops/restarts nodes, self-heals) |

You can also call the runner directly:

```bash
bash tests/run-all.sh            # full suite
bash tests/run-all.sh --fast     # skip the fault-tolerance test
bash tests/run-all.sh 01 03 05   # only the numbered tests you list
```

## The 2/3 availability (BFT) test — test 06

For `N` validators, QBFT liveness follows:

- **quorum = ⌈2N/3⌉** validators must be online to finalise blocks
- **max faults = ⌊N/3⌋** validators may be offline and the chain keeps producing

The test discovers `N`, computes both bounds, then walks through:

| Phase | Action | Expectation |
| --- | --- | --- |
| 0 | baseline, all up | blocks are mined |
| 1 | stop `⌊N/3⌋` nodes (quorum still met) | still mined — fault tolerated |
| 2 | stop one more (quorum lost) | **frozen** — safety preserved |
| 3 | restore all validators | chain recovers |

Nodes are always stopped highest-number-first, so the lowest-numbered validator
stays up throughout and is used as the observer.

### Two behaviours worth knowing

1. **The chain only seals a block when a transaction arrives.** The genesis sets
   `emptyblockperiodseconds` very high, so height does not climb on its own.
   Liveness is therefore *probed* — the tests submit a tiny transfer (the
   pre-funded Besu dev account, `gasPrice 0`) and check whether it gets mined.
   That is what "poke" means in the output.

2. **Recovery after a freeze can be slow.** Once quorum is lost, the surviving
   nodes enter QBFT round-change back-off (the round timer doubles each round),
   so simply re-adding the missing node can take minutes to resume. Phase 3 first
   gives the graceful path a short grace window, then falls back to a **rolling
   restart** of the validators — a fresh boot resets every round timer to 0 and
   consensus resumes within seconds. That is the standard operator recovery for a
   QBFT network that has lost quorum.

## Tuning (environment variables)

| Variable | Default | Meaning |
| --- | --- | --- |
| `NO_COLOR` | unset | disable coloured output |
| `CONSENSUS_DRIFT` | 3 | max block-height spread allowed across nodes (test 03) |
| `FAULT_LIVE_WAIT` | `6·blockperiod+6` | how long to wait for a poked block when quorum is met |
| `FAULT_FROZEN_WAIT` | `5·blockperiod` | how long to confirm the chain is genuinely frozen |
| `FAULT_GRACE` | 30 | grace window for self-recovery before the rolling restart |
| `FAULT_SETTLE` | `3·blockperiod+3` | settle time after start/stop before probing |

## Files

- `lib.sh` — shared helpers: validator discovery, RPC calls, quorum math, tx
  poking, container control, and pass/fail reporting.
- `01`–`06` — the individual tests (standalone; each exits non-zero on failure).
- `run-all.sh` — runs the suite and prints an aggregate summary.

> Python `web3`/`eth_account` are used to sign transactions and are installed
> automatically on first use.
