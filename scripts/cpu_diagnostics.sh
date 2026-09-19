#!/bin/bash
#
# CPU Diagnostics Script
# Check for CPU pressure, throttling, and past process kills
#
# Usage: ./scripts/cpu_diagnostics.sh [--watch] [--full]
#   --watch: Continuous monitoring mode
#   --full:  Include slow system log queries (may take 30+ seconds)
#

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if watch mode
WATCH_MODE=false
FULL_MODE=false

for arg in "$@"; do
    case "$arg" in
        --watch) WATCH_MODE=true ;;
        --full)  FULL_MODE=true ;;
    esac
done

print_section() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

check_cpu_current() {
    print_section "Current CPU Status"
    
    # CPU cores
    local ncpu=$(sysctl -n hw.ncpu)
    local cpu_freq=$(sysctl -n hw.cpufrequency 2>/dev/null)
    if [ -n "$cpu_freq" ] && [ "$cpu_freq" != "0" ]; then
        cpu_freq=$(awk "BEGIN {printf \"%.2f\", $cpu_freq / 1000000000}")
        echo -e "  CPU Cores: ${GREEN}${ncpu}${NC} @ ${cpu_freq} GHz"
    else
        echo -e "  CPU Cores: ${GREEN}${ncpu}${NC}"
    fi
    
    # Current usage
    local cpu_info=$(top -l 1 -n 0 | grep "CPU usage")
    local cpu_user=$(echo "$cpu_info" | awk '{print $3}')
    local cpu_sys=$(echo "$cpu_info" | awk '{print $5}')
    local cpu_idle=$(echo "$cpu_info" | awk '{print $7}')
    
    echo -e "  Usage: User ${cpu_user} | System ${cpu_sys} | Idle ${cpu_idle}"
    
    # Load average
    local load=$(sysctl -n vm.loadavg | awk '{print $2, $3, $4}')
    echo -e "  Load Avg: ${load}"
    
    # Calculate load percentage
    local load_1min=$(echo "$load" | awk '{print $1}')
    local load_pct=$(awk "BEGIN {printf \"%.1f\", ($load_1min / $ncpu) * 100}")
    
    if awk "BEGIN {exit !($load_pct > 80)}"; then
        echo -e "  ${RED}⚠ High load: ${load_pct}% of capacity${NC}"
    elif awk "BEGIN {exit !($load_pct > 50)}"; then
        echo -e "  ${YELLOW}⚠ Moderate load: ${load_pct}% of capacity${NC}"
    else
        echo -e "  ${GREEN}✓ Normal load: ${load_pct}% of capacity${NC}"
    fi
    
    echo ""
}

check_thermal_status() {
    print_section "Thermal & Power Status"
    
    # Thermal checking skipped - pmset can be slow
    echo -e "  ${YELLOW}CPU Throttling: Check disabled (pmset -g thermlog can be slow)${NC}"
    echo -e "  ${YELLOW}To check manually: pmset -g thermlog | grep CPU_Scheduler_Limit${NC}"
    
    # Power assertions - quick check
    if pmset -g assertions 2>/dev/null | grep -q "PreventUserIdleSystemSleep"; then
        echo -e "  ${GREEN}✓ System sleep prevented (good for long-running tasks)${NC}"
    else
        echo -e "  ${YELLOW}⚠ System may sleep during idle periods${NC}"
    fi
    
    # Battery status (if laptop) - quick check
    local battery=$(pmset -g batt 2>/dev/null | grep "InternalBattery" | head -1 || echo "")
    if [ -n "$battery" ]; then
        if echo "$battery" | grep -q "discharging"; then
            echo -e "  Battery: ${YELLOW}Discharging (may reduce performance)${NC}"
        elif echo "$battery" | grep -q "charging"; then
            echo -e "  Battery: ${GREEN}Charging ✓${NC}"
        else
            echo -e "  Power: ${GREEN}AC Powered ✓${NC}"
        fi
    fi
    
    echo ""
}

check_top_processes() {
    print_section "Top CPU Consumers (Last 5s Average)"
    
    top -l 2 -n 10 -o cpu -stats pid,command,cpu,threads,mem 2>/dev/null | \
        awk '/PID/{flag=1;next}/^Processes/{flag=0}flag' | \
        tail -10 | \
        while IFS= read -r line; do
            echo "  $line"
        done
    
    echo ""
}

