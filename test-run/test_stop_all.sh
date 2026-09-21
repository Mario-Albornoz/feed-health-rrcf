#!/bin/bash
# Regression test for `make stop-all`, without Kafka, the pipeline or any data.
#
# The bug it guards against: scripts/start_detector.sh writes 0 into
# .pids/detector-collector.pid when the stream collector is disabled. `kill 0` signals the
# caller's whole process group, so stop-all sent SIGTERM to make itself and to everything
# started from the same group (handler, detector), and `make thesis-full` died before the
# results were archived.
#
# The test points stop-all at a scratch pid directory (make PIDS_DIR=...), starts dummy
# processes, and runs make as the leader of its own process group next to a sentinel process:
# if stop-all ever signals its process group again, the sentinel dies and the test fails
# (instead of taking the test script down with it).
#
# It refuses to run while a real pipeline is up, because stop-all also runs global pkills.
#
#   ./test-run/test_stop_all.sh          scratch scenarios only (make test-stop-all)
#   ./test-run/test_stop_all.sh --real   also start the REAL handler and detector (needs
#                                        `make kafka-up` and built binaries), so the collector
#                                        pid file really holds 0, and stop them with stop-all.
#                                        (make test-stop-all-real). The handler and detector
#                                        reopen their output files, so archive a finished run
#                                        with `make archive-run` before using this.
REAL=0
[ "$1" = "--real" ] && REAL=1

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT" || exit 1

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
FAILURES=0
CHECKS=0

