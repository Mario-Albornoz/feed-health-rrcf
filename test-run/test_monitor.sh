#!/bin/bash
# Test monitoring script functionality

set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

echo "Testing Monitor Script Functionality"
echo "====================================="
echo ""

# Clean start
echo "1. Stopping any running components..."
make stop-all > /dev/null 2>&1
pkill -f monitor_pipeline 2>/dev/null || true
rm -f logs/monitor.log
sleep 2

# Start components
echo "2. Starting feed-handler..."
make run-handler > /dev/null 2>&1
sleep 3

echo "3. Starting simulator..."
make run-simulator > /dev/null 2>&1
sleep 3

# Verify processes are running
echo "4. Verifying processes are running..."
if [ -f .pids/handler.pid ] && kill -0 $(cat .pids/handler.pid) 2>/dev/null; then
    echo "   ✓ Handler is running (PID: $(cat .pids/handler.pid))"
else
    echo "   ✗ Handler is NOT running"
    exit 1
fi

if [ -f .pids/simulator.pid ] && kill -0 $(cat .pids/simulator.pid) 2>/dev/null; then
    echo "   ✓ Simulator is running (PID: $(cat .pids/simulator.pid))"
else
    echo "   ✗ Simulator is NOT running"
    exit 1
fi

# Start monitor
echo ""
echo "5. Starting monitor script..."
./scripts/monitor_pipeline.sh > /dev/null 2>&1 &
MONITOR_PID=$!
echo "   Monitor started with PID: $MONITOR_PID"

# Let it monitor for 25 seconds
echo ""
echo "6. Monitoring for 25 seconds..."
for i in {1..5}; do
    sleep 5
    echo "   - $((i*5))s: Processes still running..."
    if [ -f .pids/handler.pid ] && kill -0 $(cat .pids/handler.pid) 2>/dev/null; then
        echo "     ✓ Handler alive (PID: $(cat .pids/handler.pid))"
    else
        echo "     ✗ Handler died!"
    fi
    if [ -f .pids/simulator.pid ] && kill -0 $(cat .pids/simulator.pid) 2>/dev/null; then
        echo "     ✓ Simulator alive (PID: $(cat .pids/simulator.pid))"
    else
        echo "     ✗ Simulator died!"
    fi
done

# Stop monitor
echo ""
echo "7. Stopping monitor..."
kill $MONITOR_PID 2>/dev/null || true
sleep 1

# Check monitor log
echo ""
echo "8. Checking monitor log..."
if [ -f logs/monitor.log ]; then
    echo "   ✓ Monitor log exists"
    echo ""
    echo "Monitor Log Contents:"
    echo "===================="
    cat logs/monitor.log
    echo ""
    echo "===================="
    echo ""
    
    # Check for errors
    error_count=$(grep -c "ERROR:" logs/monitor.log 2>/dev/null || echo "0")
    if [ "$error_count" -eq 0 ]; then
        echo "   ✓ No errors detected in monitoring"
    else
        echo "   ✗ $error_count errors found in monitoring"
    fi
    
    # Check if it detected running processes
    if grep -q "CPU:" logs/monitor.log; then
        echo "   ✓ Monitor successfully captured process stats"
    else
        echo "   ✗ Monitor did not capture process stats"
    fi
else
    echo "   ✗ Monitor log NOT found"
fi

# Cleanup
echo ""
echo "9. Cleaning up..."
make stop-all > /dev/null 2>&1

echo ""
echo "====================================="
echo "Monitor Test Complete!"
echo "====================================="
