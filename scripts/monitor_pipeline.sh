#!/bin/bash
#
# Pipeline Monitor Script
# Monitors pipeline processes and logs diagnostic information about failures
#
# Usage: ./scripts/monitor_pipeline.sh
# Logs to: logs/monitor.log
#

# Setup
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_FILE="$PROJECT_ROOT/logs/monitor.log"
PIDS_DIR="$PROJECT_ROOT/.pids"
CHECK_INTERVAL=10  # seconds

# Color codes for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Initialize log file
mkdir -p "$(dirname "$LOG_FILE")"
echo "========================================" >> "$LOG_FILE"
echo "Pipeline Monitor Started: $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
echo "========================================" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE"
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $1" | tee -a "$LOG_FILE"
}

# CPU tracking arrays (for detecting spikes before kills)
# Using simple indexed arrays for bash 3.2 compatibility (macOS default)
LAST_CPU_HANDLER=""
LAST_CPU_DETECTOR_MULTI=""
LAST_CPU_DETECTOR_COLLECTOR=""
LAST_CPU_SIMULATOR=""
CPU_SPIKE_COUNT_HANDLER=0
CPU_SPIKE_COUNT_DETECTOR_MULTI=0
CPU_SPIKE_COUNT_DETECTOR_COLLECTOR=0
CPU_SPIKE_COUNT_SIMULATOR=0

# Function to get process info
get_process_info() {
    local pid=$1
    local name=$2
    
    if kill -0 "$pid" 2>/dev/null; then
        # Process is running - get stats
        local cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ')
        local mem=$(ps -p "$pid" -o %mem= 2>/dev/null | tr -d ' ')
        local rss=$(ps -p "$pid" -o rss= 2>/dev/null | tr -d ' ')
        local vsz=$(ps -p "$pid" -o vsz= 2>/dev/null | tr -d ' ')
        local time=$(ps -p "$pid" -o time= 2>/dev/null | tr -d ' ')
        local threads=$(ps -M -p "$pid" 2>/dev/null | wc -l | tr -d ' ')
        
        # Track CPU spikes (> 150% = using multiple cores heavily)
        if [ -n "$cpu" ] && awk "BEGIN {exit !($cpu > 150)}"; then
            case "$name" in
                "Handler")
                    LAST_CPU_HANDLER=$cpu
                    CPU_SPIKE_COUNT_HANDLER=$((CPU_SPIKE_COUNT_HANDLER + 1))
                    if [ "$CPU_SPIKE_COUNT_HANDLER" -gt 3 ]; then
                        log_warn "$name CPU spike: ${cpu}% (spike #${CPU_SPIKE_COUNT_HANDLER})"
                    fi
                    ;;
                "Detector-Multi")
                    LAST_CPU_DETECTOR_MULTI=$cpu
                    CPU_SPIKE_COUNT_DETECTOR_MULTI=$((CPU_SPIKE_COUNT_DETECTOR_MULTI + 1))
                    if [ "$CPU_SPIKE_COUNT_DETECTOR_MULTI" -gt 3 ]; then
                        log_warn "$name CPU spike: ${cpu}% (spike #${CPU_SPIKE_COUNT_DETECTOR_MULTI})"
                    fi
                    ;;
                "Detector-Collector")
                    LAST_CPU_DETECTOR_COLLECTOR=$cpu
                    CPU_SPIKE_COUNT_DETECTOR_COLLECTOR=$((CPU_SPIKE_COUNT_DETECTOR_COLLECTOR + 1))
                    if [ "$CPU_SPIKE_COUNT_DETECTOR_COLLECTOR" -gt 3 ]; then
                        log_warn "$name CPU spike: ${cpu}% (spike #${CPU_SPIKE_COUNT_DETECTOR_COLLECTOR})"
                    fi
                    ;;
                "Simulator")
                    LAST_CPU_SIMULATOR=$cpu
                    CPU_SPIKE_COUNT_SIMULATOR=$((CPU_SPIKE_COUNT_SIMULATOR + 1))
                    if [ "$CPU_SPIKE_COUNT_SIMULATOR" -gt 3 ]; then
                        log_warn "$name CPU spike: ${cpu}% (spike #${CPU_SPIKE_COUNT_SIMULATOR})"
                    fi
                    ;;
            esac
        else
            case "$name" in
                "Handler") CPU_SPIKE_COUNT_HANDLER=0 ;;
                "Detector-Multi") CPU_SPIKE_COUNT_DETECTOR_MULTI=0 ;;
                "Detector-Collector") CPU_SPIKE_COUNT_DETECTOR_COLLECTOR=0 ;;
                "Simulator") CPU_SPIKE_COUNT_SIMULATOR=0 ;;
            esac
        fi
        
        echo "  $name (PID: $pid) - CPU: ${cpu}% | MEM: ${mem}% | RSS: ${rss}KB | Threads: ${threads} | TIME: ${time}"
    else
        echo "  $name (PID: $pid) - PROCESS NOT RUNNING"
        return 1
    fi
}

