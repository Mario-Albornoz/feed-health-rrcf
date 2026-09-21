#!/bin/bash
# Test for `make archive-run`, on fake module directories in a scratch dir (nothing real is
# read or written; the module, log and results directories are overridden on the command line).
#
#   ./test-run/test_archive_run.sh        (or: make test-archive-run)

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT" || exit 1

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
FAILURES=0; CHECKS=0
pass() { CHECKS=$((CHECKS + 1)); echo -e "  ${GREEN}✓ PASS${NC}: $1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); echo -e "  ${RED}✗ FAIL${NC}: $1"; }

T=$(mktemp -d "${TMPDIR:-/tmp}/archive_run_test.XXXXXX")
trap 'rm -rf "$T"' EXIT

mk_run() {  # a complete fake run, with $1 as the scores content
    rm -rf "$T/sim" "$T/handler" "$T/det" "$T/logs"
    mkdir -p "$T/sim/data" "$T/sim/config" "$T/handler/data/eval" "$T/handler/config" "$T/det/data/vectors" "$T/det/config" "$T/logs"
    for f in anomaly_log.csv anomaly_log_episodes.csv anomaly_log_instruments.csv; do echo "$f" > "$T/sim/$f"; done
    echo '{}' > "$T/sim/data/injection_manifest.json"
    echo "sim" > "$T/sim/config/simulator-with-anomalies.yaml"
    echo "a" > "$T/handler/data/eval/silence_alerts.csv"; echo "a" > "$T/handler/data/eval/validation_alerts.csv"
    echo "agg" > "$T/handler/config/aggregator.yaml"
    echo "$1" > "$T/det/data/scores_rrcf.parquet"
    echo "sample-$1" > "$T/det/data/vectors/vectors_sample.parquet"
    echo "base" > "$T/det/config/baselines.yaml"
    echo "log" > "$T/logs/handler.log"
}

arch() {  # make archive-run on the fake tree; extra make args in "$@"
    make archive-run SIMULATOR_DIR="$T/sim" HANDLER_DIR="$T/handler" DETECTOR_DIR="$T/det" \
        LOGS_DIR="$T/logs" RESULTS_DIR="$T/results" ARCHIVE_DIR="$T/results/thesis_x" "$@" > "$T/out.txt" 2>&1
}

REAL_PY="$PROJECT_ROOT/rrcf-detector/venv/bin/python3"
CHECKER="$PROJECT_ROOT/rrcf-detector/scripts/check_vector_sample.py"

gen_sample() {  # a genuine recording + summary, made by the real runner code: $1 vectors consumed
    rm -rf "$T/det/data/vectors"; mkdir -p "$T/det/data/vectors"
    PYTHONPATH="$PROJECT_ROOT/rrcf-detector" "$REAL_PY" - "$T/det/data/vectors" "$1" > /dev/null 2>&1 <<'PYEOF'
import sys
from pathlib import Path
from tests.test_vector_sample import make_vectors, make_runner
d, n = Path(sys.argv[1]), int(sys.argv[2])
r = make_runner(None, record_file=str(d / "vectors_sample.parquet"))
for v in make_vectors(n):
    r._handle_vector(v)
r._shutdown()
PYEOF
}

echo "════════════════════════════════════════════════════════════"
echo "  archive-run test"
echo "════════════════════════════════════════════════════════════"

echo -e "\n${YELLOW}1. complete run${NC}"
mk_run "scores-v1"
arch && pass "archive-run exited 0" || fail "archive-run failed: $(tail -3 "$T/out.txt")"
I="$T/results/thesis_x/inputs"
ok=1
for f in anomaly_log.csv anomaly_log_episodes.csv anomaly_log_instruments.csv injection_manifest.json \
         silence_alerts.csv validation_alerts.csv scores_rrcf.parquet vectors/vectors_sample.parquet versions.txt logs/handler.log \
         config/simulator-with-anomalies.yaml config/aggregator.yaml config/baselines.yaml; do
    [ -f "$I/$f" ] || { ok=0; echo "     missing: $f"; }
done
[ "$ok" -eq 1 ] && pass "every expected file is in inputs/" || fail "files missing from inputs/"
[ "$(readlink "$T/results/latest")" = "thesis_x" ] && pass "results/latest -> thesis_x" || fail "latest symlink wrong"

echo -e "\n${YELLOW}2. repeating the same archive is fine${NC}"
arch && pass "second archive-run of the same run exited 0" || fail "repeat failed"

echo -e "\n${YELLOW}3. a different run must not overwrite the archive${NC}"
echo "scores-a-different-and-longer-run" > "$T/det/data/scores_rrcf.parquet"
arch && fail "archive-run overwrote an archive holding a different scores file" || pass "archive-run refused (exit non-zero)"
grep -q "already holds a different scores file" "$T/out.txt" && pass "and said why" || fail "no explanation printed"
[ "$(cat "$I/scores_rrcf.parquet")" = "scores-v1" ] && pass "archived scores untouched" || fail "archived scores were changed"
arch FORCE=1 && [ "$(cat "$I/scores_rrcf.parquet")" != "scores-v1" ] && pass "FORCE=1 overrides" || fail "FORCE=1 did not override"

echo -e "\n${YELLOW}4. an essential file is missing: copies the rest, then fails${NC}"
mk_run "scores-v2"; rm "$T/det/data/scores_rrcf.parquet"
rm -rf "$T/results"
arch && fail "archive-run exited 0 with the scores file missing" || pass "archive-run exited non-zero"
grep -q "scores file missing" "$T/out.txt" && pass "named the missing file" || fail "did not name the missing file"
[ -f "$T/results/thesis_x/inputs/anomaly_log_episodes.csv" ] && pass "the other files were still copied" || fail "did not copy the rest"

echo -e "\n${YELLOW}4b. a run without a vector sample archives, with a note (not an error)${NC}"
mk_run "scores-v4"; rm -rf "$T/det/data/vectors" "$T/results"
arch && pass "archive-run exited 0 without a vector sample" || fail "archive-run failed without a sample: $(tail -3 "$T/out.txt")"
grep -q "no vector sample" "$T/out.txt" && pass "and said the run was not recorded" || fail "no note about the missing sample"

echo -e "\n${YELLOW}4c. a different run's vector sample must not overwrite the archive${NC}"
mk_run "scores-v5"; rm -rf "$T/results"
arch || fail "setup archive failed"
echo "a-different-sample" > "$T/det/data/vectors/vectors_sample.parquet"
arch && fail "archive-run overwrote a different vector sample" || pass "archive-run refused a different vector sample"
[ "$(cat "$T/results/thesis_x/inputs/vectors/vectors_sample.parquet")" = "sample-scores-v5" ] && pass "archived sample untouched" || fail "archived sample was changed"

echo -e "\n${YELLOW}4d. a genuine sample is cross-checked against the runner's summary${NC}"
if [ ! -x "$REAL_PY" ]; then
    echo "  (skipped: $REAL_PY not found, run 'make setup')"
else
    mk_run "scores-v6"; rm -rf "$T/results"
    gen_sample 95
    arch PY="$REAL_PY" CHECK_SAMPLE="$CHECKER" && pass "archive-run accepted a consistent sample" || fail "consistent sample rejected: $(tail -6 "$T/out.txt")"
    grep -q "vector sample OK" "$T/out.txt" && pass "the check ran and reported OK" || fail "the cross-check did not run"
    [ -f "$T/results/thesis_x/inputs/vectors/vectors_sample.summary.json" ] && pass "the summary was archived with the sample" || fail "summary not archived"

    echo -e "\n${YELLOW}4e. a sample that disagrees with the runner's summary fails the archive${NC}"
    mk_run "scores-v7"; rm -rf "$T/results"
    gen_sample 95
    "$REAL_PY" - "$T/det/data/vectors/vectors_sample.summary.json" <<'PYEOF'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["recorded_rows"] += 1; json.dump(d, open(p, "w"))
PYEOF
    arch PY="$REAL_PY" CHECK_SAMPLE="$CHECKER" && fail "archive-run accepted a sample that disagrees with the summary" || pass "archive-run exited non-zero"
    grep -q "does not match what the runner reported" "$T/out.txt" && pass "and said why" || fail "no explanation printed: $(tail -4 "$T/out.txt")"
    grep -q "rows in the file == vectors the runner recorded" "$T/out.txt" && pass "and named the failing check" || fail "failing check not named"
fi

echo -e "\n${YELLOW}5. default ARCHIVE_DIR is a new results/thesis_<stamp>${NC}"
mk_run "scores-v3"; rm -rf "$T/results"
make archive-run SIMULATOR_DIR="$T/sim" HANDLER_DIR="$T/handler" DETECTOR_DIR="$T/det" LOGS_DIR="$T/logs" RESULTS_DIR="$T/results" > "$T/out.txt" 2>&1 \
    && ls -d "$T"/results/thesis_[0-9]*/inputs > /dev/null 2>&1 && pass "created results/thesis_<stamp>/inputs" || fail "default archive dir not created: $(tail -3 "$T/out.txt")"

echo ""
echo "════════════════════════════════════════════════════════════"
if [ "$FAILURES" -eq 0 ]; then echo -e "  ${GREEN}All $CHECKS checks passed${NC}"; exit 0
else echo -e "  ${RED}$FAILURES of $CHECKS checks FAILED${NC}"; exit 1; fi
