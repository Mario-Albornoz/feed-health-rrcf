#!/bin/bash
#
# Pre-Flight Test - Validate setup before running thesis pipeline
# Tests all components independently before full run
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

FAILED_TESTS=0
TOTAL_TESTS=0

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Pipeline Pre-Flight Test${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Helper function
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

# Test 1: Kafka is running
echo -e "${YELLOW}[1/10] Checking Kafka...${NC}"
if docker ps | grep thesis-kafka | grep -q "Up"; then
    echo -e "  ${GREEN}✓${NC} Kafka is running"
else
    echo -e "  ${RED}✗${NC} Kafka is NOT running"
    echo -e "  ${YELLOW}Run: make kafka-up${NC}"
    FAILED_TESTS=$((FAILED_TESTS + 1))
fi
TOTAL_TESTS=$((TOTAL_TESTS + 1))

# Test 2: No orphan processes
echo -e "${YELLOW}[2/10] Checking for orphan processes...${NC}"
ORPHANS=$(ps aux | grep -E "simulator|Python.*multi|aggregator" | grep -v grep | wc -l | tr -d ' ')
if [ "$ORPHANS" -eq 0 ]; then
    echo -e "  ${GREEN}✓${NC} No orphan processes"
else
    echo -e "  ${RED}✗${NC} Found $ORPHANS orphan processes"
    echo -e "  ${YELLOW}Run: ./scripts/kill_all_processes.sh${NC}"
    FAILED_TESTS=$((FAILED_TESTS + 1))
fi
TOTAL_TESTS=$((TOTAL_TESTS + 1))

# Test 3: Output files cleaned
echo -e "${YELLOW}[3/10] Checking for leftover output files...${NC}"
LEFTOVER=0
[ -f "rrcf-detector/data/scores.parquet" ] && LEFTOVER=$((LEFTOVER + 1))
[ -f "price-feed-simulator/data/anomaly_log.csv" ] && LEFTOVER=$((LEFTOVER + 1))
[ -f "price-feed-simulator/data/injection_manifest.json" ] && LEFTOVER=$((LEFTOVER + 1))

if [ "$LEFTOVER" -eq 0 ]; then
    echo -e "  ${GREEN}✓${NC} No leftover output files"
else
    echo -e "  ${RED}✗${NC} Found $LEFTOVER leftover files"
    echo -e "  ${YELLOW}Run: make clean-output-files${NC}"
    FAILED_TESTS=$((FAILED_TESTS + 1))
fi
TOTAL_TESTS=$((TOTAL_TESTS + 1))

# Test 4: Simulator binary exists
echo -e "${YELLOW}[4/10] Checking simulator binary...${NC}"
if [ -f "price-feed-simulator/bin/simulator" ]; then
    echo -e "  ${GREEN}✓${NC} Simulator binary exists"
else
    echo -e "  ${RED}✗${NC} Simulator binary not found"
    echo -e "  ${YELLOW}Run: cd price-feed-simulator && make build${NC}"
    FAILED_TESTS=$((FAILED_TESTS + 1))
fi
TOTAL_TESTS=$((TOTAL_TESTS + 1))

# Test 5: Handler binary exists
echo -e "${YELLOW}[5/10] Checking handler binary...${NC}"
if [ -f "feed-handler/aggregator" ]; then
    echo -e "  ${GREEN}✓${NC} Handler binary exists"
else
    echo -e "  ${RED}✗${NC} Handler binary not found"
    echo -e "  ${YELLOW}Run: cd feed-handler && make build${NC}"
    FAILED_TESTS=$((FAILED_TESTS + 1))
fi
TOTAL_TESTS=$((TOTAL_TESTS + 1))

# Test 6: Python venv exists
echo -e "${YELLOW}[6/10] Checking Python virtual environment...${NC}"
if [ -d "rrcf-detector/venv" ]; then
    echo -e "  ${GREEN}✓${NC} Python venv exists"
else
    echo -e "  ${RED}✗${NC} Python venv not found"
    echo -e "  ${YELLOW}Run: cd rrcf-detector && python3 -m venv venv && source venv/bin/activate && pip install -r requirements.txt${NC}"
    FAILED_TESTS=$((FAILED_TESTS + 1))
fi
TOTAL_TESTS=$((TOTAL_TESTS + 1))

# Test 7: Data files exist
echo -e "${YELLOW}[7/10] Checking data files...${NC}"
DATA_FILES=$(ls price-feed-simulator/data/*.csv 2>/dev/null | wc -l | tr -d ' ')
if [ "$DATA_FILES" -gt 0 ]; then
    echo -e "  ${GREEN}✓${NC} Found $DATA_FILES CSV files"
else
    echo -e "  ${RED}✗${NC} No CSV data files found"
    echo -e "  ${YELLOW}Download DEBS 2022 dataset to price-feed-simulator/data/${NC}"
    FAILED_TESTS=$((FAILED_TESTS + 1))
fi
TOTAL_TESTS=$((TOTAL_TESTS + 1))

# Test 8: Anomaly config exists
echo -e "${YELLOW}[8/10] Checking anomaly config...${NC}"
if [ -f "price-feed-simulator/config/simulator-with-anomalies.yaml" ]; then
    echo -e "  ${GREEN}✓${NC} Anomaly config exists"
    
    # Check acceleration factor
    ACCEL=$(grep "acceleration_factor:" price-feed-simulator/config/simulator-with-anomalies.yaml | awk '{print $2}')
    echo -e "  ${BLUE}ℹ${NC}  Acceleration factor: $ACCEL"
else
    echo -e "  ${RED}✗${NC} Anomaly config not found"
    FAILED_TESTS=$((FAILED_TESTS + 1))
fi
TOTAL_TESTS=$((TOTAL_TESTS + 1))

# Test 9: Test simulator can start (5 second test)
echo -e "${YELLOW}[9/10] Testing simulator startup (5 seconds)...${NC}"
cd price-feed-simulator
./bin/simulator -config config/simulator-with-anomalies.yaml > /tmp/sim_test.log 2>&1 &
SIM_PID=$!
cd ..

sleep 5

if kill -0 $SIM_PID 2>/dev/null; then
    # Check if it's actually processing
    if grep -q "Throughput:" /tmp/sim_test.log; then
        THROUGHPUT=$(grep "Throughput:" /tmp/sim_test.log | tail -1 | awk '{print $10}')
        if [ "$THROUGHPUT" != "0" ]; then
            echo -e "  ${GREEN}✓${NC} Simulator running (Throughput: $THROUGHPUT)"
        else
            echo -e "  ${RED}✗${NC} Simulator stuck (Throughput: 0)"
            FAILED_TESTS=$((FAILED_TESTS + 1))
        fi
    else
        echo -e "  ${YELLOW}⚠${NC} Simulator started but no throughput data yet"
    fi
    kill $SIM_PID 2>/dev/null
    wait $SIM_PID 2>/dev/null
else
    echo -e "  ${RED}✗${NC} Simulator crashed"
    echo -e "  ${YELLOW}Check /tmp/sim_test.log for errors${NC}"
    FAILED_TESTS=$((FAILED_TESTS + 1))
fi
TOTAL_TESTS=$((TOTAL_TESTS + 1))

# Test 10: Check system resources
echo -e "${YELLOW}[10/10] Checking system resources...${NC}"
LOAD=$(sysctl -n vm.loadavg | awk '{print $2}')
NCPU=$(sysctl -n hw.ncpu)
LOAD_PCT=$(awk "BEGIN {printf \"%.0f\", ($LOAD / $NCPU) * 100}")

if [ "$LOAD_PCT" -lt 70 ]; then
    echo -e "  ${GREEN}✓${NC} CPU load OK ($LOAD_PCT% of capacity)"
else
    echo -e "  ${YELLOW}⚠${NC} CPU load high ($LOAD_PCT% of capacity)"
fi

MEM_PRESSURE=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo "unknown")
if [ "$MEM_PRESSURE" == "1" ]; then
    echo -e "  ${GREEN}✓${NC} Memory pressure normal (level 1)"
elif [ "$MEM_PRESSURE" == "2" ]; then
    echo -e "  ${YELLOW}⚠${NC} Memory pressure warning (level 2)"
else
    echo -e "  ${RED}✗${NC} Memory pressure critical (level $MEM_PRESSURE)"
fi
TOTAL_TESTS=$((TOTAL_TESTS + 1))

# Summary
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [ "$FAILED_TESTS" -eq 0 ]; then
    echo -e "${GREEN}✓ All tests passed ($TOTAL_TESTS/$TOTAL_TESTS)${NC}"
    echo -e "${GREEN}  Ready to run: make thesis-full${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    exit 0
else
    echo -e "${RED}✗ $FAILED_TESTS/$TOTAL_TESTS tests failed${NC}"
    echo -e "${YELLOW}  Fix the issues above before running pipeline${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    exit 1
fi