# Function to check system resources
check_system_resources() {
    log "System Resources:"
    
    # CPU Usage (system-wide)
    local cpu_user=$(top -l 1 -n 0 | grep "CPU usage" | awk '{print $3}' | tr -d '%')
    local cpu_sys=$(top -l 1 -n 0 | grep "CPU usage" | awk '{print $5}' | tr -d '%')
    local cpu_idle=$(top -l 1 -n 0 | grep "CPU usage" | awk '{print $7}' | tr -d '%')
    local cpu_total=$(echo "$cpu_user + $cpu_sys" | bc 2>/dev/null || echo "unknown")
    log "  CPU: ${cpu_total}% (user: ${cpu_user}%, sys: ${cpu_sys}%, idle: ${cpu_idle}%)"
    
    # CPU cores and load
    local ncpu=$(sysctl -n hw.ncpu)
    local load=$(sysctl -n vm.loadavg | awk '{print $2, $3, $4}')
    log "  Load Average: $load (${ncpu} cores available)"
    
    # Check if load is high (> 80% of cores sustained)
    local load_1min=$(echo "$load" | awk '{print $1}')
    local load_threshold=$(awk "BEGIN {printf \"%.1f\", $ncpu * 0.8}")
    if awk "BEGIN {exit !($load_1min > $load_threshold)}"; then
        log_warn "  High CPU load detected: $load_1min (threshold: $load_threshold)"
    fi
    
    # Memory
    local mem_total=$(sysctl -n hw.memsize | awk '{print $1/1024/1024/1024}')
    local mem_free=$(vm_stat | grep "Pages free" | awk '{print $3}' | tr -d '.' | awk '{print $1*4096/1024/1024/1024}')
    log "  Memory: ${mem_free}GB free / ${mem_total}GB total"
    
    # Check for memory pressure
    local mem_pressure=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo "unknown")
    log "  Memory Pressure: $mem_pressure"
    if [ "$mem_pressure" != "1" ] && [ "$mem_pressure" != "unknown" ]; then
        log_warn "  Elevated memory pressure detected (level: $mem_pressure)"
    fi
    
    # Thermal pressure (macOS specific - can cause CPU throttling)
    local thermal_level=$(pmset -g thermlog 2>/dev/null | grep "CPU_Scheduler_Limit" | awk '{print $3}' || echo "unknown")
    if [ "$thermal_level" != "unknown" ] && [ "$thermal_level" != "100" ]; then
        log_warn "  CPU thermal throttling detected: ${thermal_level}%"
    fi
    
    # Check power management
    local sleep_disabled=$(pmset -g assertions | grep -c "PreventUserIdleSystemSleep" || echo "0")
    log "  Sleep Prevention Active: $sleep_disabled assertions"
    
    # Disk I/O wait (can cause apparent CPU issues)
    local iostat_output=$(iostat -c 2 -w 1 2>/dev/null | tail -1)
    if [ -n "$iostat_output" ]; then
        local disk_util=$(echo "$iostat_output" | awk '{print $NF}')
        log "  Disk I/O: ${disk_util}% utilization"
    fi
    
    echo "" >> "$LOG_FILE"
}

