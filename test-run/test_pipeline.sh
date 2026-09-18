#!/bin/bash

# Pipeline Integration Test Script
# Tests partial pipeline execution with timeout and verification

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test configuration
TEST_DURATION=30  # Run simulator for 30 seconds
STARTUP_WAIT=5    # Wait 5 seconds between component starts
LOG_CHECK_WAIT=3  # Wait 3 seconds for logs to accumulate

# Directories
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_ROOT/test-run"
LOGS_DIR="$PROJECT_ROOT/logs"
PIDS_DIR="$PROJECT_ROOT/.pids"

# PID files
HANDLER_PID="$PIDS_DIR/handler.pid"
SIMULATOR_PID="$PIDS_DIR/simulator.pid"

# Test results
TEST_RESULTS="$TEST_DIR/test_results.txt"
TEST_LOG="$TEST_DIR/test_execution.log"

# Initialize test
echo "════════════════════════════════════════════════════════════" | tee "$TEST_LOG"
echo "  Pipeline Integration Test" | tee -a "$TEST_LOG"
echo "  $(date)" | tee -a "$TEST_LOG"
echo "════════════════════════════════════════════════════════════" | tee -a "$TEST_LOG"
echo "" | tee -a "$TEST_LOG"

# Clear previous test results
> "$TEST_RESULTS"

# Function to log test results
log_result() {
    local test_name="$1"
    local status="$2"
    local message="$3"
    
    if [ "$status" = "PASS" ]; then
        echo -e "${GREEN}✓ PASS${NC}: $test_name" | tee -a "$TEST_LOG"
    elif [ "$status" = "FAIL" ]; then
        echo -e "${RED}✗ FAIL${NC}: $test_name - $message" | tee -a "$TEST_LOG"
    elif [ "$status" = "WARN" ]; then
        echo -e "${YELLOW}⚠ WARN${NC}: $test_name - $message" | tee -a "$TEST_LOG"
    fi
    
    echo "$test_name|$status|$message" >> "$TEST_RESULTS"
}

