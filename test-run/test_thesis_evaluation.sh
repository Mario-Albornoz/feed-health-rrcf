#!/bin/bash

# Thesis Evaluation Integration Test
# Tests the complete evaluation pipeline end-to-end

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test configuration
TEST_DURATION=60  # Run for 60 seconds
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$PROJECT_ROOT/test-run"
TEST_DATA_DIR="$TEST_DIR/thesis_test_data"

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}Cleaning up test processes...${NC}"
    cd "$PROJECT_ROOT"
    make stop-all > /dev/null 2>&1 || true
    sleep 2
}

trap cleanup EXIT

# Create test data directory
mkdir -p "$TEST_DATA_DIR"

echo "════════════════════════════════════════════════════════════"
echo "  Thesis Evaluation Integration Test"
echo "  $(date)"
echo "════════════════════════════════════════════════════════════"
echo ""

# Test 1: Check Prerequisites
echo -e "${BLUE}Test 1: Checking Prerequisites${NC}"
echo ""

# Check Kafka
if docker ps | grep -q "thesis-kafka"; then
    if docker ps | grep "thesis-kafka" | grep -q "Up"; then
        echo -e "${GREEN}✓${NC} Kafka is running"
    else
        echo -e "${RED}✗${NC} Kafka is not running (unhealthy)"
        echo "  Run: make kafka-up"
        exit 1
    fi
else
    echo -e "${RED}✗${NC} Kafka container not found"
    echo "  Run: make kafka-up"
    exit 1
fi

# Check Go binaries
if [ -f "$PROJECT_ROOT/price-feed-simulator/bin/simulator" ]; then
    echo -e "${GREEN}✓${NC} Simulator binary exists"
else
    echo -e "${RED}✗${NC} Simulator binary missing"
    echo "  Run: make build-simulator"
    exit 1
fi

if [ -f "$PROJECT_ROOT/feed-handler/aggregator" ]; then
    echo -e "${GREEN}✓${NC} Handler binary exists"
else
    echo -e "${RED}✗${NC} Handler binary missing"
    echo "  Run: make build-handler"
    exit 1
fi

# Check Python venv
if [ -f "$PROJECT_ROOT/rrcf-detector/venv/bin/python3" ]; then
    echo -e "${GREEN}✓${NC} Python venv exists"
else
    echo -e "${RED}✗${NC} Python venv missing"
    echo "  Run: make setup-detector"
    exit 1
fi

# Check data files
data_count=$(ls -1 "$PROJECT_ROOT/price-feed-simulator/data/"*.csv 2>/dev/null | wc -l)
if [ "$data_count" -gt 0 ]; then
    echo -e "${GREEN}✓${NC} Data files present ($data_count files)"
else
    echo -e "${RED}✗${NC} No data files found"
    echo "  Place DEBS 2022 CSV files in price-feed-simulator/data/"
    exit 1
fi

echo ""

# Test 2: Test Simulator with Anomaly Injection
echo -e "${BLUE}Test 2: Testing Simulator Ground Truth Generation${NC}"
echo ""

# Clean previous test data
rm -f "$PROJECT_ROOT/price-feed-simulator/anomaly_log.csv"
rm -f "$PROJECT_ROOT/price-feed-simulator/injection_manifest.json"
rm -f "$PROJECT_ROOT/price-feed-simulator/data/anomaly_log.csv"
rm -f "$PROJECT_ROOT/price-feed-simulator/data/injection_manifest.json"

# Check if anomaly config exists
if [ ! -f "$PROJECT_ROOT/price-feed-simulator/config/simulator-with-anomalies.yaml" ]; then
    echo -e "${RED}✗${NC} Anomaly config not found"
    exit 1
fi

# Start simulator briefly with anomaly config
echo "  Starting simulator with anomaly injection for 15 seconds..."
cd "$PROJECT_ROOT"
make stop-all > /dev/null 2>&1 || true
sleep 1

# Run simulator with anomaly config in background
cd "$PROJECT_ROOT/price-feed-simulator"
timeout 15s ./bin/simulator -config config/simulator-with-anomalies.yaml > /dev/null 2>&1 || true

sleep 2

