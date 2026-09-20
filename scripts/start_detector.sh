#!/bin/bash
# Start detector components and save PIDs

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT/rrcf-detector"

# For thesis evaluation, we only need run_multi_model.py
# It creates model-specific parquet files (scores_modelname.parquet)
# The stream_collector creates a single scores.parquet which:
# 1. Is redundant (duplicates data)
# 2. Gets corrupted on shutdown (no graceful close)
# 3. Causes evaluation failures

# NOTE: stream_collector.py is disabled for thesis runs.
# If you need it for other purposes, uncomment the lines below.

# Start collector (DISABLED for thesis)
# PYTHONPATH=. nohup venv/bin/python3 scripts/stream_collector.py --config config/baselines.yaml > "$PROJECT_ROOT/logs/detector-collector.log" 2>&1 &
# COLLECTOR_PID=$!
# echo $COLLECTOR_PID > "$PROJECT_ROOT/.pids/detector-collector.pid"
# sleep 2

COLLECTOR_PID=0
echo $COLLECTOR_PID > "$PROJECT_ROOT/.pids/detector-collector.pid"

# Start multi-model via wrapper script
nohup "$PROJECT_ROOT/scripts/run_detector_wrapper.sh" < /dev/null > "$PROJECT_ROOT/logs/detector-multi.log" 2>&1 &
MULTI_PID=$!

# Save PID
echo $MULTI_PID > "$PROJECT_ROOT/.pids/detector-multi.pid"

# Verify it started
sleep 2
if kill -0 $MULTI_PID 2>/dev/null; then
    echo "$COLLECTOR_PID $MULTI_PID"
    exit 0
else
    echo "Failed to start" >&2
    exit 1
fi
