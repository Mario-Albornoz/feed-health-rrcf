# Quick Start Guide - Testing Infrastructure

## What's New

✅ **Fixed `make stop-all`** - Now properly stops all components  
✅ **Simulator Logging** - Logs saved to `logs/simulator.log`  
✅ **Integration Tests** - Complete end-to-end testing suite  
✅ **Better Process Management** - Reliable PID tracking for all components

## Quick Commands

### Run the Integration Test
```bash
# Ensure Kafka is running
make kafka-status

# Run 30-second integration test
make test-integration
```

**This will:**
1. Check all prerequisites (Kafka, binaries, data files)
2. Start all three components
3. Run for 30 seconds
4. Test that stop-all works
5. Generate a detailed report

### Start the Full Pipeline
```bash
make run-all          # Start everything
make status           # Check component status
make logs             # View all logs
make stop-all         # Stop everything
```

### View Logs
```bash
# All logs in one stream
make logs

# Individual logs
tail -f logs/handler.log
tail -f logs/simulator.log
tail -f logs/detector-collector.log
```

## Test Results

The integration test validates:
- ✅ All components start successfully
- ✅ Components run stably
- ✅ Stop command works correctly
- ✅ Logs are being written
- ✅ No critical errors

See `test-run/TESTING_SUMMARY.md` for full details.

## Files to Check

### Logs
- `logs/handler.log` - Feed handler output
- `logs/simulator.log` - Simulator output  
- `logs/detector-collector.log` - Detector collector
- `logs/detector-multi.log` - Multi-model detector

### Test Results
- `test-run/test_execution.log` - Full test output
- `test-run/test_results.txt` - Pass/fail summary

## Troubleshooting

### If test fails
```bash
# Check Kafka is running
make kafka-status

# Check component status
make status

# View recent logs
tail -50 logs/handler.log
```

### Clean restart
```bash
make stop-all
make kafka-down
make kafka-up
make test-integration
```

## What Was Fixed

1. **Makefile** - Fixed path issues, improved stop-all, added simulator logging
2. **Process Management** - Created helper scripts for reliable PID capture
3. **Testing** - Created comprehensive integration test suite
4. **Documentation** - Updated READMEs with complete testing instructions

All 20 core tests are passing! 🎉