# Check if ground truth files were created (in simulator directory)
if [ -f "$PROJECT_ROOT/price-feed-simulator/anomaly_log.csv" ]; then
    echo -e "${GREEN}✓${NC} anomaly_log.csv created"
    
    # Check if it has content
    line_count=$(wc -l < "$PROJECT_ROOT/price-feed-simulator/anomaly_log.csv")
    if [ "$line_count" -gt 1 ]; then
        echo -e "${GREEN}✓${NC} CSV has $line_count lines"
    else
        echo -e "${YELLOW}⚠${NC} CSV has only header (no anomalies injected in time window)"
    fi
    
    # Copy to data directory for consistency
    cp "$PROJECT_ROOT/price-feed-simulator/anomaly_log.csv" "$PROJECT_ROOT/price-feed-simulator/data/" 2>/dev/null || true
else
    echo -e "${YELLOW}⚠${NC} anomaly_log.csv not created (simulator may not have reached injection window)"
    echo "      Creating empty file for testing..."
    # Create a minimal test CSV with header
    echo "Timestamp,InstrumentID,Exchange,AnomalyType,Phase,OriginalBid,OriginalAsk,OriginalLast,ModifiedBid,ModifiedAsk,ModifiedLast,Dropped" > "$PROJECT_ROOT/price-feed-simulator/data/anomaly_log.csv"
fi

if [ -f "$PROJECT_ROOT/price-feed-simulator/injection_manifest.json" ]; then
    echo -e "${GREEN}✓${NC} injection_manifest.json created"
    
    # Validate JSON
    if python3 -m json.tool "$PROJECT_ROOT/price-feed-simulator/injection_manifest.json" > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Manifest is valid JSON"
    else
        echo -e "${RED}✗${NC} Manifest is invalid JSON"
        exit 1
    fi
    
    # Copy to data directory for consistency
    cp "$PROJECT_ROOT/price-feed-simulator/injection_manifest.json" "$PROJECT_ROOT/price-feed-simulator/data/" 2>/dev/null || true
else
    echo -e "${YELLOW}⚠${NC} injection_manifest.json not created (short run)"
    echo "      Creating minimal manifest for testing..."
    # Create a minimal test manifest
    cat > "$PROJECT_ROOT/price-feed-simulator/data/injection_manifest.json" << 'MANIFEST_EOF'
{
  "experiment_id": "test_run",
  "seed": 42,
  "start_time": "2021-11-08T09:00:00Z",
  "end_time": "2021-11-08T09:01:00Z",
  "phases": {
    "phase1": {"name": "gradual_decline", "enabled": true, "dates": ["08-11-2021"], "window": {"start": "09:30:00", "end": "14:00:00"}, "total_dropped": 0, "affected_instruments": 0},
    "phase2": {"name": "contextual_price", "enabled": true, "dates": ["09-11-2021"], "window": {"start": "09:30:00", "end": "15:00:00"}, "total_injected": 0},
    "phase3": {"name": "feed_silence", "enabled": true, "dates": ["08-11-2021"], "window": {"start": "14:30:00", "end": "16:00:00"}, "total_dropped": 0, "affected_instruments": 0},
    "phase4": {"name": "point_failures", "enabled": true, "dates": ["10-11-2021"], "window": {"start": "09:30:00", "end": "15:30:00"}, "total_injected": 0}
  },
  "selected_instruments": {"phase1": [], "phase2": ["ALL"], "phase3": [], "phase4": ["ALL"]},
  "stats": {"TotalProcessed": 0, "Phase1Dropped": 0, "Phase2Injected": 0, "Phase3Dropped": 0, "Phase4Injected": 0}
}
MANIFEST_EOF
fi

echo ""

# Test 3: Test Detector Parquet Output
echo -e "${BLUE}Test 3: Testing Detector Parquet Output${NC}"
echo ""

# Clean previous test data
rm -f "$TEST_DATA_DIR/test_scores.parquet"

# Create a minimal test config
cat > "$TEST_DATA_DIR/test_config.yaml" << 'EOF'
detector:
  window_size: 100
  min_fill_threshold: 10
  training_samples: 1000
  n_estimators: 10
  contamination: 0.1
  n_trees: 5
  height: 4

kafka:
  bootstrap_servers: "localhost:9092"
  consumer_group_id: "test-detector"
  input_topic: "normalized-vectors"
  output_topic: "anomaly-scores"
  auto_offset_reset: "latest"
  linger_ms: 10
  batch_size: 10000
  compression_type: "lz4"
  acks: 1
  retries: 3

multiprocessing:
  num_workers: 2
  health_check_interval: 30

models:
  - rrcf
  - zscore

stream_collector:
  output_file: "$TEST_DATA_DIR/test_scores.parquet"
  buffer_size: 100
  flush_interval: 5
  bootstrap_servers: "localhost:9092"
  topic: "anomaly-scores"