# Function to check if a process is running
check_process() {
    local pid_file="$1"
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# Function to cleanup on exit
cleanup() {
    echo "" | tee -a "$TEST_LOG"
    echo -e "${YELLOW}Cleaning up...${NC}" | tee -a "$TEST_LOG"
    cd "$PROJECT_ROOT"
    make stop-all >> "$TEST_LOG" 2>&1 || true
    sleep 2
}

trap cleanup EXIT

# Test 1: Check prerequisites
echo -e "${BLUE}Test 1: Checking prerequisites...${NC}" | tee -a "$TEST_LOG"

if docker ps | grep -q "thesis-kafka"; then
    log_result "Kafka running" "PASS" ""
else
    log_result "Kafka running" "FAIL" "Kafka is not running. Run 'make kafka-up' first."
    exit 1
fi

if [ -f "$PROJECT_ROOT/feed-handler/aggregator" ]; then
    log_result "Handler binary exists" "PASS" ""
else
    log_result "Handler binary exists" "FAIL" "Handler not built. Run 'make build-handler'"
    exit 1
fi

if [ -f "$PROJECT_ROOT/price-feed-simulator/bin/simulator" ]; then
    log_result "Simulator binary exists" "PASS" ""
else
    log_result "Simulator binary exists" "FAIL" "Simulator not built. Run 'make build-simulator'"
    exit 1
fi

if [ -d "$PROJECT_ROOT/rrcf-detector/venv" ]; then
    log_result "Detector venv exists" "PASS" ""
else
    log_result "Detector venv exists" "FAIL" "Detector venv not setup. Run 'make setup-detector'"
    exit 1
fi

# Check for data files
data_count=$(ls -1 "$PROJECT_ROOT/price-feed-simulator/data/"*.csv 2>/dev/null | wc -l)
if [ "$data_count" -gt 0 ]; then
    log_result "Data files present" "PASS" "$data_count CSV files found"
else
    log_result "Data files present" "FAIL" "No CSV files in price-feed-simulator/data/"
    exit 1
fi

echo "" | tee -a "$TEST_LOG"

# Test 2: Clean start - stop any running components
echo -e "${BLUE}Test 2: Ensuring clean state...${NC}" | tee -a "$TEST_LOG"
cd "$PROJECT_ROOT"
make stop-all >> "$TEST_LOG" 2>&1 || true
sleep 2

if check_process "$HANDLER_PID"; then
    log_result "Clean state" "FAIL" "Handler still running after stop"
else
    log_result "Clean state" "PASS" "All processes stopped"
fi

echo "" | tee -a "$TEST_LOG"

# Test 3: Start feed-handler
echo -e "${BLUE}Test 3: Starting feed-handler...${NC}" | tee -a "$TEST_LOG"
cd "$PROJECT_ROOT"
make run-handler >> "$TEST_LOG" 2>&1

sleep "$STARTUP_WAIT"

if check_process "$HANDLER_PID"; then
    log_result "Handler startup" "PASS" "PID: $(cat $HANDLER_PID)"
else
    log_result "Handler startup" "FAIL" "Handler not running"
    cat "$LOGS_DIR/handler.log" | tail -20
    exit 1
fi

# Check handler logs
sleep "$LOG_CHECK_WAIT"
if [ -f "$LOGS_DIR/handler.log" ]; then
    if grep -q "ERROR\|FATAL\|panic" "$LOGS_DIR/handler.log"; then
        log_result "Handler logs healthy" "WARN" "Errors found in logs"
    else
        log_result "Handler logs healthy" "PASS" "No errors in logs"
    fi
else
    log_result "Handler logs exist" "FAIL" "No handler.log file"
fi

echo "" | tee -a "$TEST_LOG"

# Test 4: Start detector
echo -e "${BLUE}Test 4: Starting detector pipeline...${NC}" | tee -a "$TEST_LOG"
cd "$PROJECT_ROOT"
make run-detector >> "$TEST_LOG" 2>&1

sleep "$STARTUP_WAIT"

if check_process "$PIDS_DIR/detector-collector.pid"; then
    log_result "Detector collector startup" "PASS" "PID: $(cat $PIDS_DIR/detector-collector.pid)"
else
    log_result "Detector collector startup" "FAIL" "Collector not running"
fi

if check_process "$PIDS_DIR/detector-multi.pid"; then
    log_result "Detector multi-model startup" "PASS" "PID: $(cat $PIDS_DIR/detector-multi.pid)"
else
    log_result "Detector multi-model startup" "FAIL" "Multi-model not running"
fi

# Check detector logs
sleep "$LOG_CHECK_WAIT"
if [ -f "$LOGS_DIR/detector-collector.log" ]; then
    log_result "Detector collector logs exist" "PASS" ""
else
    log_result "Detector collector logs exist" "FAIL" "No collector log"
fi

echo "" | tee -a "$TEST_LOG"

# Test 5: Start simulator (limited duration)
echo -e "${BLUE}Test 5: Starting simulator (${TEST_DURATION}s test run)...${NC}" | tee -a "$TEST_LOG"
cd "$PROJECT_ROOT"
make run-simulator >> "$TEST_LOG" 2>&1

sleep "$STARTUP_WAIT"

if check_process "$SIMULATOR_PID"; then
    log_result "Simulator startup" "PASS" "PID: $(cat $SIMULATOR_PID)"
else
    log_result "Simulator startup" "FAIL" "Simulator not running"
    exit 1
fi

# Check simulator logs
sleep "$LOG_CHECK_WAIT"
if [ -f "$LOGS_DIR/simulator.log" ]; then
    log_result "Simulator logs exist" "PASS" ""
    
    # Check for throughput in logs
    sleep 5
    if grep -q "ticks/sec\|Throughput" "$LOGS_DIR/simulator.log"; then
        log_result "Simulator producing data" "PASS" "Throughput stats found"
    else
        log_result "Simulator producing data" "WARN" "No throughput stats yet"
    fi
else
    log_result "Simulator logs exist" "FAIL" "No simulator log"
fi

echo "" | tee -a "$TEST_LOG"

# Test 6: Let pipeline run
echo -e "${BLUE}Test 6: Running pipeline for ${TEST_DURATION} seconds...${NC}" | tee -a "$TEST_LOG"
echo -e "${YELLOW}Monitoring components...${NC}" | tee -a "$TEST_LOG"

for i in $(seq 1 "$TEST_DURATION"); do
    sleep 1
    
    # Check all processes every 10 seconds
    if [ $((i % 10)) -eq 0 ]; then
        echo -n "." | tee -a "$TEST_LOG"
        
        if ! check_process "$HANDLER_PID"; then
            log_result "Handler stability" "FAIL" "Handler died during test"
            break
        fi
        
        if ! check_process "$SIMULATOR_PID"; then
            log_result "Simulator stability" "FAIL" "Simulator died during test"
            break
        fi
    fi
done

echo "" | tee -a "$TEST_LOG"

# Verify all processes still running
if check_process "$HANDLER_PID"; then
    log_result "Handler stability" "PASS" "Running after ${TEST_DURATION}s"
fi

if check_process "$SIMULATOR_PID"; then
    log_result "Simulator stability" "PASS" "Running after ${TEST_DURATION}s"
fi

if check_process "$PIDS_DIR/detector-collector.pid"; then
    log_result "Detector stability" "PASS" "Running after ${TEST_DURATION}s"
fi

echo "" | tee -a "$TEST_LOG"

# Test 7: Check log files
echo -e "${BLUE}Test 7: Verifying log files...${NC}" | tee -a "$TEST_LOG"

for log_file in handler.log simulator.log detector-collector.log detector-multi.log; do
    if [ -f "$LOGS_DIR/$log_file" ]; then
        size=$(wc -c < "$LOGS_DIR/$log_file")
        if [ "$size" -gt 100 ]; then
            log_result "Log file $log_file" "PASS" "${size} bytes"
        else
            log_result "Log file $log_file" "WARN" "Only ${size} bytes"
        fi
    else
        log_result "Log file $log_file" "FAIL" "File not found"
    fi
done

echo "" | tee -a "$TEST_LOG"

# Test 8: Test stop-all
echo -e "${BLUE}Test 8: Testing stop-all command...${NC}" | tee -a "$TEST_LOG"
cd "$PROJECT_ROOT"
make stop-all >> "$TEST_LOG" 2>&1

sleep 3

stopped=0
if ! check_process "$HANDLER_PID"; then
    ((stopped++))
fi

if ! check_process "$SIMULATOR_PID"; then
    ((stopped++))
fi

if ! check_process "$PIDS_DIR/detector-collector.pid"; then
    ((stopped++))
fi

if ! check_process "$PIDS_DIR/detector-multi.pid"; then
    ((stopped++))
fi

if [ "$stopped" -eq 4 ]; then
    log_result "Stop all components" "PASS" "All 4 components stopped"
else
    log_result "Stop all components" "FAIL" "Only $stopped/4 components stopped"
fi

echo "" | tee -a "$TEST_LOG"

# Test 9: Analyze logs for errors
echo -e "${BLUE}Test 9: Analyzing logs for errors...${NC}" | tee -a "$TEST_LOG"

for log_file in "$LOGS_DIR"/*.log; do
    if [ -f "$log_file" ]; then
        filename=$(basename "$log_file")
        error_count=$(grep -ic "error\|fatal\|panic" "$log_file" 2>/dev/null || echo "0")
        
        if [ "$error_count" = "0" ]; then
            log_result "Errors in $filename" "PASS" "No errors found"
        else
            log_result "Errors in $filename" "WARN" "$error_count error(s) found"
        fi
    fi
done

echo "" | tee -a "$TEST_LOG"

# Generate summary report
echo "════════════════════════════════════════════════════════════" | tee -a "$TEST_LOG"
echo "  Test Summary" | tee -a "$TEST_LOG"
echo "════════════════════════════════════════════════════════════" | tee -a "$TEST_LOG"
echo "" | tee -a "$TEST_LOG"

pass_count=$(grep -c "|PASS|" "$TEST_RESULTS" 2>/dev/null || echo "0")
fail_count=$(grep -c "|FAIL|" "$TEST_RESULTS" 2>/dev/null || echo "0")
warn_count=$(grep -c "|WARN|" "$TEST_RESULTS" 2>/dev/null || echo "0")
total_count=$((pass_count + fail_count + warn_count))

echo -e "${GREEN}PASSED: $pass_count${NC}" | tee -a "$TEST_LOG"
echo -e "${RED}FAILED: $fail_count${NC}" | tee -a "$TEST_LOG"
echo -e "${YELLOW}WARNINGS: $warn_count${NC}" | tee -a "$TEST_LOG"
echo "TOTAL: $total_count" | tee -a "$TEST_LOG"
echo "" | tee -a "$TEST_LOG"

# Show log file sizes
echo "Log file sizes:" | tee -a "$TEST_LOG"
ls -lh "$LOGS_DIR"/*.log 2>/dev/null | awk '{print "  " $9 ": " $5}' | tee -a "$TEST_LOG"
echo "" | tee -a "$TEST_LOG"

# Final verdict
if [ "$fail_count" = "0" ]; then
    echo -e "${GREEN}✓ ALL TESTS PASSED${NC}" | tee -a "$TEST_LOG"
    exit_code=0
else
    echo -e "${RED}✗ SOME TESTS FAILED${NC}" | tee -a "$TEST_LOG"
    exit_code=1
fi

echo "" | tee -a "$TEST_LOG"
echo "Full test log: $TEST_LOG" | tee -a "$TEST_LOG"
echo "Test results: $TEST_RESULTS" | tee -a "$TEST_LOG"
echo "" | tee -a "$TEST_LOG"

exit $exit_code
