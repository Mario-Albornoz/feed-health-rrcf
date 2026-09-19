# CPU Monitoring & Diagnostics Guide

## Overview

Enhanced monitoring system to detect CPU pressure, thermal throttling, and process kills due to resource constraints.

---

## Enhanced Features in `monitor_pipeline.sh`

### 1. **CPU Spike Detection**
Tracks per-process CPU usage over time and warns when sustained high usage is detected.

**Detects**:
- CPU usage > 150% (multi-core saturation)
- Consecutive high-CPU intervals
- Stores last known CPU usage before process death

**Output Example**:
```
[2026-09-19 01:30:45] WARN: Detector-Multi CPU spike: 287.5% (spike #5)
```

---

### 2. **System-Wide CPU Monitoring**

**Metrics Collected**:
- CPU usage breakdown (user/system/idle)
- Load average (1min, 5min, 15min)
- Core count and load percentage
- High load warnings (> 80% capacity)

**Output Example**:
```
[2026-09-19 01:30:00] System Resources:
  CPU: 45.2% (user: 38.1%, sys: 7.1%, idle: 54.8%)
  Load Average: 6.2 4.8 3.1 (8 cores available)
  ✓ Normal load: 77.5% of capacity
```

---

### 3. **Thermal Throttling Detection**

**Monitors**:
- CPU scheduler limits (macOS thermal management)
- Warns when CPU is thermally throttled
- Logs throttling state at process death

**Output Example**:
```
[2026-09-19 01:30:00] WARN: CPU thermal throttling detected: 75%
```

**What This Means**:
- CPU is running hot
- Clock speed reduced to prevent overheating
- Performance degraded by ~25% in this example

---

### 4. **Enhanced Process Death Analysis**

When a process dies, the monitor now checks:

#### CPU-Related Kills
```bash
# Searches system logs for:
- CPU watchdog events
- Resource limit violations
- Runaway process terminations
```

#### Diagnostic Snapshot
Logs collected at death:
- Last CPU usage before death
- Number of CPU spikes
- System load at time of death
- Thermal throttling status
- Recent system logs for kill signals

**Output Example**:
```
[2026-09-19 01:35:12] ERROR: Detector-Multi process (PID: 12345) has died!
  Last CPU usage before death: 312.4%
  CPU spikes detected: 8 consecutive high-CPU intervals
  System load at death: 7.8 (8 cores)
  CPU was thermally throttled at death: 65%
  Kill reason: signal 9 (SIGKILL) - resource exhaustion
```

---

### 5. **Additional Monitoring**

**Disk I/O**:
- Monitors disk utilization
- High I/O can cause CPU wait states

**Memory Pressure**:
- Tracks macOS memory pressure levels
- Warns when memory pressure is elevated
- Links memory issues to potential CPU impact

**Thread Count**:
- Tracks number of threads per process
- Helps identify thread explosion issues

---

## New Tool: `cpu_diagnostics.sh`

Standalone diagnostic tool for CPU health checks.

### Basic Usage

**One-Time Snapshot**:
```bash
./scripts/cpu_diagnostics.sh
```

**Continuous Monitoring**:
```bash
./scripts/cpu_diagnostics.sh --watch
```

---

### What It Reports

#### 1. Current CPU Status
- Core count and frequency
- Current usage (user/system/idle)
- Load average and capacity percentage
- Warnings for high load

#### 2. Thermal & Power Status
- CPU throttling state
- Battery status (laptop)
- Sleep prevention status

#### 3. Top CPU Consumers
- Top 10 processes by CPU usage
- Useful for finding resource hogs

#### 4. Pipeline Process Status
- Status of all pipeline components
- CPU/memory/thread usage per process
- Uptime for each process

#### 5. Recent Process Terminations
- Scans last 10 minutes of system logs
- Identifies process kills
- Highlights CPU/resource-related kills

#### 6. Memory Pressure
- Current memory pressure level
- Memory breakdown (wired/active/free)
- Warnings if memory is constrained