# Function to check if process died and log reason
check_process_death() {
    local pid=$1
    local name=$2
    local pid_file=$3
    
    if [ ! -f "$pid_file" ]; then
        return 0  # PID file doesn't exist, process never started
    fi
    
    if ! kill -0 "$pid" 2>/dev/null; then
        log_error "$name process (PID: $pid) has died!"
        
        # Log last known CPU usage if we tracked it
        local last_cpu=""
        local spike_count=0
        case "$name" in
            "Handler")
                last_cpu="$LAST_CPU_HANDLER"
                spike_count=$CPU_SPIKE_COUNT_HANDLER
                ;;
            "Detector-Multi")
                last_cpu="$LAST_CPU_DETECTOR_MULTI"
                spike_count=$CPU_SPIKE_COUNT_DETECTOR_MULTI
                ;;
            "Detector-Collector")
                last_cpu="$LAST_CPU_DETECTOR_COLLECTOR"
                spike_count=$CPU_SPIKE_COUNT_DETECTOR_COLLECTOR
                ;;
            "Simulator")
                last_cpu="$LAST_CPU_SIMULATOR"
                spike_count=$CPU_SPIKE_COUNT_SIMULATOR
                ;;
        esac
        
        if [ -n "$last_cpu" ]; then
            log_error "  Last CPU usage before death: ${last_cpu}%"
            if [ "$spike_count" -gt 0 ]; then
                log_error "  CPU spikes detected: ${spike_count} consecutive high-CPU intervals"
            fi
        fi
        
        # Try to determine exit reason
        # Check system logs for kills
        local kill_reason=$(log show --predicate "processID == $pid" --last 5m --info 2>/dev/null | grep -i "kill\|signal\|term\|exit" | tail -1)
        
        if [ -n "$kill_reason" ]; then
            log_error "  Kill reason: $kill_reason"
        fi
        
        # Check for CPU-related kills (runaway process, watchdog, etc.)
        local cpu_kill=$(log show --predicate "processID == $pid" --last 5m 2>/dev/null | grep -i "cpu\|resource\|watchdog\|hang")
        if [ -n "$cpu_kill" ]; then
            log_error "  CPU/Resource-related kill detected:"
            echo "$cpu_kill" >> "$LOG_FILE"
        fi
        
        # Check for OOM killer
        local oom_check=$(log show --predicate 'eventMessage contains "memory" AND eventMessage contains "kill"' --last 5m 2>/dev/null | grep "$pid")
        if [ -n "$oom_check" ]; then
            log_error "  Possible OOM (Out of Memory) kill detected"
        fi
        
        # Check system load at time of death
        local load=$(sysctl -n vm.loadavg | awk '{print $2}')
        local ncpu=$(sysctl -n hw.ncpu)
        log_error "  System load at death: $load (${ncpu} cores)"
        
        # Check for thermal throttling at time of death
        local thermal=$(pmset -g thermlog 2>/dev/null | grep "CPU_Scheduler_Limit" | awk '{print $3}' || echo "unknown")
        if [ "$thermal" != "unknown" ] && [ "$thermal" != "100" ]; then
            log_error "  CPU was thermally throttled at death: ${thermal}%"
        fi
        
        # Check for sleep-related kills
        local sleep_check=$(pmset -g log | grep -i "sleep\|wake" | tail -5)
        if [ -n "$sleep_check" ]; then
            log_warn "  Recent sleep/wake events detected:"
            echo "$sleep_check" >> "$LOG_FILE"
        fi
        
        # Check last exit code if available
        log_error "  Check process-specific logs for more details"
        
        # Log diagnostic snapshot
        log_error "  Diagnostic snapshot:"
        log_error "    - Check 'logs/${name}.log' for process output"
        log_error "    - Check 'sudo dmesg' for kernel messages (may require sudo)"
        log_error "    - Check Console.app for system-level crash reports"
        
        return 1
    fi
    return 0
}

# Main monitoring loop
log "Starting monitoring loop (checking every ${CHECK_INTERVAL}s)"
log ""

iteration=0
while true; do
    iteration=$((iteration + 1))
    
    # Every 10th iteration (100s), log full status
    if [ $((iteration % 10)) -eq 0 ]; then
        log "=== Periodic Status Check ==="
        check_system_resources
    fi
    
    # Check handler
    if [ -f "$PIDS_DIR/handler.pid" ]; then
        handler_pid=$(cat "$PIDS_DIR/handler.pid")
        if ! get_process_info "$handler_pid" "Handler" >> "$LOG_FILE" 2>&1; then
            check_process_death "$handler_pid" "Handler" "$PIDS_DIR/handler.pid"
        fi
    fi
    
    # Check detector collector
    if [ -f "$PIDS_DIR/detector-collector.pid" ]; then
        collector_pid=$(cat "$PIDS_DIR/detector-collector.pid")
        if ! get_process_info "$collector_pid" "Detector-Collector" >> "$LOG_FILE" 2>&1; then
            check_process_death "$collector_pid" "Detector-Collector" "$PIDS_DIR/detector-collector.pid"
        fi
    fi
    
    # Check detector multi-model
    if [ -f "$PIDS_DIR/detector-multi.pid" ]; then
        multi_pid=$(cat "$PIDS_DIR/detector-multi.pid")
        if ! get_process_info "$multi_pid" "Detector-Multi" >> "$LOG_FILE" 2>&1; then
            check_process_death "$multi_pid" "Detector-Multi" "$PIDS_DIR/detector-multi.pid"
        fi
    fi
    
    # Check simulator (if running in background - usually foreground)
    if [ -f "$PIDS_DIR/simulator.pid" ]; then
        simulator_pid=$(cat "$PIDS_DIR/simulator.pid")
        if ! get_process_info "$simulator_pid" "Simulator" >> "$LOG_FILE" 2>&1; then
            check_process_death "$simulator_pid" "Simulator" "$PIDS_DIR/simulator.pid"
        fi
    fi
    
    sleep "$CHECK_INTERVAL"
done
