# TODO: add last step for the rrcf setup.
.PHONY: help setup clean kafka-up kafka-down kafka-logs kafka-status \
        build-simulator build-handler setup-detector \
        run-handler run-detector run-simulator \
        run-all stop-all status logs \
        test clean-all

# Default target
.DEFAULT_GOAL := help

# Color output
BLUE := \033[0;34m
GREEN := \033[0;32m
YELLOW := \033[0;33m
RED := \033[0;31m
NC := \033[0m # No Color

# Project directories
SIMULATOR_DIR := price-feed-simulator
HANDLER_DIR := feed-handler
DETECTOR_DIR := rrcf-detector

# Binary paths
SIMULATOR_BIN := $(SIMULATOR_DIR)/bin/simulator
HANDLER_BIN := $(HANDLER_DIR)/aggregator

# PID files for process management
PIDS_DIR := .pids
HANDLER_PID := $(PIDS_DIR)/handler.pid
SIMULATOR_PID := $(PIDS_DIR)/simulator.pid

# Log directory
LOGS_DIR := logs

##@ Help

help: ## Display this help message
	@echo "$(BLUE)╔════════════════════════════════════════════════════════════╗$(NC)"
	@echo "$(BLUE)║  Thesis Pipeline - Market Data Anomaly Detection System  ║$(NC)"
	@echo "$(BLUE)╚════════════════════════════════════════════════════════════╝$(NC)"
	@echo ""
	@echo "$(GREEN)Quick Start:$(NC)"
	@echo "  1. make setup        # Build everything and install dependencies"
	@echo "  2. make kafka-up     # Start Kafka and Redis"
	@echo "  3. make run-all      # Run the entire pipeline"
	@echo "  4. make stop-all     # Stop all services"
	@echo "  5. make kafka-down   # Stop infrastructure"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"; printf "\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  $(GREEN)%-18s$(NC) %s\n", $$1, $$2 } /^##@/ { printf "\n$(BLUE)%s$(NC)\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Setup & Installation

setup: ## Install all dependencies and build binaries
	@echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(BLUE)  Setting up Thesis Pipeline$(NC)"
	@echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@mkdir -p $(PIDS_DIR) $(LOGS_DIR)
	@$(MAKE) build-simulator
	@$(MAKE) build-handler
	@$(MAKE) setup-detector
	@echo "$(GREEN)✓ Setup complete!$(NC)"
	@echo ""
	@echo "$(YELLOW)Next steps:$(NC)"
	@echo "  1. make kafka-up    # Start infrastructure"
	@echo "  2. make run-all     # Run the pipeline"

build-simulator: ## Build price-feed-simulator binary
	@echo "$(YELLOW)Building price-feed-simulator...$(NC)"
	@cd $(SIMULATOR_DIR) && go build -o bin/simulator cmd/simulator/main.go
	@echo "$(GREEN)✓ Simulator built$(NC)"

build-handler: ## Build feed-handler binary
	@echo "$(YELLOW)Building feed-handler...$(NC)"
	@cd $(HANDLER_DIR) && go build -o aggregator ./cmd/aggregator
	@echo "$(GREEN)✓ Handler built$(NC)"

setup-detector: ## Setup rrcf-detector (Python venv + dependencies)
	@echo "$(YELLOW)Setting up rrcf-detector...$(NC)"
	@if ! command -v python3.12 > /dev/null 2>&1; then \
		echo "$(RED)Error: Python 3.12 required but not found$(NC)"; \
		echo "$(YELLOW)Install: brew install python@3.12$(NC)"; \
		exit 1; \
	fi
	@cd $(DETECTOR_DIR) && \
		if [ ! -d "venv" ]; then \
			echo "$(YELLOW)  Creating venv with Python 3.12...$(NC)"; \
			python3.12 -m venv venv; \
			echo "$(GREEN)✓ Virtual environment created$(NC)"; \
		fi && \
		. venv/bin/activate && \
		echo "$(YELLOW)  Installing dependencies from requirements.txt...$(NC)" && \
		pip install --upgrade pip > /dev/null 2>&1 && \
		pip install 'setuptools<75' > /dev/null 2>&1 && \
		pip install -r requirements.txt && \
		echo "$(GREEN)✓ Dependencies installed$(NC)"

##@ Infrastructure

kafka-up: ## Start Kafka and Zookeeper via Docker Compose
	@echo "$(YELLOW)Starting infrastructure (Kafka + Zookeeper)...$(NC)"
	@docker compose up -d
	@echo "$(YELLOW)Waiting for services to be healthy...$(NC)"
	@sleep 15
	@echo "$(GREEN)✓ Infrastructure ready$(NC)"
	@echo ""
	@docker compose ps

kafka-down: ## Stop and remove Kafka infrastructure
	@echo "$(YELLOW)Stopping infrastructure...$(NC)"
	@docker compose down -v
	@echo "$(GREEN)✓ Infrastructure stopped$(NC)"

kafka-logs: ## Show Kafka logs
	@docker compose logs -f kafka

kafka-status: ## Check Kafka infrastructure status
	@docker compose ps

##@ Pipeline Execution

run-all: ## Run the complete pipeline (handler → detector → simulator) with sleep prevention
	@echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(BLUE)  Starting Thesis Pipeline$(NC)"
	@echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo ""
	@if ! docker compose ps | grep -q "thesis-kafka.*Up"; then \
		echo "$(RED)✗ Kafka is not running. Please run 'make kafka-up' first.$(NC)"; \
		exit 1; \
	fi
	@echo "$(YELLOW)ℹ Using caffeinate to prevent system sleep during execution$(NC)"
	@echo ""
	@echo "$(YELLOW)Step 1/3: Starting feed-handler...$(NC)"
	@$(MAKE) run-handler
	@sleep 5
	@echo "$(YELLOW)Step 2/3: Starting rrcf-detector...$(NC)"
	@$(MAKE) run-detector
	@sleep 5
	@echo "$(YELLOW)Step 3/3: Starting price-feed-simulator...$(NC)"
	@echo "$(YELLOW)Step 4/4: Starting pipeline monitor...$(NC)"
	@./scripts/monitor_pipeline.sh &
	@echo "$(GREEN)Pipeline is now running!$(NC)"
	@echo ""
	@echo "$(BLUE)Logs:$(NC)"
	@echo "  Handler:   tail -f $(LOGS_DIR)/handler.log"
	@echo "  Detector:  tail -f $(LOGS_DIR)/detector-*.log"
	@echo "  Monitor:   tail -f $(LOGS_DIR)/monitor.log"
	@echo "  Simulator: (running in foreground)"
	@echo ""
	@echo "$(YELLOW)Press Ctrl+C to stop the simulator and pipeline$(NC)"
	@echo ""
	@caffeinate -dis $(MAKE) run-simulator

run-handler: ## Start feed-handler (background)
	@if [ -f $(HANDLER_PID) ] && kill -0 $$(cat $(HANDLER_PID)) 2>/dev/null; then \
		echo "$(YELLOW)Handler already running (PID: $$(cat $(HANDLER_PID)))$(NC)"; \
	else \
		cd $(HANDLER_DIR) && \
			nohup ./aggregator > ../$(LOGS_DIR)/handler.log 2>&1 & echo $$! > ../$(HANDLER_PID); \
		echo "$(GREEN)✓ Handler started (PID: $$(cat $(HANDLER_PID)))$(NC)"; \
	fi

run-detector: ## Start rrcf-detector (background)
	@if [ -f $(PIDS_DIR)/detector-collector.pid ] && kill -0 $$(cat $(PIDS_DIR)/detector-collector.pid) 2>/dev/null; then \
		echo "$(YELLOW)Detector already running$(NC)"; \
	else \
		cd $(DETECTOR_DIR) && \
			PYTHONPATH=. nohup venv/bin/python3 scripts/stream_collector.py --config config/baselines.yaml > ../$(LOGS_DIR)/detector-collector.log 2>&1 & echo $$! > ../$(PIDS_DIR)/detector-collector.pid; \
		sleep 2; \
		cd $(DETECTOR_DIR) && \
			PYTHONPATH=. nohup venv/bin/python3 scripts/run_multi_model.py --config config/baselines.yaml > ../$(LOGS_DIR)/detector-multi.log 2>&1 & echo $$! > ../$(PIDS_DIR)/detector-multi.pid; \
		echo "$(GREEN)✓ Detector started (collector: $$(cat $(PIDS_DIR)/detector-collector.pid), multi-model: $$(cat $(PIDS_DIR)/detector-multi.pid))$(NC)"; \
	fi

run-simulator: ## Start price-feed-simulator (foreground)
	@cd $(SIMULATOR_DIR) && ./bin/simulator

stop-all: ## Stop all running pipeline components
	@echo "$(YELLOW)Stopping pipeline components...$(NC)"
	@if [ -f $(SIMULATOR_PID) ]; then \
		kill $$(cat $(SIMULATOR_PID)) 2>/dev/null || true; \
		rm -f $(SIMULATOR_PID); \
	fi
	@if [ -f $(PIDS_DIR)/detector-collector.pid ]; then \
		kill $$(cat $(PIDS_DIR)/detector-collector.pid) 2>/dev/null || true; \
		rm -f $(PIDS_DIR)/detector-collector.pid; \
	fi
	@if [ -f $(PIDS_DIR)/detector-multi.pid ]; then \
		kill $$(cat $(PIDS_DIR)/detector-multi.pid) 2>/dev/null || true; \
		rm -f $(PIDS_DIR)/detector-multi.pid; \
		echo "$(GREEN)✓ Detector stopped$(NC)"; \
	fi
	@if [ -f $(HANDLER_PID) ]; then \
		kill $$(cat $(HANDLER_PID)) 2>/dev/null || true; \
		rm -f $(HANDLER_PID); \
		echo "$(GREEN)✓ Handler stopped$(NC)"; \
	fi
	@echo "$(GREEN)✓ All components stopped$(NC)"

status: ## Show status of all pipeline components
	@echo "$(BLUE)Pipeline Status:$(NC)"
	@echo ""
	@echo "$(YELLOW)Feed Handler:$(NC)"
	@if [ -f $(HANDLER_PID) ] && kill -0 $$(cat $(HANDLER_PID)) 2>/dev/null; then \
		echo "  $(GREEN)● Running$(NC) (PID: $$(cat $(HANDLER_PID)))"; \
	else \
		echo "  $(RED)○ Stopped$(NC)"; \
	fi
	@echo ""
	@echo "$(YELLOW)RRCF Detector:$(NC)"
	@if [ -f $(PIDS_DIR)/detector-collector.pid ] && kill -0 $$(cat $(PIDS_DIR)/detector-collector.pid) 2>/dev/null; then \
		echo "  $(GREEN)● Collector Running$(NC) (PID: $$(cat $(PIDS_DIR)/detector-collector.pid))"; \
	else \
		echo "  $(RED)○ Collector Stopped$(NC)"; \
	fi
	@if [ -f $(PIDS_DIR)/detector-multi.pid ] && kill -0 $$(cat $(PIDS_DIR)/detector-multi.pid) 2>/dev/null; then \
		echo "  $(GREEN)● Multi-Model Running$(NC) (PID: $$(cat $(PIDS_DIR)/detector-multi.pid))"; \
	else \
		echo "  $(RED)○ Multi-Model Stopped$(NC)"; \
	fi
	@echo ""
	@echo "$(YELLOW)Infrastructure:$(NC)"
	@docker compose ps

logs: ## Tail all pipeline logs
	@echo "$(BLUE)Tailing logs (Ctrl+C to stop)...$(NC)"
	@tail -f $(LOGS_DIR)/*.log 2>/dev/null || echo "$(YELLOW)No logs found. Pipeline may not be running.$(NC)"

##@ Testing

test: ## Run all tests for all components
	@echo "$(BLUE)Running all tests...$(NC)"
	@echo ""
	@echo "$(YELLOW)Testing price-feed-simulator...$(NC)"
	@cd $(SIMULATOR_DIR) && go test ./... -v
	@echo ""
	@echo "$(YELLOW)Testing feed-handler...$(NC)"
	@cd $(HANDLER_DIR) && go test ./internal/... -v
	@echo ""
	@echo "$(YELLOW)Testing rrcf-detector...$(NC)"
	@cd $(DETECTOR_DIR) && . venv/bin/activate && pytest tests/ -v
	@echo ""
	@echo "$(GREEN)✓ All tests completed$(NC)"

##@ Cleanup

clean: ## Clean build artifacts and logs
	@echo "$(YELLOW)Cleaning build artifacts...$(NC)"
	@rm -rf $(SIMULATOR_DIR)/bin/simulator
	@rm -rf $(HANDLER_DIR)/aggregator
	@rm -rf $(LOGS_DIR)/*
	@rm -rf $(PIDS_DIR)
	@echo "$(GREEN)✓ Build artifacts cleaned$(NC)"

clean-all: clean kafka-down ## Full cleanup (artifacts + Docker volumes + venv)
	@echo "$(YELLOW)Performing full cleanup...$(NC)"
	@rm -rf $(DETECTOR_DIR)/venv
	@docker volume rm thesis-kafka-data 2>/dev/null || true
	@echo "$(GREEN)✓ Full cleanup complete$(NC)"
