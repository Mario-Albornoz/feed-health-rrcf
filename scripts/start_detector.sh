#!/bin/bash

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT/rrcf-detector"

COLLECTOR_PID=0
echo $COLLECTOR_PID > "$PROJECT_ROOT/.pids/detector-collector.pid"

nohup "$PROJECT_ROOT/scripts/run_detector_wrapper.sh" < /dev/null > "$PROJECT_ROOT/logs/detector-multi.log" 2>&1 &
MULTI_PID=$!

echo $MULTI_PID > "$PROJECT_ROOT/.pids/detector-multi.pid"

sleep 2
if kill -0 $MULTI_PID 2>/dev/null; then
    echo "$COLLECTOR_PID $MULTI_PID"
    exit 0
else
    echo "Failed to start" >&2
    exit 1
fi
