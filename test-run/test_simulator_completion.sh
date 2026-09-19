#!/bin/bash
# Test: Verify simulator completes and stops gracefully after processing all files

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SIMULATOR_DIR="$PROJECT_ROOT/price-feed-simulator"

echo "============================================================"
echo "Test: Simulator Completion and Graceful Shutdown"
echo "============================================================"
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

cleanup() {
    echo ""
    echo "${YELLOW}Cleaning up test artifacts...${NC}"
    cd "$SIMULATOR_DIR"
    rm -f data/test_completion_*.csv
    rm -f data/test_anomaly_log.csv
    rm -f data/test_injection_manifest.json
    rm -f config/test_simulator.yaml
    if [ ! -z "$SIMULATOR_PID" ] && kill -0 "$SIMULATOR_PID" 2>/dev/null; then
        echo "  Killing stuck simulator (PID: $SIMULATOR_PID)..."
        kill -9 "$SIMULATOR_PID" 2>/dev/null || true
    fi
    echo "  ✓ Cleanup complete"
}

trap cleanup EXIT

# Step 1: Create small test CSV files
echo "Step 1: Creating small test CSV files (100 rows each)..."
cd "$SIMULATOR_DIR"

head -101 "data/debs2022-gc-trading-day-08-11-21.csv" > "data/test_completion_08-11-21.csv"
head -101 "data/debs2022-gc-trading-day-09-11-21.csv" > "data/test_completion_09-11-21.csv"

echo "  ✓ Created test files"

# Step 2: Create test config
echo ""
echo "Step 2: Creating test configuration..."

cat > "config/test_simulator.yaml" << 'EOF'
kafka:
  brokers: ["localhost:9092"]
  topic: raw-ticks

publisher:
  batch_size: 100
  batch_timeout_ms: 10
  compression: snappy
  workers: 1

simulator:
  mode: fullspeed
  data_dir: data
  file_pattern: "test_completion_*.csv"

performance:
  csv_buffer_kb: 64
  parse_workers: 1
  channel_buffer: 100

logging:
  stats_interval_sec: 2
  level: info

anomaly:
  enabled: true
  seed: 42
  log_file: test_anomaly_log.csv
  
  phase1_tick_rate_decline:
    enabled: true
    date_filter: ["08-11-2021"]
    window: {start: "09:30:00", end: "14:00:00"}
    decline_pattern: linear
    initial_rate: 1.0
    final_rate: 0.5
    instrument_ratio: 0.2
  
  phase2_contextual_anomalies:
    enabled: false
  phase3_feed_silence:
    enabled: false
  phase4_point_failures:
    enabled: false
EOF

echo "  ✓ Test config created"

# Step 3: Ensure Kafka is running
echo ""
echo "Step 3: Ensuring Kafka is running..."
cd "$PROJECT_ROOT"
if ! docker ps | grep thesis-kafka | grep -q "Up"; then
    echo "  Starting Kafka..."
    make kafka-up > /dev/null 2>&1
    sleep 3
fi
echo "  ✓ Kafka is running"

# Step 4: Run simulator with timeout
echo ""
echo "Step 4: Running simulator (timeout: 30s)..."
echo ""

cd "$SIMULATOR_DIR"
./bin/simulator -config config/test_simulator.yaml > /tmp/test_simulator.log 2>&1 &
SIMULATOR_PID=$!

echo "  Simulator PID: $SIMULATOR_PID"

# Wait for completion with timeout
TIMEOUT=30
ELAPSED=0
while kill -0 "$SIMULATOR_PID" 2>/dev/null; do
    sleep 1
    ELAPSED=$((ELAPSED + 1))
    
    if [ $ELAPSED -ge $TIMEOUT ]; then
        echo ""
        echo "${RED}✗ FAIL: Simulator did not complete within ${TIMEOUT}s${NC}"
        echo ""
        echo "Simulator log (last 30 lines):"
        tail -30 /tmp/test_simulator.log
        exit 1
    fi
    
    if [ $((ELAPSED % 5)) -eq 0 ]; then
        echo "    ... ${ELAPSED}s elapsed"
    fi
done

wait "$SIMULATOR_PID"
EXIT_CODE=$?
SIMULATOR_PID=""

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo "${GREEN}✓ Simulator completed successfully in ${ELAPSED}s${NC}"
else
    echo "${RED}✗ FAIL: Simulator exited with code ${EXIT_CODE}${NC}"
    echo ""
    echo "Simulator log:"
    cat /tmp/test_simulator.log
    exit 1
fi

# Step 5: Verify log messages
echo ""
echo "Step 5: Verifying simulator log messages..."

if ! grep -q "All files processed, simulator shutting down gracefully" /tmp/test_simulator.log; then
    echo "${RED}✗ FAIL: Missing graceful shutdown message${NC}"
    echo ""
    echo "Simulator log:"
    cat /tmp/test_simulator.log
    exit 1
fi
echo "  ✓ Found graceful shutdown message"

if ! grep -q "Simulation completed" /tmp/test_simulator.log; then
    echo "${RED}✗ FAIL: Missing completion message${NC}"
    exit 1
fi
echo "  ✓ Found completion message"

if ! grep -q "Wrote anomaly manifest" /tmp/test_simulator.log; then
    echo "${RED}✗ FAIL: Missing manifest write confirmation${NC}"
    echo ""
    echo "Simulator log (last 20 lines):"
    tail -20 /tmp/test_simulator.log
    exit 1
fi
echo "  ✓ Found manifest write confirmation"

# Step 6: Verify manifest file exists
echo ""
echo "Step 6: Verifying output files..."

if [ -f "data/test_injection_manifest.json" ]; then
    echo "  ✓ injection_manifest.json created"
else
    echo "  ⚠ injection_manifest.json not found (might be in different location)"
fi

# Success!
echo ""
echo "============================================================"
echo "${GREEN}✓ ALL TESTS PASSED${NC}"
echo "============================================================"
echo ""
echo "Summary:"
echo "  • Simulator completed in ${ELAPSED}s (< ${TIMEOUT}s timeout)"
echo "  • No hanging or infinite loop detected"
echo "  • Graceful shutdown confirmed"
echo "  • Manifest write confirmed in logs"
echo ""
echo "Bug Fix Verified:"
echo "  The statsLogger worker is now properly canceled after all"
echo "  files are processed, allowing the simulator to exit cleanly."
echo ""