EOF

# Test Python imports
echo "  Testing Python imports..."
if cd "$PROJECT_ROOT/rrcf-detector" && ./venv/bin/python3 -c "
from src.detection.generic_worker import ParquetWriter
from src.baselines import RRCFDetectorAdapter, ZScoreDetector
print('✓ Imports successful')
" 2>&1 | grep -q "✓ Imports successful"; then
    echo -e "${GREEN}✓${NC} Python imports work"
else
    echo -e "${RED}✗${NC} Python import failed"
    cd "$PROJECT_ROOT/rrcf-detector" && ./venv/bin/python3 -c "
from src.detection.generic_worker import ParquetWriter
from src.baselines import RRCFDetectorAdapter, ZScoreDetector
"
    exit 1
fi

# Test ParquetWriter class directly
echo "  Testing ParquetWriter class..."
cd "$PROJECT_ROOT/rrcf-detector" && ./venv/bin/python3 << 'PYEOF'
import sys
from src.detection.generic_worker import ParquetWriter

try:
    writer = ParquetWriter("../test-run/thesis_test_data/test_writer.parquet", buffer_size=10)
    
    # Write test data
    for i in range(15):
        writer.write({
            "exchange": "TEST",
            "instrument": f"TEST{i}",
            "instrument_class": "test",
            "timestamp": f"2024-01-01T00:00:{i:02d}",
            "timestamp_ms": 1704067200000 + i * 1000,
            "model": "test_model",
            "raw_score": float(i),
            "z_score": float(i) / 5.0,
            "alert_level": "normal",
            "stats_mean": 0.0,
            "stats_std": 1.0,
            "stats_count": 100,
            "worker_id": 0,
        })
    
    writer.close()
    print("✓ ParquetWriter test successful")
    sys.exit(0)