pass() { CHECKS=$((CHECKS + 1)); echo -e "  ${GREEN}✓ PASS${NC}: $1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); echo -e "  ${RED}✗ FAIL${NC}: $1"; }

alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

# Refuse to run next to a real pipeline: stop-all pkills by name.
if pgrep -f "scripts/run_multi_model.py|scripts/stream_collector.py|monitor_pipeline.sh|feed-handler/aggregator|bin/simulator" > /dev/null 2>&1; then
    echo -e "${RED}A pipeline component is running; stop it first (this test would kill it).${NC}"
    exit 2
fi
if [ -d "$PROJECT_ROOT/.pids" ]; then
    for f in "$PROJECT_ROOT"/.pids/*.pid; do
        [ -f "$f" ] || continue
        p=$(cat "$f" 2>/dev/null)
        if [ -n "$p" ] && [ "$p" -gt 0 ] 2>/dev/null && kill -0 "$p" 2>/dev/null; then
            echo -e "${RED}$f points at a live process ($p); stop the pipeline first.${NC}"
            exit 2
        fi
    done
fi

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/stop_all_test.XXXXXX")
PIDS="$SCRATCH/pids"
DUMMIES=""
STOP_ARGS="PIDS_DIR=$PIDS"     # empty in the --real scenario (real .pids directory)

cleanup() {
    for p in $DUMMIES; do kill -9 "$p" 2>/dev/null || true; done
    if [ "$REAL" -eq 1 ] && [ -n "$REAL_STARTED" ]; then   # never leave the real pipeline running
        python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' make stop-all > /dev/null 2>&1 || true
    fi
    rm -rf "$SCRATCH"
}
REAL_STARTED=""
trap cleanup EXIT

start_dummy() {  # sets DUMMY_PID; not called via $(...) so DUMMIES stays in this shell for cleanup
    sleep 300 > /dev/null 2>&1 &
    DUMMY_PID=$!
    disown "$DUMMY_PID" 2>/dev/null || true    # no "Terminated" job notices when stop-all kills it
    DUMMIES="$DUMMIES $DUMMY_PID"
}

# Run `make stop-all` on the scratch pid dir as the leader of a new session, with a sentinel
# process in the same process group. Sets MAKE_RC, MAKE_OUT and SENTINEL_ALIVE.
run_stop_all() {
    local sentinel_file="$SCRATCH/sentinel.pid"
    rm -f "$sentinel_file"
    local extra=()
    [ -n "$STOP_ARGS" ] && extra=("$STOP_ARGS")
    python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
        bash -c 'sleep 120 > /dev/null 2>&1 & echo $! > "$1"; shift; exec make "$@"' _ \
        "$sentinel_file" stop-all "${extra[@]}" > "$SCRATCH/make.out" 2>&1
    MAKE_RC=$?
    MAKE_OUT=$(cat "$SCRATCH/make.out")
    local sp
    sp=$(cat "$sentinel_file" 2>/dev/null)
    if alive "$sp"; then
        SENTINEL_ALIVE=1
        kill -9 "$sp" 2>/dev/null || true
    else
        SENTINEL_ALIVE=0
    fi
}

check_common() {  # checks every scenario must satisfy
    [ "$MAKE_RC" -eq 0 ] && pass "make stop-all exited 0" || fail "make stop-all exited $MAKE_RC (Terminated / killed?)"
    [ "$SENTINEL_ALIVE" -eq 1 ] && pass "process group was not signalled (sentinel alive)" \
        || fail "process group was signalled: the sentinel next to make died (the kill 0 bug)"
    echo "$MAKE_OUT" | grep -q "All components stopped" && pass "stop-all reached its last line" \
        || fail "stop-all did not reach 'All components stopped'"
}

echo "════════════════════════════════════════════════════════════"
echo "  stop-all regression test"
echo "════════════════════════════════════════════════════════════"

# --- Scenario 1: the failing case: collector pid file holds 0, real processes running ---------
echo -e "\n${YELLOW}1. collector pid file = 0, handler and simulator running${NC}"
mkdir -p "$PIDS"
start_dummy; H=$DUMMY_PID; start_dummy; S=$DUMMY_PID
echo "$H" > "$PIDS/handler.pid"
echo "$S" > "$PIDS/simulator.pid"
echo 0 > "$PIDS/detector-collector.pid"
run_stop_all
check_common
alive "$H" && fail "handler dummy still running" || pass "handler stopped"
alive "$S" && fail "simulator dummy still running" || pass "simulator stopped"
[ ! -e "$PIDS/detector-collector.pid" ] && [ ! -e "$PIDS/handler.pid" ] && [ ! -e "$PIDS/simulator.pid" ] \
    && pass "pid files removed (including the 0 one)" || fail "stale pid files left behind"

# --- Scenario 2: only the 0 pid file -----------------------------------------------------------
echo -e "\n${YELLOW}2. only a collector pid file = 0${NC}"
rm -rf "$PIDS"; mkdir -p "$PIDS"
echo 0 > "$PIDS/detector-collector.pid"
run_stop_all
check_common

# --- Scenario 3: nothing running, no pid files -------------------------------------------------
echo -e "\n${YELLOW}3. nothing running, no pid files${NC}"
rm -rf "$PIDS"; mkdir -p "$PIDS"
run_stop_all
check_common

# --- Scenario 4: stale pid files (dead processes), empty and garbage pid files ------------------
echo -e "\n${YELLOW}4. stale, empty and garbage pid files${NC}"
rm -rf "$PIDS"; mkdir -p "$PIDS"
start_dummy; D=$DUMMY_PID; kill -9 "$D" 2>/dev/null; wait "$D" 2>/dev/null
echo "$D" > "$PIDS/handler.pid"
: > "$PIDS/simulator.pid"
echo "not-a-pid" > "$PIDS/detector-collector.pid"
run_stop_all
check_common

# --- Scenario 5: a live process next to a 0 pid file is still stopped ---------------------------
echo -e "\n${YELLOW}5. handler running, collector pid 0, no simulator${NC}"
rm -rf "$PIDS"; mkdir -p "$PIDS"
start_dummy; H=$DUMMY_PID
echo "$H" > "$PIDS/handler.pid"
echo 0 > "$PIDS/detector-collector.pid"
run_stop_all
check_common
alive "$H" && fail "handler dummy still running" || pass "handler stopped"

# --- Scenario 6 (--real): the real handler and detector, collector disabled --------------------
if [ "$REAL" -eq 1 ]; then
    echo -e "\n${YELLOW}6. REAL handler + detector running (collector pid file = 0), then make stop-all${NC}"
    STOP_ARGS=""
    if ! docker ps --format '{{.Names}}' | grep -q '^thesis-kafka$'; then
        echo -e "  ${RED}Kafka is not running (make kafka-up); cannot run the real scenario${NC}"; exit 2
    fi
    if [ ! -x feed-handler/aggregator ] || [ ! -x rrcf-detector/venv/bin/python3 ]; then
        echo -e "  ${RED}feed-handler/aggregator or the detector venv is missing (make build-handler / make setup)${NC}"; exit 2
    fi
    mkdir -p .pids logs
    REAL_STARTED=1
    make run-handler > "$SCRATCH/start.out" 2>&1
    sleep 5
    make run-detector >> "$SCRATCH/start.out" 2>&1
    sleep 15
    HP=$(cat .pids/handler.pid 2>/dev/null); MP=$(cat .pids/detector-multi.pid 2>/dev/null)
    alive "$HP" && pass "real handler is running (PID $HP)" || fail "real handler did not start (see logs/handler.log)"
    alive "$MP" && pass "real detector is running (PID $MP)" || fail "real detector did not start (see logs/detector-multi.log)"
    [ "$(cat .pids/detector-collector.pid 2>/dev/null)" = "0" ] && pass "collector pid file holds 0 (the failing configuration)" \
        || fail "collector pid file does not hold 0; this run does not reproduce the configuration"
    run_stop_all
    check_common
    alive "$HP" && fail "real handler still running after stop-all" || pass "real handler stopped"
    alive "$MP" && fail "real detector still running after stop-all" || pass "real detector stopped"
    LEFT=$(pgrep -f "scripts/run_multi_model.py|multiprocessing.*spawn_main" | wc -l | tr -d ' ')
    [ "$LEFT" -eq 0 ] && pass "no detector worker processes left" || fail "$LEFT detector worker process(es) left"
    ls .pids/*.pid > /dev/null 2>&1 && fail "pid files left in .pids" || pass "pid files removed"
    REAL_STARTED=""
fi

echo ""
echo "════════════════════════════════════════════════════════════"
if [ "$FAILURES" -eq 0 ]; then
    echo -e "  ${GREEN}All $CHECKS checks passed${NC}"
    exit 0
else
    echo -e "  ${RED}$FAILURES of $CHECKS checks FAILED${NC}"
    exit 1
fi
