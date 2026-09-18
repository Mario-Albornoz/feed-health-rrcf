#!/bin/bash
# Start detector components and save PIDs

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT/rrcf-detector"

# Start collector
PYTHONPATH=. nohup venv/bin/python3 scripts/stream_collector.py --config config/baselines.yaml > "$PROJECT_ROOT/logs/detector-collector.log" 2>&1 &
COLLECTOR_PID=$!
echo $COLLECTOR_PID > "$PROJECT_ROOT/.pids/detector-collector.pid"

# Wait a bit
sleep 2

# Start multi-model
PYTHONPATH=. nohup venv/bin/python3 scripts/run_multi_model.py --config config/baselines.yaml > "$PROJECT_ROOT/logs/detector-multi.log" 2>&1 &
MULTI_PID=$!
echo $MULTI_PID > "$PROJECT_ROOT/.pids/detector-multi.pid"

# Verify they started
sleep 1
if kill -0 $COLLECTOR_PID 2>/dev/null && kill -0 $MULTI_PID 2>/dev/null; then
    echo "$COLLECTOR_PID $MULTI_PID"
    exit 0
else
    echo "Failed to start" >&2
    exit 1
fi
