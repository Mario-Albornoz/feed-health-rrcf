# TODO: add last step for the rrcf setup.
.PHONY: help setup clean kafka-up kafka-down kafka-logs kafka-status \
        build-simulator build-handler setup-detector \
        run-handler run-detector run-simulator run-simulator-foreground \
        run-all stop-all status logs \
        test test-integration test-thesis test-simulator-completion clean-all

# Default target
.DEFAULT_GOAL := help

# Color output
BLUE := \033[0;34m
GREEN := \033[0;32m
YELLOW := \033[0;33m
RED := \033[0;31m
NC := \033[0m # No Color

# Project directories
PROJECT_ROOT := $(shell pwd)
SIMULATOR_DIR := price-feed-simulator
HANDLER_DIR := feed-handler
DETECTOR_DIR := rrcf-detector

# Binary paths
SIMULATOR_BIN := $(SIMULATOR_DIR)/bin/simulator
HANDLER_BIN := $(HANDLER_DIR)/aggregator

# PID files for process management
PIDS_DIR := $(PROJECT_ROOT)/.pids
HANDLER_PID := $(PIDS_DIR)/handler.pid
SIMULATOR_PID := $(PIDS_DIR)/simulator.pid

# Log directory
LOGS_DIR := $(PROJECT_ROOT)/logs

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
	@echo "$(YELLOW) Deleting log files"
	@rm -f ./logs/*.log
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
	@echo "  Simulator: tail -f $(LOGS_DIR)/simulator.log"
	@echo ""
	@$(MAKE) run-simulator
	@echo "$(GREEN)✓ Simulator started$(NC)"
	@echo ""
	@echo "$(GREEN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(GREEN)  Pipeline Running Successfully!$(NC)"
	@echo "$(GREEN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo ""
	@echo "$(YELLOW)Monitor with:$(NC)"
	@echo "  make status          # Check component status"
	@echo "  make logs            # Tail all logs"
	@echo ""
	@echo "$(YELLOW)Stop with:$(NC)"
	@echo "  make stop-all        # Stop all components"

run-handler: ## Start feed-handler (background)
	@mkdir -p $(PIDS_DIR) $(LOGS_DIR)
	@if [ -f $(HANDLER_PID) ] && kill -0 $$(cat $(HANDLER_PID)) 2>/dev/null; then \
		echo "$(YELLOW)Handler already running (PID: $$(cat $(HANDLER_PID)))$(NC)"; \
	else \
		PID=$$(./scripts/start_handler.sh) && \
		echo "$(GREEN)✓ Handler started (PID: $$PID)$(NC)"; \
	fi

run-detector: ## Start rrcf-detector (background)
	@mkdir -p $(PIDS_DIR) $(LOGS_DIR)
	@if [ -f $(PIDS_DIR)/detector-collector.pid ] && kill -0 $$(cat $(PIDS_DIR)/detector-collector.pid) 2>/dev/null; then \
		echo "$(YELLOW)Detector already running$(NC)"; \
	else \
		PIDS=$$(./scripts/start_detector.sh) && \
		COLLECTOR_PID=$$(echo $$PIDS | cut -d' ' -f1) && \
		MULTI_PID=$$(echo $$PIDS | cut -d' ' -f2) && \
		echo "$(GREEN)✓ Detector started (collector: $$COLLECTOR_PID, multi-model: $$MULTI_PID)$(NC)"; \
	fi

run-simulator: ## Start price-feed-simulator (background with logs)
	@mkdir -p $(PIDS_DIR) $(LOGS_DIR)
	@if [ -f $(SIMULATOR_PID) ] && kill -0 $$(cat $(SIMULATOR_PID)) 2>/dev/null; then \
		echo "$(YELLOW)Simulator already running (PID: $$(cat $(SIMULATOR_PID)))$(NC)"; \
	else \
		PID=$$(./scripts/start_simulator.sh) && \
		echo "$(GREEN)✓ Simulator started (PID: $$PID)$(NC)"; \
	fi

run-simulator-foreground: ## Start price-feed-simulator (foreground, no logging to file)
	@cd $(SIMULATOR_DIR) && ./bin/simulator

stop-all: ## Stop all running pipeline components
	@echo "$(YELLOW)Stopping pipeline components...$(NC)"
	@echo ""
	@# Kill simulator
	@if [ -f $(SIMULATOR_PID) ]; then \
		if kill -0 $$(cat $(SIMULATOR_PID)) 2>/dev/null; then \
			kill $$(cat $(SIMULATOR_PID)) 2>/dev/null || true; \
			sleep 0.5; \
			kill -9 $$(cat $(SIMULATOR_PID)) 2>/dev/null || true; \
			echo "$(GREEN)✓ Simulator stopped$(NC)"; \
		fi; \
		rm -f $(SIMULATOR_PID); \
	else \
		echo "$(YELLOW)  Simulator not running$(NC)"; \
	fi
	@# Kill detector collector and all its children
	@if [ -f $(PIDS_DIR)/detector-collector.pid ]; then \
		if kill -0 $$(cat $(PIDS_DIR)/detector-collector.pid) 2>/dev/null; then \
			pkill -P $$(cat $(PIDS_DIR)/detector-collector.pid) 2>/dev/null || true; \
			kill $$(cat $(PIDS_DIR)/detector-collector.pid) 2>/dev/null || true; \
			sleep 0.5; \
			kill -9 $$(cat $(PIDS_DIR)/detector-collector.pid) 2>/dev/null || true; \
			echo "$(GREEN)✓ Detector collector stopped$(NC)"; \
		fi; \
		rm -f $(PIDS_DIR)/detector-collector.pid; \
	else \
		echo "$(YELLOW)  Detector collector not running$(NC)"; \
	fi
	@# Kill detector multi-model and ALL its worker children
	@if [ -f $(PIDS_DIR)/detector-multi.pid ]; then \
		if kill -0 $$(cat $(PIDS_DIR)/detector-multi.pid) 2>/dev/null; then \
			pkill -P $$(cat $(PIDS_DIR)/detector-multi.pid) 2>/dev/null || true; \
			kill $$(cat $(PIDS_DIR)/detector-multi.pid) 2>/dev/null || true; \
			sleep 1; \
			kill -9 $$(cat $(PIDS_DIR)/detector-multi.pid) 2>/dev/null || true; \
			pkill -9 -f "multiprocessing.*spawn_main" 2>/dev/null || true; \
			echo "$(GREEN)✓ Detector multi-model stopped$(NC)"; \
		fi; \
		rm -f $(PIDS_DIR)/detector-multi.pid; \
	else \
		echo "$(YELLOW)  Detector multi-model not running$(NC)"; \
	fi
	@# Kill handler
	@if [ -f $(HANDLER_PID) ]; then \
		if kill -0 $$(cat $(HANDLER_PID)) 2>/dev/null; then \
			kill $$(cat $(HANDLER_PID)) 2>/dev/null || true; \
			sleep 0.5; \
			kill -9 $$(cat $(HANDLER_PID)) 2>/dev/null || true; \
			echo "$(GREEN)✓ Handler stopped$(NC)"; \
		fi; \
		rm -f $(HANDLER_PID); \
	else \
		echo "$(YELLOW)  Handler not running$(NC)"; \
	fi
	@# Kill monitor
	@pkill -f "monitor_pipeline.sh" 2>/dev/null || true
	@# Nuclear option: kill any remaining Python workers from this project
	@pkill -f "scripts/run_multi_model.py" 2>/dev/null || true
	@pkill -f "scripts/stream_collector.py" 2>/dev/null || true
	@echo ""
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

test-integration: ## Run integration test of complete pipeline (30s test)
	@echo "$(BLUE)Running pipeline integration test...$(NC)"
	@rm -f ./test-run/*.log
	@./test-run/test_pipeline.sh

test-thesis: ## Run thesis evaluation integration test
	@echo "$(BLUE)Running thesis evaluation integration test...$(NC)"
	@./test-run/test_thesis_quick.sh

test-simulator-completion: ## Test that simulator completes gracefully (doesn't hang)
	@echo "$(BLUE)Testing simulator completion and graceful shutdown...$(NC)"
	@./test-run/test_simulator_completion.sh

##@ Cleanup

clean: ## Clean build artifacts and logs
	@echo "$(YELLOW)Cleaning build artifacts...$(NC)"
	@rm -rf $(SIMULATOR_DIR)/bin/simulator
	@rm -rf $(HANDLER_DIR)/aggregator
	@rm -rf $(LOGS_DIR)/*
	@rm -rf $(PIDS_DIR)
	@echo "$(GREEN)✓ Build artifacts cleaned$(NC)"

clean-output-files: ## Clean output files from previous runs (scores, ground truth, logs)
	@echo "$(YELLOW)Cleaning output files from previous runs...$(NC)"
	@rm -f ./rrcf-detector/data/scores_rrcf.parquet
	@rm -f ./rrcf-detector/data/scores_zscore.parquet
	@rm -f ./rrcf-detector/data/scores_onlineiforest.parquet
	@rm -f ./rrcf-detector/data/scores_isoforest.parquet
	@rm -f ./rrcf-detector/data/scores_halfspace.parquet
	@rm -f ./price-feed-simulator/anomaly_log.csv
	@rm -f ./price-feed-simulator/data/anomaly_log.csv
	@rm -f ./price-feed-simulator/data/injection_manifest.json
	@rm -f ./data/scores.parquet
	@rm -f ./data/anomaly_log.csv
	@rm -f ./data/injection_manifest.json
	@rm -f ./logs/*.log
	@echo "$(GREEN)✓ Output files cleaned$(NC)"

clean-all: clean clean-output-files kafka-down ## Full cleanup (artifacts + outputs + Docker volumes + venv)
	@echo "$(YELLOW)Performing full cleanup...$(NC)"
	@rm -rf $(DETECTOR_DIR)/venv
	@docker volume rm thesis-kafka-data 2>/dev/null || true
	@echo "$(GREEN)✓ Full cleanup complete$(NC)"

##@ Thesis Evaluation

run-thesis-experiment: ## Run thesis evaluation experiment with anomaly injection
	@echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(BLUE)  Thesis Evaluation Experiment$(NC)"
	@echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo ""
	@echo "$(YELLOW)Cleaning previous run...$(NC)"
	@$(MAKE) clean-output-files > /dev/null 2>&1
	@echo "$(GREEN)✓ Cleaned$(NC)"
	@echo ""
	@echo "$(YELLOW)Starting infrastructure...$(NC)"
	@make kafka-up > /dev/null 2>&1
	@echo "$(GREEN)✓ Kafka ready$(NC)"
	@echo ""
	@echo "$(YELLOW)Starting handler and detector...$(NC)"
	@$(MAKE) run-handler > /dev/null 2>&1
	@sleep 5
	@$(MAKE) run-detector > /dev/null 2>&1
	@sleep 5
	@echo "$(GREEN)✓ Handler and detector ready$(NC)"
	@echo ""
	@echo "$(YELLOW)Running simulator with anomaly injection...$(NC)"
	@echo "  This will take 4-5 minutes depending on dataset size"
	@echo "  $(BLUE)Progress: tail -f logs/simulator.log$(NC)"
	@echo ""
	@cd $(SIMULATOR_DIR) && ./bin/simulator -config config/simulator-with-anomalies.yaml
	@echo ""
	@echo "$(GREEN)✓ Simulator run complete$(NC)"
	@echo ""
	@echo "$(YELLOW)Stopping pipeline components...$(NC)"
	@$(MAKE) stop-all > /dev/null 2>&1
	@echo "$(GREEN)✓ Components stopped$(NC)"
	@echo ""
	@echo "$(YELLOW)Verifying output files...$(NC)"
	@ls -lh ./price-feed-simulator/anomaly_log.csv ./price-feed-simulator/data/injection_manifest.json ./rrcf-detector/data/scores.parquet 2>&1 || echo "$(RED)✗ Missing output files$(NC)"
	@echo ""
	@echo "$(GREEN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(GREEN)  Experiment Complete!$(NC)"
	@echo "$(GREEN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo ""
	@echo "Ground truth: ./price-feed-simulator/anomaly_log.csv"
	@echo "Manifest:     ./price-feed-simulator/data/injection_manifest.json"
	@echo "Scores:       ./rrcf-detector/data/scores.parquet"
	@echo ""

evaluate-thesis: ## Evaluate thesis results (RQ1 + RQ2)
	@echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(BLUE)  Thesis Evaluation: RQ1 + RQ2 (Optimized)$(NC)"
	@echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo ""
	@cd $(DETECTOR_DIR) && \
		./venv/bin/python3 scripts/evaluate_thesis.py \
		--ground-truth-csv ../price-feed-simulator/anomaly_log.csv \
		--ground-truth-manifest ../price-feed-simulator/data/injection_manifest.json \
		--scores ./data/scores_rrcf.parquet \
		--output ../results/thesis_$(shell date +%Y%m%d_%H%M%S)
	@echo ""
	@echo "$(GREEN)✓ Evaluation complete!$(NC)"
	@echo "Results are ready for thesis inclusion."

thesis-full: run-thesis-experiment evaluate-thesis ## Complete thesis evaluation workflow (run + evaluate)
	@echo ""
	@echo "$(GREEN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(GREEN)  Thesis Evaluation Complete!$(NC)"
	@echo "$(GREEN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
