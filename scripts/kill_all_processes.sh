#!/bin/bash
#
# Emergency cleanup script
# Kills ALL pipeline-related processes, including orphans from previous runs
#

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${RED}  EMERGENCY CLEANUP${NC}"
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}This will kill ALL processes related to the pipeline,${NC}"
echo -e "${YELLOW}including orphans from previous runs.${NC}"
echo ""

# Check what will be killed
echo -e "${BLUE}Processes that will be killed:${NC}"
ps aux | grep -E "simulator|aggregator|run_multi_model|stream_collector|monitor_pipeline" | grep -v grep | grep -v "kill_all_processes.sh"

echo ""
read -p "Continue? (y/N): " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Cancelled.${NC}"
    exit 0
fi

echo ""
echo -e "${YELLOW}Killing processes...${NC}"

# Kill simulator
pkill -f "bin/simulator" && echo -e "${GREEN}✓ Killed simulator${NC}" || echo -e "${YELLOW}  No simulator found${NC}"

# Kill aggregator (handler)
pkill -f "aggregator" && echo -e "${GREEN}✓ Killed aggregator/handler${NC}" || echo -e "${YELLOW}  No aggregator found${NC}"

# Kill multi-model detector
pkill -f "run_multi_model.py" && echo -e "${GREEN}✓ Killed multi-model detector${NC}" || echo -e "${YELLOW}  No multi-model found${NC}"

# Kill collector
pkill -f "stream_collector.py" && echo -e "${GREEN}✓ Killed stream collector${NC}" || echo -e "${YELLOW}  No collector found${NC}"

# Kill monitor
pkill -f "monitor_pipeline.sh" && echo -e "${GREEN}✓ Killed monitor${NC}" || echo -e "${YELLOW}  No monitor found${NC}"

# Nuclear option: kill all Python multiprocessing workers spawned by this project
sleep 1
pkill -f "multiprocessing.*spawn_main" && echo -e "${GREEN}✓ Killed Python workers${NC}" || echo -e "${YELLOW}  No Python workers found${NC}"

# Clean up PID files
rm -f .pids/*.pid 2>/dev/null

echo ""
echo -e "${BLUE}Remaining processes (if any):${NC}"
ps aux | grep -E "simulator|aggregator|run_multi_model|stream_collector|monitor_pipeline" | grep -v grep | grep -v "kill_all_processes.sh" || echo -e "${GREEN}✓ All clean!${NC}"

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Cleanup complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