check_pipeline_processes() {
    print_section "Pipeline Process Status"
    
    local pids_dir=".pids"
    local found=false
    
    for pid_file in "$pids_dir"/*.pid; do
        if [ -f "$pid_file" ]; then
            found=true
            local name=$(basename "$pid_file" .pid)
            local pid=$(cat "$pid_file")
            
            if kill -0 "$pid" 2>/dev/null; then
                local cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ')
                local mem=$(ps -p "$pid" -o %mem= 2>/dev/null | tr -d ' ')
                local threads=$(ps -M -p "$pid" 2>/dev/null | wc -l | tr -d ' ')
                local time=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ')
                
                echo -e "  ${GREEN}✓${NC} $name (PID: $pid)"
                echo -e "    CPU: ${cpu}% | Memory: ${mem}% | Threads: ${threads} | Uptime: ${time}"
                
                # Warn if high CPU
                if [ -n "$cpu" ] && awk "BEGIN {exit !($cpu > 150)}"; then
                    echo -e "    ${YELLOW}⚠ High CPU usage${NC}"
                fi
            else
                echo -e "  ${RED}✗${NC} $name (PID: $pid) - NOT RUNNING"
            fi
        fi
    done
    
    if [ "$found" = false ]; then
        echo -e "  ${YELLOW}No pipeline processes found${NC}"
    fi
    
    echo ""
}

check_recent_kills() {
    print_section "Recent Process Terminations (Last 10 Minutes)"
    
    if [ "$FULL_MODE" != true ]; then
        echo -e "  ${YELLOW}Skipped (use --full flag to check system logs)${NC}"
        echo -e "  ${YELLOW}Note: System log queries can take 30+ seconds on macOS${NC}"
        echo ""
        return
    fi
    
    echo -e "  ${YELLOW}Checking system logs (this can be slow, 15-30 seconds)...${NC}"
    
    # macOS log show is very slow, so we limit the scope
    local kills=$(log show --predicate 'eventMessage contains "signal" OR eventMessage contains "terminated"' --last 10m --style compact 2>/dev/null | grep -E "simulator|handler|detector|python" | head -10 || echo "")
    
    if [ -n "$kills" ]; then
        echo -e "  ${YELLOW}Found termination events:${NC}"
        echo "$kills" | while IFS= read -r line; do
            echo "    $line"
        done
    else
        echo -e "  ${GREEN}✓ No recent terminations detected${NC}"
    fi
    
    echo ""
}

check_memory_pressure() {
    print_section "Memory Pressure"
    
    local mem_pressure=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)
    
    case "$mem_pressure" in
        1)
            echo -e "  ${GREEN}✓ Normal (level 1)${NC}"
            ;;
        2)
            echo -e "  ${YELLOW}⚠ Warning (level 2)${NC}"
            echo -e "    System may start freeing memory"
            ;;
        3|4)
            echo -e "  ${RED}⚠ Critical (level $mem_pressure)${NC}"
            echo -e "    System is actively killing processes to free memory"
            ;;
        *)
            echo -e "  ${YELLOW}Unknown (level $mem_pressure)${NC}"
            ;;
    esac
    
    # Memory stats
    local mem_total=$(sysctl -n hw.memsize | awk '{printf "%.1f", $1/1024/1024/1024}')
    local mem_wired=$(vm_stat | grep "Pages wired down" | awk '{print $4}' | tr -d '.' | awk '{printf "%.1f", $1*4096/1024/1024/1024}')
    local mem_active=$(vm_stat | grep "Pages active" | awk '{print $3}' | tr -d '.' | awk '{printf "%.1f", $1*4096/1024/1024/1024}')
    local mem_free=$(vm_stat | grep "Pages free" | awk '{print $3}' | tr -d '.' | awk '{printf "%.1f", $1*4096/1024/1024/1024}')
    
    echo -e "  Total: ${mem_total}GB | Wired: ${mem_wired}GB | Active: ${mem_active}GB | Free: ${mem_free}GB"
    
    echo ""
}

check_disk_io() {
    print_section "Disk I/O (Can Cause CPU Wait)"
    
    echo -e "  ${YELLOW}Sampling I/O for 2 seconds...${NC}"
    local iostat_output=$(iostat -c 2 -w 2 2>/dev/null | tail -1 || echo "")
    
    if [ -n "$iostat_output" ]; then
        echo "  $iostat_output"
        
        # Check if disk is bottleneck  
        local disk_util=$(echo "$iostat_output" | awk '{print $NF}' | tr -d '%')
        if [ -n "$disk_util" ] && awk "BEGIN {exit !($disk_util > 80)}"; then
            echo -e "  ${RED}⚠ High disk utilization (>80%)${NC}"
            echo -e "    This can cause processes to appear CPU-bound while waiting for I/O"
        fi
    else
        echo -e "  ${YELLOW}Unable to sample disk I/O${NC}"
    fi
    
    echo ""
}

# Main execution
if [ "$WATCH_MODE" = true ]; then
    while true; do
        clear
        echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
        echo -e "${BLUE}  CPU Diagnostics - $(date '+%Y-%m-%d %H:%M:%S')${NC}"
        echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
        echo ""
        
        check_cpu_current
        check_thermal_status
        check_pipeline_processes
        check_memory_pressure
        
        echo -e "${YELLOW}Refreshing in 5 seconds... (Ctrl+C to exit)${NC}"
        sleep 5
    done
else
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  CPU Diagnostics - $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo ""
    
    check_cpu_current
    check_thermal_status
    check_top_processes
    check_pipeline_processes
    check_recent_kills
    check_memory_pressure
    check_disk_io
    
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}Diagnostics complete!${NC}"
    echo -e "Run with ${YELLOW}--watch${NC} flag for continuous monitoring"
    echo -e "Run with ${YELLOW}--full${NC} flag to include system log queries (slower)"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
fi
