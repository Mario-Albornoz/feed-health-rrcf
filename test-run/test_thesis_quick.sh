#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_ROOT/test-run/thesis_test_data"

mkdir -p "$TEST_DIR"

echo "════════════════════════════════════════════════════════════"
echo "  Thesis Evaluation Integration Test - Quick Version"
echo "  $(date)"
echo "════════════════════════════════════════════════════════════"
echo ""

FAILED_TESTS=0
TOTAL_TESTS=0

run_test() {
    local test_name="$1"
    local test_command="$2"
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo -n "Testing: $test_name... "
    
    if eval "$test_command" > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC}"
        return 0
    else
        echo -e "${RED}✗${NC}"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        return 1
    fi
}

echo -e "${BLUE}=== Prerequisites ===${NC}"
echo ""

run_test "Kafka is running" "docker ps | grep thesis-kafka | grep -q Up"

run_test "Simulator binary exists" "[ -x '$PROJECT_ROOT/price-feed-simulator/bin/simulator' ]"

run_test "Handler binary exists" "[ -x '$PROJECT_ROOT/feed-handler/aggregator' ]"

run_test "Python venv exists" "[ -f '$PROJECT_ROOT/rrcf-detector/venv/bin/python3' ]"

run_test "Data files present" "ls '$PROJECT_ROOT/price-feed-simulator/data/'*.csv | wc -l | grep -q '[1-9]'"

echo ""
echo -e "${BLUE}=== Python Environment ===${NC}"
echo ""

run_test "Python base imports" "cd '$PROJECT_ROOT/rrcf-detector' && ./venv/bin/python3 -c 'import pandas, pyarrow, numpy'"

run_test "Project imports" "cd '$PROJECT_ROOT/rrcf-detector' && ./venv/bin/python3 -c 'from src.baselines import BaseDetector'"

run_test "ParquetWriter import" "cd '$PROJECT_ROOT/rrcf-detector' && ./venv/bin/python3 -c 'from src.detection.generic_worker import ParquetWriter'"

echo ""
echo -e "${BLUE}=== Scripts and Configuration ===${NC}"
echo ""

run_test "Evaluation script exists" "[ -x '$PROJECT_ROOT/rrcf-detector/scripts/evaluate_thesis.py' ]"

run_test "Evaluation script runs" "cd '$PROJECT_ROOT/rrcf-detector' && ./venv/bin/python3 scripts/evaluate_thesis.py --help"

run_test "Anomaly config exists" "[ -f '$PROJECT_ROOT/price-feed-simulator/config/simulator-with-anomalies.yaml' ]"

run_test "Detector config exists" "[ -f '$PROJECT_ROOT/rrcf-detector/config/baselines.yaml' ]"

echo ""
echo -e "${BLUE}=== Makefile Targets ===${NC}"
echo ""

run_test "make run-thesis-experiment" "cd '$PROJECT_ROOT' && make -n run-thesis-experiment"
run_test "make evaluate-thesis" "cd '$PROJECT_ROOT' && make -n evaluate-thesis"
run_test "make thesis-full" "cd '$PROJECT_ROOT' && make -n thesis-full"

echo ""
echo -e "${BLUE}=== Functional Tests ===${NC}"
echo ""

echo -n "Testing: ParquetWriter functionality... "
cd "$PROJECT_ROOT/rrcf-detector"
if ./venv/bin/python3 << 'PYEOF'
import sys
import os
sys.path.insert(0, os.getcwd())
from src.detection.generic_worker import ParquetWriter

try:
    writer = ParquetWriter("../test-run/thesis_test_data/test_parquet.parquet", buffer_size=5)
    for i in range(10):
        writer.write({
            "exchange": "TEST",
            "instrument": f"INST{i}",
            "instrument_class": "test",
            "timestamp": f"2024-01-01T00:00:{i:02d}",
            "timestamp_ms": 1704067200000 + i * 1000,
            "model": "test",
            "raw_score": float(i),
            "z_score": float(i) / 5.0,
            "alert_level": "normal",
            "stats_mean": 0.0,
            "stats_std": 1.0,
            "stats_count": 100,
            "worker_id": 0,
        })
    writer.close()
    sys.exit(0)
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
then
    echo -e "${GREEN}✓${NC}"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    if [ -f "$TEST_DIR/test_parquet.parquet" ]; then
        size=$(wc -c < "$TEST_DIR/test_parquet.parquet")
        echo "  Created parquet file: $size bytes"
    fi
else
    echo -e "${RED}✗${NC}"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
fi

echo -n "Testing: Reading parquet file... "
if cd "$PROJECT_ROOT/rrcf-detector" && ./venv/bin/python3 << 'PYEOF'
import pandas as pd
import sys
df = pd.read_parquet("../test-run/thesis_test_data/test_parquet.parquet")
if len(df) == 10 and "model" in df.columns:
    sys.exit(0)
else:
    sys.exit(1)
PYEOF
then
    echo -e "${GREEN}✓${NC}"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
else
    echo -e "${RED}✗${NC}"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
fi

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Test Summary"
echo "════════════════════════════════════════════════════════════"
echo ""

PASSED=$((TOTAL_TESTS - FAILED_TESTS))
echo "Tests passed: $PASSED / $TOTAL_TESTS"

if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "${GREEN}✓ All tests passed!${NC}"
    echo ""
    echo "System is ready for thesis evaluation."
    echo ""
    echo "To run full experiment:"
    echo "  make thesis-full"
    echo ""
    exit 0
else
    echo -e "${RED}✗ $FAILED_TESTS test(s) failed${NC}"
    echo ""
    echo "Please fix the failed tests before running experiments."
    echo ""
    exit 1
fi