#### 7. Disk I/O
- Samples disk utilization
- Warns if disk is bottleneck

---

## Example Output

```bash
$ ./scripts/cpu_diagnostics.sh

═══════════════════════════════════════════════
  CPU Diagnostics - 2026-09-19 01:30:00
═══════════════════════════════════════════════

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Current CPU Status
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  CPU Cores: 8 @ 3.20 GHz
  Usage: User 38.1% | System 7.1% | Idle 54.8%
  Load Avg: 3.2 2.8 2.1
  ✓ Normal load: 40.0% of capacity

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Thermal & Power Status
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  CPU Throttling: None (100%)
  ✓ System sleep prevented (good for long-running tasks)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Pipeline Process Status
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✓ handler (PID: 12340)
    CPU: 42.3% | Memory: 1.2% | Threads: 12 | Uptime: 05:23
  ✓ detector-multi (PID: 12341)
    CPU: 287.5% | Memory: 3.8% | Threads: 24 | Uptime: 05:22
    ⚠ High CPU usage

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Recent Process Terminations (Last 10 Minutes)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✓ No recent terminations detected

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Memory Pressure
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✓ Normal (level 1)
  Total: 16.0GB | Wired: 3.2GB | Active: 8.1GB | Free: 4.7GB

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Disk I/O (Can Cause CPU Wait)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Sampling I/O for 2 seconds...
  disk0   35.2 MB/s   12.1 MB/s   2345   1234   45%

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Diagnostics complete!
Run with --watch flag for continuous monitoring
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Common Scenarios & Diagnosis

### Scenario 1: Process Killed by System

**Symptoms**:
```
[ERROR] Detector-Multi process (PID: 12345) has died!
  CPU spikes detected: 15 consecutive high-CPU intervals
  Kill reason: signal 9 (SIGKILL)
```

**Diagnosis**:
- Process was using excessive CPU
- System watchdog killed it (runaway process protection)
- May also happen due to OOM (Out of Memory)

**Solutions**:
- Reduce workload (smaller dataset, slower replay)
- Optimize model algorithms
- Add CPU throttling in code

---

### Scenario 2: Thermal Throttling

**Symptoms**:
```
[WARN] CPU thermal throttling detected: 65%
```

**Diagnosis**:
- CPU is overheating
- Clock speed reduced by 35%
- Performance degraded

**Solutions**:
- Improve cooling (clean fans, laptop cooling pad)
- Reduce workload intensity
- Run at night when ambient temperature is lower
- Close other applications

---

### Scenario 3: High Load, No Kills

**Symptoms**:
```
[WARN] High CPU load detected: 7.8 (threshold: 6.4)
```

**Diagnosis**:
- System is busy but stable
- All processes running normally

**Action**:
- Monitor for sustained high load
- If load stays high for > 10 minutes, consider reducing workload
- Check `cpu_diagnostics.sh` for top CPU consumers

---

### Scenario 4: Process Slow but Not Killed

**Symptoms**:
- Pipeline takes much longer than expected
- No kills detected
- CPU usage seems low

**Check**:
1. **Thermal throttling**: `cpu_diagnostics.sh` → Thermal status
2. **Disk I/O bottleneck**: `cpu_diagnostics.sh` → Disk I/O section
3. **Memory swapping**: Check memory pressure level

---

## Integration with Pipeline

### Automatic Monitoring

When you run:
```bash
make run-all
```

The monitor automatically starts and logs to `logs/monitor.log`.

### Check Monitor Logs

```bash
# View monitor output
tail -f logs/monitor.log

# Search for CPU issues
grep -i "cpu" logs/monitor.log | grep -i "warn\|error"

# Check for process deaths
grep "died" logs/monitor.log
```

---

## Tips for Long-Running Experiments

### 1. Prevent System Sleep
```bash
# Keep system awake during experiment
caffeinate -i make thesis-full
```

### 2. Monitor in Real-Time
```bash
# Terminal 1: Run pipeline
make run-all