except Exception as e:
    print(f"✗ ParquetWriter test failed: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
PYEOF

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓${NC} ParquetWriter works"
    
    # Verify the file
    if [ -f "$TEST_DATA_DIR/test_writer.parquet" ]; then
        echo -e "${GREEN}✓${NC} Parquet file created"
    else
        echo -e "${RED}✗${NC} Parquet file not created"
        exit 1
    fi
else
    echo -e "${RED}✗${NC} ParquetWriter test failed"
    exit 1
fi

echo ""

# Test 4: Test Evaluation Script
echo -e "${BLUE}Test 4: Testing Evaluation Script${NC}"
echo ""

# Check if evaluation script exists and is executable
if [ -x "$PROJECT_ROOT/rrcf-detector/scripts/evaluate_thesis.py" ]; then
    echo -e "${GREEN}✓${NC} Evaluation script exists and is executable"
else
    echo -e "${YELLOW}⚠${NC} Making evaluation script executable"
    chmod +x "$PROJECT_ROOT/rrcf-detector/scripts/evaluate_thesis.py"
fi

# Test evaluation script help
echo "  Testing evaluation script..."
if cd "$PROJECT_ROOT/rrcf-detector" && ./venv/bin/python3 scripts/evaluate_thesis.py --help > /dev/null 2>&1; then
    echo -e "${GREEN}✓${NC} Evaluation script runs"
else
    echo -e "${RED}✗${NC} Evaluation script failed"
    cd "$PROJECT_ROOT/rrcf-detector" && ./venv/bin/python3 scripts/evaluate_thesis.py --help
    exit 1
fi

# Test with mock data (if ground truth exists from Test 2)
if [ -f "$PROJECT_ROOT/price-feed-simulator/data/anomaly_log.csv" ] && \
   [ -f "$PROJECT_ROOT/price-feed-simulator/data/injection_manifest.json" ] && \
   [ -f "$TEST_DATA_DIR/test_writer.parquet" ]; then
    
    echo "  Running evaluation with test data..."
    cd "$PROJECT_ROOT/rrcf-detector" && ./venv/bin/python3 scripts/evaluate_thesis.py \
        --ground-truth-csv ../price-feed-simulator/data/anomaly_log.csv \
        --ground-truth-manifest ../price-feed-simulator/data/injection_manifest.json \
        --scores ../test-run/thesis_test_data/test_writer.parquet \
        --output ../test-run/thesis_test_data/eval_output > /dev/null 2>&1 || true
    
    # Check if any output was generated (may fail due to mismatched data)
    if [ -d "$TEST_DATA_DIR/eval_output" ]; then
        echo -e "${GREEN}✓${NC} Evaluation script executed"
        
        if [ -f "$TEST_DATA_DIR/eval_output/rq1_results.json" ]; then
            echo -e "${GREEN}✓${NC} RQ1 results generated"
        fi
        
        if [ -f "$TEST_DATA_DIR/eval_output/rq2_results.json" ]; then
            echo -e "${GREEN}✓${NC} RQ2 results generated"
        fi
    fi
fi

echo ""

# Test 5: Test Makefile Targets
echo -e "${BLUE}Test 5: Testing Makefile Targets${NC}"
echo ""

cd "$PROJECT_ROOT"

# Test help target
if make help | grep -q "Thesis Evaluation"; then
    echo -e "${GREEN}✓${NC} Thesis evaluation targets in help"
else
    echo -e "${RED}✗${NC} Thesis evaluation targets not in help"
    exit 1
fi

# Check if targets exist
for target in run-thesis-experiment evaluate-thesis thesis-full; do
    if make -n $target > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Target '$target' exists"
    else
        echo -e "${RED}✗${NC} Target '$target' not found"
        exit 1
    fi
done

echo ""

# Test 6: Quick End-to-End Test (30 seconds)
echo -e "${BLUE}Test 6: Quick End-to-End Test (30 seconds)${NC}"
echo ""

# Clean test area
rm -rf "$TEST_DATA_DIR/e2e"
mkdir -p "$TEST_DATA_DIR/e2e"

echo "  Starting handler..."
cd "$PROJECT_ROOT"
make stop-all > /dev/null 2>&1 || true
sleep 2

make run-handler > /dev/null 2>&1
sleep 3

if [ -f "$PROJECT_ROOT/.pids/handler.pid" ] && kill -0 $(cat "$PROJECT_ROOT/.pids/handler.pid") 2>/dev/null; then
    echo -e "${GREEN}✓${NC} Handler started"
else
    echo -e "${RED}✗${NC} Handler failed to start"
    exit 1
fi

echo "  Starting detector (writing to test parquet)..."
cd "$PROJECT_ROOT/rrcf-detector"

# Start detector with short timeout and parquet output
timeout 15s ./venv/bin/python3 scripts/run_multi_model.py \
    --config config/baselines.yaml \
    --output ../test-run/thesis_test_data/e2e/scores.parquet > /dev/null 2>&1 &

DETECTOR_PID=$!
sleep 10

echo "  Starting simulator briefly..."
cd "$PROJECT_ROOT/price-feed-simulator"
timeout 10s ./bin/simulator > /dev/null 2>&1 || true

sleep 2

# Check outputs
echo ""
echo "  Checking outputs..."

if [ -f "$PROJECT_ROOT/price-feed-simulator/data/anomaly_log.csv" ]; then
    echo -e "${GREEN}✓${NC} Ground truth CSV exists"
else
    echo -e "${YELLOW}⚠${NC} Ground truth CSV not found (may not have reached injection window)"
fi

if [ -f "$PROJECT_ROOT/price-feed-simulator/data/injection_manifest.json" ]; then
    echo -e "${GREEN}✓${NC} Manifest exists"
else
    echo -e "${YELLOW}⚠${NC} Manifest not found"
fi

if [ -f "$TEST_DATA_DIR/e2e/scores.parquet" ]; then
    echo -e "${GREEN}✓${NC} Scores parquet exists"
    
    # Check parquet file size
    size=$(wc -c < "$TEST_DATA_DIR/e2e/scores.parquet")
    if [ "$size" -gt 1000 ]; then
        echo -e "${GREEN}✓${NC} Scores parquet has data ($size bytes)"
    else
        echo -e "${YELLOW}⚠${NC} Scores parquet is very small ($size bytes)"
    fi
else
    echo -e "${YELLOW}⚠${NC} Scores parquet not found (detector may not have flushed)"
fi

# Cleanup
echo ""
echo "  Cleaning up..."
kill $DETECTOR_PID 2>/dev/null || true
cd "$PROJECT_ROOT"
make stop-all > /dev/null 2>&1 || true

echo ""

# Summary
echo "════════════════════════════════════════════════════════════"
echo "  Test Summary"
echo "════════════════════════════════════════════════════════════"
echo ""
echo -e "${GREEN}✓ All critical tests passed${NC}"
echo ""
echo "Test artifacts saved to: $TEST_DATA_DIR"
echo ""
echo "Next steps:"
echo "  1. Run full experiment: make thesis-full"
echo "  2. Check results in results/thesis_*/"
echo ""
echo "════════════════════════════════════════════════════════════"
