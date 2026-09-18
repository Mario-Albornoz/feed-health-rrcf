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
        
        echo "  $name (PID: $pid) - CPU: ${cpu}% | MEM: ${mem}% | RSS: ${rss}KB | TIME: ${time}"
    else
        echo "  $name (PID: $pid) - PROCESS NOT RUNNING"
        return 1
    fi
}

# Function to check system resources
check_system_resources() {
    log "System Resources:"
    
    # Memory
    local mem_total=$(sysctl -n hw.memsize | awk '{print $1/1024/1024/1024}')
    local mem_free=$(vm_stat | grep "Pages free" | awk '{print $3}' | tr -d '.' | awk '{print $1*4096/1024/1024/1024}')
    log "  Memory: ${mem_free}GB free / ${mem_total}GB total"
    
    # Load average
    local load=$(sysctl -n vm.loadavg | awk '{print $2, $3, $4}')
    log "  Load Average: $load"
    
    # Check for memory pressure
    local mem_pressure=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo "unknown")
    log "  Memory Pressure: $mem_pressure"
    
    # Check power management
    local sleep_disabled=$(pmset -g assertions | grep -c "PreventUserIdleSystemSleep" || echo "0")
    log "  Sleep Prevention Active: $sleep_disabled assertions"
    
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
        
        # Try to determine exit reason
        # Check system logs for kills
        local kill_reason=$(log show --predicate "processID == $pid" --last 5m --info 2>/dev/null | grep -i "kill\|signal\|term\|exit" | tail -1)
        
        if [ -n "$kill_reason" ]; then
            log_error "  Kill reason: $kill_reason"
        fi
        
        # Check for OOM killer
        local oom_check=$(log show --predicate 'eventMessage contains "memory" AND eventMessage contains "kill"' --last 5m 2>/dev/null | grep "$pid")
        if [ -n "$oom_check" ]; then
            log_error "  Possible OOM (Out of Memory) kill detected"
        fi
        
        # Check for sleep-related kills
        local sleep_check=$(pmset -g log | grep -i "sleep\|wake" | tail -5)
        if [ -n "$sleep_check" ]; then
            log_warn "  Recent sleep/wake events detected:"
            echo "$sleep_check" >> "$LOG_FILE"
        fi
        
        # Check last exit code if available
        log_error "  Check process-specific logs for more details"
        
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