# Terminal 2: Watch diagnostics
./scripts/cpu_diagnostics.sh --watch
```

### 3. Check Before Starting
```bash
# Verify system health before experiment
./scripts/cpu_diagnostics.sh

# Look for:
# - CPU throttling = 100% (no throttling)
# - Memory pressure = level 1 (normal)
# - Load < 50% of capacity
```

### 4. Post-Mortem Analysis
```bash
# After a failure, check:
tail -100 logs/monitor.log      # Monitor diagnostics
./scripts/cpu_diagnostics.sh    # Current system state
grep "died" logs/monitor.log    # Process deaths
```

---

## Advanced: Continuous Logging

For very long experiments, enable continuous CPU logging:

```bash
# Log CPU stats every 30 seconds
while true; do
    echo "=== $(date) ===" >> logs/cpu_history.log
    top -l 1 -n 5 -o cpu >> logs/cpu_history.log
    sleep 30
done &

# Save the PID to kill later
echo $! > .pids/cpu_logger.pid
```

---

## Interpreting CPU Usage

### Normal Ranges

| Component | Expected CPU | Normal Threads | Notes |
|-----------|--------------|----------------|-------|
| Simulator | 50-100% | 4-8 | Single-threaded, may use 1 core fully |
| Handler | 30-80% | 10-15 | Multi-threaded Go |
| RRCF Detector | 100-200% | 8-12 | Uses 2-4 cores |
| Z-Score | 50-100% | 4-6 | Lighter computation |
| IsoForest | 150-300% | 8-16 | Heavy during training |
| HalfSpace | 80-150% | 6-10 | Moderate computation |

### Concerning Signs

- **Single process > 400% CPU**: Possible runaway/bug
- **System load > cores * 2**: System overloaded
- **CPU usage < 10% + slow progress**: I/O bottleneck or sleeping
- **Thermal throttling < 80%**: Performance severely degraded

---

## macOS-Specific Notes

### CPU Pressure Stalls

macOS may pause processes when:
1. **Thermal limits** exceeded
2. **Power management** on battery
3. **Background processes** take priority
4. **App Nap** enabled (should be disabled by pipeline)

### System Logs

For detailed analysis:
```bash
# View system logs for process kills
sudo dmesg | grep -i "kill\|term"

# Check Console.app for crash reports
open /Applications/Utilities/Console.app
```

### Activity Monitor

For GUI monitoring:
```bash
open -a "Activity Monitor"

# Sort by:
# - CPU% (descending)
# - Filter by "python" or "simulator"
```

---

## Troubleshooting Commands

```bash
# Check if CPU is throttled
pmset -g thermlog | grep CPU_Scheduler_Limit

# Check system load
uptime

# Check process CPU usage
ps aux | grep -E "python|simulator|handler" | sort -k3 -rn

# Check kernel messages (may require sudo)
sudo dmesg | tail -50

# Check for OOM kills
log show --predicate 'eventMessage contains "memory" AND eventMessage contains "kill"' --last 30m

# Check CPU frequency
sysctl hw.cpufrequency hw.cpufrequency_max
```

---

## Summary

### What's New
✅ CPU spike detection per process  
✅ Thermal throttling monitoring  
✅ Enhanced process death analysis  
✅ System-wide CPU load tracking  
✅ Disk I/O bottleneck detection  
✅ Standalone diagnostics tool  

### How to Use
1. **Automatic**: Monitoring runs when you use `make run-all`
2. **Manual Check**: Run `./scripts/cpu_diagnostics.sh`
3. **Watch Mode**: Run `./scripts/cpu_diagnostics.sh --watch`
4. **Post-Mortem**: Check `logs/monitor.log` after failures

### Key Files
- `scripts/monitor_pipeline.sh` - Enhanced monitoring script
- `scripts/cpu_diagnostics.sh` - Diagnostic tool
- `logs/monitor.log` - Monitor output
- `logs/*.log` - Component-specific logs
