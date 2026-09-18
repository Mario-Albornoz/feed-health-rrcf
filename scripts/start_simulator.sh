#!/bin/bash
# Start simulator and save PID

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT/price-feed-simulator"

# Start the simulator in background
nohup ./bin/simulator > "$PROJECT_ROOT/logs/simulator.log" 2>&1 &
PID=$!

# Save PID
echo $PID > "$PROJECT_ROOT/.pids/simulator.pid"

# Verify it started
sleep 1
if kill -0 $PID 2>/dev/null; then
    echo $PID
    exit 0
else
    echo "Failed to start" >&2
    exit 1
fi
