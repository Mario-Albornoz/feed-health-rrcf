#!/bin/bash
# Start handler and save PID

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT/feed-handler"

# Start the aggregator in background
nohup ./aggregator > "$PROJECT_ROOT/logs/handler.log" 2>&1 &
PID=$!

# Save PID
echo $PID > "$PROJECT_ROOT/.pids/handler.pid"

# Verify it started
sleep 1
if kill -0 $PID 2>/dev/null; then
    echo $PID
    exit 0
else
    echo "Failed to start" >&2
    exit 1
fi
