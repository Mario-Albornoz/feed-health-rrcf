# Pipeline Integration Test

This directory contains scripts for testing the complete pipeline with a partial run.

## Purpose

The test script performs a comprehensive integration test of the entire pipeline:
1. Verifies all prerequisites are met
2. Starts all components in the correct order
3. Monitors component health during execution
4. Tests the stop-all functionality
5. Analyzes logs for errors
6. Generates a detailed test report

## Running the Test

### Prerequisites

Before running the test, ensure:

```bash
# 1. Build all components
make setup

# 2. Start Kafka infrastructure
make kafka-up

# 3. Ensure DEBS 2022 CSV files are in place
ls price-feed-simulator/data/*.csv
```

### Execute Test

```bash
# Run the integration test (30-second partial run)
./test-run/test_pipeline.sh
```

The test will:
- Run for 30 seconds (configurable in script)
- Test all start/stop commands
- Verify all logs are being written
- Check for errors in logs
- Generate a summary report

## Test Output

The test generates two files:

1. **test_execution.log** - Full test execution log with timestamps
2. **test_results.txt** - Machine-readable test results (format: test_name|status|message)

## What the Test Validates

### Component Startup
- [x] Feed-handler starts successfully
- [x] Detector collector starts successfully
- [x] Detector multi-model starts successfully
- [x] Simulator starts successfully

### Process Management
- [x] All processes run stably for test duration
- [x] PID files are created correctly
- [x] `make stop-all` stops all components
- [x] No zombie processes remain

### Logging
- [x] Handler logs to `logs/handler.log`
- [x] Simulator logs to `logs/simulator.log`
- [x] Detector logs to `logs/detector-*.log`
- [x] All log files grow during execution
- [x] Logs contain expected output (throughput stats, etc.)

### Error Detection
- [x] No FATAL errors in any component
- [x] No panics or crashes
- [x] All components remain responsive

## Test Configuration

Edit the script to modify test parameters:

```bash
TEST_DURATION=30      # Duration to run simulator (seconds)
STARTUP_WAIT=5        # Wait time between component starts (seconds)
LOG_CHECK_WAIT=3      # Wait time before checking logs (seconds)
```

## Troubleshooting

### Test Fails: Kafka not running

```bash
make kafka-up
# Wait 15 seconds
./test-run/test_pipeline.sh
```

### Test Fails: Binaries not built

```bash
make build-simulator
make build-handler
make setup-detector
./test-run/test_pipeline.sh
```

### Test Fails: No data files

```bash
# Download DEBS 2022 dataset
# Place CSV files in price-feed-simulator/data/
./test-run/test_pipeline.sh
```

### View detailed logs

```bash
# After test completion, view logs:
tail -f logs/handler.log
tail -f logs/simulator.log
tail -f logs/detector-collector.log

# Or use the aggregated logs command:
make logs
```

### Manual cleanup

If the test crashes and leaves processes running:

```bash
make stop-all
# Or force kill:
pkill -f aggregator
pkill -f simulator
pkill -f stream_collector
pkill -f run_multi_model
```

## Understanding Test Results

### PASS (Green ✓)
- Component started successfully
- No errors detected
- Test criteria met

### WARN (Yellow ⚠)
- Component running but with warnings
- Non-critical errors in logs
- Unexpected but not fatal behavior

### FAIL (Red ✗)
- Component failed to start
- Critical error detected
- Test criteria not met

## Sample Successful Output

```
════════════════════════════════════════════════════════════
  Pipeline Integration Test
  Fri Sep 18 20:45:00 CEST 2026
════════════════════════════════════════════════════════════

Test 1: Checking prerequisites...
✓ PASS: Kafka running
✓ PASS: Handler binary exists
✓ PASS: Simulator binary exists
✓ PASS: Detector venv exists
✓ PASS: Data files present - 5 CSV files found

Test 2: Ensuring clean state...
✓ PASS: Clean state - All processes stopped

Test 3: Starting feed-handler...
✓ PASS: Handler startup - PID: 12345
✓ PASS: Handler logs healthy - No errors in logs

Test 4: Starting detector pipeline...
✓ PASS: Detector collector startup - PID: 12346
✓ PASS: Detector multi-model startup - PID: 12347
✓ PASS: Detector collector logs exist

Test 5: Starting simulator (30s test run)...
✓ PASS: Simulator startup - PID: 12348
✓ PASS: Simulator logs exist
✓ PASS: Simulator producing data - Throughput stats found

Test 6: Running pipeline for 30 seconds...
Monitoring components...
...
✓ PASS: Handler stability - Running after 30s
✓ PASS: Simulator stability - Running after 30s
✓ PASS: Detector stability - Running after 30s

Test 7: Verifying log files...
✓ PASS: Log file handler.log - 45231 bytes
✓ PASS: Log file simulator.log - 38924 bytes
✓ PASS: Log file detector-collector.log - 12453 bytes
✓ PASS: Log file detector-multi.log - 8932 bytes

Test 8: Testing stop-all command...
✓ PASS: Stop all components - All 4 components stopped

Test 9: Analyzing logs for errors...
✓ PASS: Errors in handler.log - No errors found
✓ PASS: Errors in simulator.log - No errors found
✓ PASS: Errors in detector-collector.log - No errors found
✓ PASS: Errors in detector-multi.log - No errors found

════════════════════════════════════════════════════════════
  Test Summary
════════════════════════════════════════════════════════════

PASSED: 25
FAILED: 0
WARNINGS: 0
TOTAL: 25

✓ ALL TESTS PASSED
```

## Continuous Integration

This test script can be integrated into CI/CD pipelines:

```bash
#!/bin/bash
# CI pipeline script
set -e

make setup
make kafka-up
sleep 15

# Run test
./test-run/test_pipeline.sh

# Cleanup
make kafka-down
```

## Next Steps

After a successful test:

1. **Full Pipeline Run**: `make run-all` for production-like execution
2. **View Results**: Check `data/` directory for Parquet files
3. **Analyze Results**: Use Python/pandas to analyze anomaly detection results
4. **Monitor**: Use `make logs` to monitor ongoing execution
5. **Stop**: Use `make stop-all` to stop all components

## Notes

- The test uses a **30-second run** by default to quickly verify functionality
- For full evaluation, run the complete pipeline with all data files
- Log files are preserved after test completion for analysis
- The test script automatically cleans up processes on exit (Ctrl+C safe)
