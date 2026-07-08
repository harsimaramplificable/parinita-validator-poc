#!/usr/bin/env bash
# Run the whole Besu QBFT test suite and print an aggregate summary.
#
#   ./run-all.sh                 # run every test
#   ./run-all.sh --fast          # skip the slow fault-tolerance test (06)
#   ./run-all.sh 01 03 05        # run only the numbered tests you list
#
# Each test is a standalone script that exits non-zero on failure.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FAST=0
SELECT=()
for arg in "$@"; do
  case "$arg" in
    --fast) FAST=1 ;;
    [0-9]*) SELECT+=("$arg") ;;
    *) echo "Unknown argument: $arg"; exit 2 ;;
  esac
done

# Ordered list of test files (numeric prefixes).
ALL=( "$TESTS_DIR"/[0-9][0-9]-*.sh )

# Filter by selection / --fast.
RUN=()
for f in "${ALL[@]}"; do
  base="$(basename "$f")"; num="${base%%-*}"
  if (( ${#SELECT[@]} )); then
    for s in "${SELECT[@]}"; do [[ "$num" == "$s" || "$num" == "0$s" ]] && RUN+=("$f"); done
  else
    [[ "$FAST" -eq 1 && "$num" == "06" ]] && continue
    RUN+=("$f")
  fi
done

if (( ${#RUN[@]} == 0 )); then echo "No matching tests to run."; exit 2; fi

section "BESU QBFT TEST SUITE"
info "Validators discovered: $(validator_count)  [$(discover_validators | paste -sd, -)]"
info "Running ${#RUN[@]} test(s): $(for f in "${RUN[@]}"; do basename "$f" .sh; done | paste -sd' ' -)"
[[ "$FAST" -eq 1 ]] && info "(--fast: skipping fault-tolerance)"

declare -a RESULTS=()
suite_fail=0
for f in "${RUN[@]}"; do
  name="$(basename "$f" .sh)"
  bash "$f"
  rc=$?
  if [[ $rc -eq 0 ]]; then RESULTS+=("${C_GRN}PASS${C_RST}  $name"); else RESULTS+=("${C_RED}FAIL${C_RST}  $name"); suite_fail=1; fi
done

section "SUITE SUMMARY"
for r in "${RESULTS[@]}"; do printf "   %b\n" "$r"; done
echo; hr
if [[ $suite_fail -eq 0 ]]; then
  printf "%s%s ✓ SUITE PASSED %s\n" "$C_BLD" "$C_GRN" "$C_RST"
else
  printf "%s%s ✗ SUITE FAILED %s\n" "$C_BLD" "$C_RED" "$C_RST"
fi
hr
exit $suite_fail
