# TODO: add last step for the rrcf setup.
.PHONY: help setup clean kafka-up kafka-down kafka-logs kafka-status \
        build-simulator build-handler setup-detector \
        run-handler run-detector run-simulator run-simulator-foreground \
        run-all stop-all status logs \
        test test-integration test-thesis test-simulator-completion test-stop-all test-stop-all-real test-archive-run clean-all \
        kafka-reset drain integration-test smoke-run describe-dataset \
        run-thesis-experiment archive-run verify-run evaluate-thesis compare-models thesis-full

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

# Shell test, exit 0 when the pid file $(1) holds a positive pid of a live process. A pid file
# containing 0 (the disabled stream collector, see scripts/start_detector.sh) must never reach
# `kill`: `kill 0` signals the caller's whole process group, which took make, the handler and
# the detector down together at the end of a thesis run. Empty or garbage files count as dead.
# Regression test: test-run/test_stop_all.sh (make test-stop-all)
pid_alive = [ "$$(cat $(1) 2>/dev/null)" -gt 0 ] 2>/dev/null && kill -0 "$$(cat $(1))" 2>/dev/null

# Log directory
LOGS_DIR := $(PROJECT_ROOT)/logs

# Thesis run: python of the detector venv, where a run's files are archived, and the
# evaluation settings. Override on the command line, e.g.
#   make evaluate-thesis RUN_DIR=results/thesis_20260921_101500 TARGET_FAR=0.5
PY := $(DETECTOR_DIR)/venv/bin/python3
RESULTS_DIR := results
RUN_STAMP := $(shell date +%Y%m%d_%H%M%S)
NEW_RUN_DIR := $(RESULTS_DIR)/thesis_$(RUN_STAMP)
# where archive-run puts a run's inputs (must be under RESULTS_DIR: "latest" links to its name)
ARCHIVE_DIR ?= $(NEW_RUN_DIR)
# the run that verify-run / evaluate-thesis work on (run-thesis-experiment repoints "latest")
RUN_DIR ?= $(RESULTS_DIR)/latest
# Kafka CLI tools run inside the broker container (no extra installs needed)
KAFKA_EXEC := docker exec thesis-kafka
KAFKA_BS := localhost:9092
# Consumer groups of the two consumers. They must match consumer_group in
# feed-handler/config/aggregator.yaml and consumer_group_id + "-multi" in
# rrcf-detector/config/baselines.yaml (run_multi_model.py appends "-multi").
HANDLER_GROUP := aggregator-group
DETECTOR_GROUP := rrcf-detector-baselines-multi
# how long "make drain" waits in total (seconds)
DRAIN_TIMEOUT ?= 21600
# alert threshold is picked on the clean days at this many alerts per 1000 scored vectors
TARGET_FAR ?= 1.0
THRESHOLDS ?= 1,1.5,2,3,3.5,4,4.5,5,6,7,8,9,10,12,15,20

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
	@echo "$(GREEN)Thesis run (see README, section 'Running the thesis experiment'):$(NC)"
	@echo "  make setup && make smoke-run     # once: build, then a few-minute check of the whole chain"
	@echo "  make thesis-full                 # reset, run, drain, archive, verify, evaluate"
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

kafka-reset: ## Delete and recreate the pipeline topics and consumer offsets (empty start)
	@echo "$(YELLOW)Resetting Kafka topics and consumer groups...$(NC)"
	@if ! docker ps --format '{{.Names}}' | grep -q '^thesis-kafka$$'; then echo "$(RED)✗ Kafka is not running: make kafka-up$(NC)"; exit 1; fi
	@# 1. delete the topics and the consumers' committed offsets
	@for t in raw-ticks normalized-vectors health-events anomaly-scores; do \
		$(KAFKA_EXEC) kafka-topics --bootstrap-server $(KAFKA_BS) --delete --topic $$t --if-exists > /dev/null 2>&1; \
	done
	@for g in $(HANDLER_GROUP) $(DETECTOR_GROUP); do \
		$(KAFKA_EXEC) kafka-consumer-groups --bootstrap-server $(KAFKA_BS) --delete --group $$g > /dev/null 2>&1 || true; \
	done
	@# 2. wait until they are gone, then (re)create them as docker-compose.yml does
	@#    (a deleted topic can linger for a while, so retry until each one reports the right partition count)
	@for i in $$(seq 1 60); do \
		LEFT=$$($(KAFKA_EXEC) kafka-topics --bootstrap-server $(KAFKA_BS) --list 2>/dev/null | grep -cE '^(raw-ticks|normalized-vectors|health-events|anomaly-scores)$$'); \
		[ "$$LEFT" = "0" ] && break; sleep 2; \
	done
	@for i in $$(seq 1 45); do \
		OK=1; \
		for spec in raw-ticks:4 normalized-vectors:4 health-events:1 anomaly-scores:4; do \
			t=$${spec%%:*}; p=$${spec##*:}; \
			GOT=$$($(KAFKA_EXEC) kafka-topics --bootstrap-server $(KAFKA_BS) --describe --topic $$t 2>/dev/null | grep -o 'PartitionCount: *[0-9]*' | grep -o '[0-9]*$$'); \
			if [ "$$GOT" != "$$p" ]; then \
				OK=0; \
				$(KAFKA_EXEC) kafka-topics --bootstrap-server $(KAFKA_BS) --create --if-not-exists --topic $$t --partitions $$p --replication-factor 1 --config retention.ms=7200000 > /dev/null 2>&1; \
			fi; \
		done; \
		[ "$$OK" = "1" ] && break; sleep 2; \
	done; \
	[ "$$OK" = "1" ] || { echo "$(RED)✗ Topics were not created as expected$(NC)"; exit 1; }
	@echo "$(GREEN)✓ Topics reset: raw-ticks, normalized-vectors, anomaly-scores (4 partitions), health-events (1)$(NC)"

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
	@if $(call pid_alive,$(PIDS_DIR)/detector-collector.pid); then \
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
		if $(call pid_alive,$(SIMULATOR_PID)); then \
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
		if $(call pid_alive,$(PIDS_DIR)/detector-collector.pid); then \
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
		if $(call pid_alive,$(PIDS_DIR)/detector-multi.pid); then \
			pkill -P $$(cat $(PIDS_DIR)/detector-multi.pid) 2>/dev/null || true; \
			kill $$(cat $(PIDS_DIR)/detector-multi.pid) 2>/dev/null || true; \
			for i in $$(seq 1 240); do kill -0 $$(cat $(PIDS_DIR)/detector-multi.pid) 2>/dev/null || break; sleep 0.5; done; \
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
		if $(call pid_alive,$(HANDLER_PID)); then \
			kill $$(cat $(HANDLER_PID)) 2>/dev/null || true; \
			for i in $$(seq 1 120); do kill -0 $$(cat $(HANDLER_PID)) 2>/dev/null || break; sleep 0.5; done; \
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
	@if $(call pid_alive,$(PIDS_DIR)/detector-collector.pid); then \
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

integration-test: ## Feed-handler integration test: real binary against Kafka, 20-item checklist
	@echo "$(BLUE)Running feed-handler integration test (needs 'make kafka-up')...$(NC)"
	@cd $(HANDLER_DIR) && INTEGRATION_TEST=1 go test ./test/integration/... -v -count=1 -timeout=5m

smoke-run: ## Whole chain on a small slice of real data + verification (run before a real run)
	@echo "$(BLUE)Smoke run (needs 'make kafka-up'; uses its own smoke-* topics and results/smoke_*)...$(NC)"
	@if [ ! -x $(PY) ]; then echo "$(RED)✗ $(PY) not found: run 'make setup' first$(NC)"; exit 1; fi
	@$(PY) scripts/smoke_run.py

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

test-stop-all: ## Regression test for stop-all (dummy processes, no Kafka; refuses to run next to a live pipeline)
	@./test-run/test_stop_all.sh

test-stop-all-real: ## Same, plus the REAL handler and detector (collector pid 0); needs kafka-up and built binaries
	@./test-run/test_stop_all.sh --real

test-archive-run: ## Test archive-run on fake module directories in a scratch dir (touches nothing real)
	@./test-run/test_archive_run.sh

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
	@rm -f ./price-feed-simulator/anomaly_log_episodes.csv
	@rm -f ./price-feed-simulator/anomaly_log_instruments.csv
	@rm -rf ./feed-handler/data/eval
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

describe-dataset: ## Profile the dataset (both directories, about 15 minutes) -> docs/dataset_profile/
	@echo "$(BLUE)Profiling the replayed (trading_hours) data and the raw data...$(NC)"
	@if [ ! -x $(PY) ]; then echo "$(RED)✗ $(PY) not found: run 'make setup' first$(NC)"; exit 1; fi
	@$(PY) scripts/describe_dataset.py --data-dir $(SIMULATOR_DIR)/data/trading_hours --output docs/dataset_profile/trading_hours
	@$(PY) scripts/describe_dataset.py --data-dir $(SIMULATOR_DIR)/data --output docs/dataset_profile/raw
	@echo "$(GREEN)✓ Profiles written to docs/dataset_profile/$(NC)"

# One thesis run, start to finish. Order matters:
#   1. rebuild the two Go binaries (a stale binary is the easiest way to waste a run)
#   2. remove the previous run's outputs and reset Kafka (topics + committed offsets)
#   3. handler, detector, monitor, then the simulator in the foreground (stride and playback
#      speed come from the configs and are not touched here)
#   4. "drain": wait until the handler and detector have processed everything the simulator
#      published. Stopping earlier throws away the unprocessed tail of the run.
#   5. stop everything gracefully (the detector must close its parquet file, the handler
#      runs its final silence scan), archive the run under results/thesis_<stamp>/inputs
#      with the configs and git revisions (the separate target archive-run, which can be
#      repeated by hand), and run the verifier.
# Nothing is committed or pushed; stage-by-stage problems show up in the verifier report.
run-thesis-experiment: ## Full run: reset, run, drain, stop, archive to results/thesis_<stamp>, verify
	@echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(BLUE)  Thesis Evaluation Experiment  ($(RUN_STAMP))$(NC)"
	@echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@if [ ! -x $(PY) ]; then echo "$(RED)✗ $(PY) not found: run 'make setup' first$(NC)"; exit 1; fi
	@# keep the machine awake until make exits (a run takes hours)
	@if command -v caffeinate > /dev/null 2>&1; then (caffeinate -i -w $$PPID > /dev/null 2>&1 &); fi
	@echo "$(YELLOW)Building binaries...$(NC)"
	@$(MAKE) build-handler build-simulator
	@echo ""
	@echo "$(YELLOW)Cleaning previous run...$(NC)"
	@$(MAKE) stop-all > /dev/null 2>&1 || true
	@$(MAKE) clean-output-files > /dev/null 2>&1
	@echo "$(GREEN)✓ Cleaned$(NC)"
	@echo ""
	@echo "$(YELLOW)Starting infrastructure and resetting topics...$(NC)"
	@$(MAKE) kafka-up > /dev/null 2>&1
	@$(MAKE) kafka-reset
	@echo ""
	@echo "$(YELLOW)Starting handler, detector and monitor...$(NC)"
	@mkdir -p $(PIDS_DIR) $(LOGS_DIR)
	@$(MAKE) run-handler
	@sleep 5
	@$(MAKE) run-detector
	@sleep 5
	@(./scripts/monitor_pipeline.sh > /dev/null 2>&1 &)
	@echo "$(GREEN)✓ Handler, detector and monitor running$(NC)"
	@echo "  Logs: tail -f $(LOGS_DIR)/handler.log $(LOGS_DIR)/detector-multi.log $(LOGS_DIR)/monitor.log"
	@echo ""
	@echo "$(YELLOW)Running simulator with anomaly injection (foreground)...$(NC)"
	@echo "  $(BLUE)Progress: tail -f logs/simulator.log$(NC)"
	@cd $(SIMULATOR_DIR) && ./bin/simulator -config config/simulator-with-anomalies.yaml > $(LOGS_DIR)/simulator.log 2>&1 \
		|| { echo "$(RED)✗ Simulator failed; last lines of logs/simulator.log:$(NC)"; tail -20 $(LOGS_DIR)/simulator.log; $(MAKE) stop-all > /dev/null 2>&1; exit 1; }
	@echo "$(GREEN)✓ Simulator run complete$(NC)"
	@echo ""
	@echo "$(YELLOW)Waiting for the handler and detector to process everything...$(NC)"
	@$(MAKE) drain \
		|| { echo "$(RED)✗ Drain did not finish; stopping. Outputs are NOT archived.$(NC)"; $(MAKE) stop-all > /dev/null 2>&1; exit 1; }
	@echo ""
	@echo "$(YELLOW)Stopping pipeline components (graceful)...$(NC)"
	@$(MAKE) stop-all
	@echo ""
	@# archiving is its own target (archive-run) so it can be repeated by hand if this step fails;
	@# ARCHIVE_DIR is passed explicitly because a sub-make would compute a new RUN_STAMP
	@$(MAKE) archive-run ARCHIVE_DIR=$(NEW_RUN_DIR) \
		|| echo "$(RED)✗ Archiving failed; the outputs are still in the module data/ directories. Fix the cause and run: make archive-run ARCHIVE_DIR=$(NEW_RUN_DIR)$(NC)"
	@echo ""
	@$(MAKE) verify-run RUN_DIR=$(NEW_RUN_DIR) || echo "$(RED)✗ The verifier reported FAILED checks: read $(NEW_RUN_DIR)/verify_*.txt before evaluating$(NC)"
	@echo ""
	@echo "$(GREEN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(GREEN)  Experiment complete: $(NEW_RUN_DIR)$(NC)"
	@echo "$(GREEN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "Next: make evaluate-thesis   (uses $(RESULTS_DIR)/latest)"
	@echo ""

drain: ## Wait until the handler and detector have processed everything the simulator published
	@# Run after the simulator has finished and BEFORE stop-all: stopping earlier throws away the
	@# unprocessed tail. Three stages: handler has consumed raw-ticks; detector has consumed
	@# normalized-vectors (and no new vectors appear); no scores file (any model) is still growing.
	@T0=$$(date +%s); \
	state() { $(KAFKA_EXEC) kafka-consumer-groups --bootstrap-server $(KAFKA_BS) --describe --group $$1 2>/dev/null \
		| awk -v t=$$2 '$$2==t {n++; lag+=($$6=="-")?$$5:$$6; end+=$$5} END {if (n==0) print "-1 -1"; else print lag, end}'; }; \
	late() { [ $$(( $$(date +%s) - T0 )) -lt $(DRAIN_TIMEOUT) ] || { echo "$(RED)✗ timed out after $(DRAIN_TIMEOUT)s$(NC)"; exit 1; }; }; \
	set -- $$(state $(HANDLER_GROUP) raw-ticks); \
	[ "$$2" -gt 0 ] || { echo "$(RED)✗ nothing was published to raw-ticks (or the handler's consumer group does not exist)$(NC)"; exit 1; }; \
	echo "simulator published $$2 messages; waiting for the feed-handler..."; \
	while [ "$$1" != "0" ]; do \
		late; echo "  handler lag: $$1"; sleep 15; set -- $$(state $(HANDLER_GROUP) raw-ticks); \
		[ "$$1" -ge 0 ] || { echo "$(RED)✗ handler consumer group disappeared$(NC)"; exit 1; }; \
	done; \
	echo "$(GREEN)  handler done$(NC); waiting for the detector..."; \
	STABLE=0; PREV=""; \
	set -- $$(state $(DETECTOR_GROUP) normalized-vectors); \
	while [ $$STABLE -lt 3 ]; do \
		late; \
		[ "$$1" -ge 0 ] || { echo "$(RED)✗ detector consumer group not found: is the detector running? (logs/detector-multi.log)$(NC)"; exit 1; }; \
		if [ "$$1" = "0" ] && [ "$$2" = "$$PREV" ]; then STABLE=$$((STABLE+1)); else STABLE=0; fi; \
		PREV=$$2; echo "  detector lag: $$1 (vectors on topic: $$2)"; sleep 10; \
		set -- $$(state $(DETECTOR_GROUP) normalized-vectors); \
	done; \
	echo "$(GREEN)  detector done$(NC); waiting for the scores file to settle..."; \
	STABLE=0; PREV=-1; \
	while [ $$STABLE -lt 3 ]; do \
		late; SZ=$$(stat -f %z $(DETECTOR_DIR)/data/*.parquet 2>/dev/null | paste -sd+ - | bc); SZ=$${SZ:-0}; \
		if [ "$$SZ" = "$$PREV" ]; then STABLE=$$((STABLE+1)); else STABLE=0; fi; \
		PREV=$$SZ; sleep 10; \
	done; \
	[ "$$PREV" -gt 0 ] || { echo "$(RED)✗ the detector wrote no scores to $(DETECTOR_DIR)/data (logs/detector-multi.log)$(NC)"; exit 1; }; \
	echo "$(GREEN)✓ Everything the simulator published has been processed$(NC)"

# Copy a finished run's raw outputs from the module directories into ARCHIVE_DIR/inputs: the
# simulator's ground truth, the handler's alert logs, the scores, the logs, the configs and the
# git revisions; then repoint results/latest. It is a separate target so it can be repeated on
# its own if the end of run-thesis-experiment fails:
#     make archive-run ARCHIVE_DIR=results/thesis_<stamp>      (default: a new thesis_<now> dir)
# Run it BEFORE the next run-thesis-experiment, which deletes these files (clean-output-files).
# It copies everything it can, then exits 1 if an essential file was missing. It refuses to
# overwrite an archive whose scores file has a different size (a different run) unless FORCE=1.
# versions.txt records the repositories as they are when this runs. If you run it by hand
# long after the run, uncommitted-file counts may differ from what was used.
archive-run: ## Copy the last run's outputs, logs, configs and git revisions into ARCHIVE_DIR/inputs (default: new results/thesis_<stamp>)
	@echo "$(YELLOW)Archiving the run to $(ARCHIVE_DIR)/inputs ...$(NC)"
	@for f in $(DETECTOR_DIR)/data/*.parquet; do \
		[ -f "$$f" ] || continue; \
		a=$(ARCHIVE_DIR)/inputs/$$(basename $$f); \
		if [ -f "$$a" ] && [ "$$(stat -f %z $$a)" != "$$(stat -f %z $$f)" ] && [ "$(FORCE)" != "1" ]; then \
			echo "$(RED)✗ $$a already holds a different scores file (another run?). Not overwriting; pass FORCE=1 to override.$(NC)"; exit 1; \
		fi; \
	done
	@mkdir -p $(ARCHIVE_DIR)/inputs/logs $(ARCHIVE_DIR)/inputs/config
	@MISSING=0; \
	cp $(SIMULATOR_DIR)/anomaly_log.csv $(SIMULATOR_DIR)/anomaly_log_episodes.csv $(SIMULATOR_DIR)/anomaly_log_instruments.csv $(ARCHIVE_DIR)/inputs/ \
		|| { echo "$(RED)✗ simulator ground-truth files missing$(NC)"; MISSING=1; }; \
	cp $(SIMULATOR_DIR)/data/injection_manifest.json $(ARCHIVE_DIR)/inputs/ \
		|| { echo "$(RED)✗ manifest missing$(NC)"; MISSING=1; }; \
	cp $(HANDLER_DIR)/data/eval/*.csv $(ARCHIVE_DIR)/inputs/ \
		|| { echo "$(RED)✗ handler alert logs missing$(NC)"; MISSING=1; }; \
	N=0; \
	for f in $(DETECTOR_DIR)/data/*.parquet; do \
		[ -f "$$f" ] || continue; \
		cp "$$f" $(ARCHIVE_DIR)/inputs/ && { N=$$((N+1)); echo "  scores archived: $$(basename $$f)"; } \
			|| { echo "$(RED)✗ could not copy $$f$(NC)"; MISSING=1; }; \
	done; \
	[ $$N -gt 0 ] || { echo "$(RED)✗ scores file missing: no .parquet in $(DETECTOR_DIR)/data$(NC)"; MISSING=1; }; \
	cp $(LOGS_DIR)/*.log $(ARCHIVE_DIR)/inputs/logs/ 2>/dev/null || true; \
	cp $(SIMULATOR_DIR)/config/simulator-with-anomalies.yaml $(HANDLER_DIR)/config/aggregator.yaml $(DETECTOR_DIR)/config/baselines.yaml $(ARCHIVE_DIR)/inputs/config/ \
		|| { echo "$(RED)✗ config files missing$(NC)"; MISSING=1; }; \
	{ for d in . $(SIMULATOR_DIR) $(HANDLER_DIR) $(DETECTOR_DIR); do \
		echo "$$d: $$(git -C $$d rev-parse --short HEAD) $$(git -C $$d status --porcelain | wc -l | tr -d ' ') uncommitted files"; \
	done; } > $(ARCHIVE_DIR)/inputs/versions.txt; \
	ln -sfn $(notdir $(ARCHIVE_DIR)) $(RESULTS_DIR)/latest; \
	if [ $$MISSING -ne 0 ]; then \
		echo "$(RED)✗ Archive incomplete: $(ARCHIVE_DIR)/inputs is missing files (see above)$(NC)"; exit 1; \
	fi; \
	echo "$(GREEN)✓ Archived; $(RESULTS_DIR)/latest -> $(notdir $(ARCHIVE_DIR))$(NC)"

# archive-run, drain, verify-run and evaluate-thesis are model-agnostic: they work on every
# *.parquet the detector wrote to its data/ dir (scores_<model>.parquet -> model "<model>").
# MODEL=<name> restricts verify-run / evaluate-thesis to one model. A failure on one model does
# not stop the others; the target exits 1 at the end if any model failed.
# Still hardcoded / not covered (PROPOSAL, not active): clean-output-files only deletes the five
# known scores_*.parquet names (a new detector's file would survive into the next run:
# `rm -f ./rrcf-detector/data/*.parquet` would cover it), and test-run/test_archive_run.sh seeds
# only scores_rrcf.parquet.

verify-run: ## PASS/WARN/FAIL report per model on an archived run (RUN_DIR=..., MODEL=... optional)
	@echo "$(BLUE)Verifying $(RUN_DIR) against the live Kafka topics...$(NC)"
	@if [ ! -d $(RUN_DIR)/inputs ]; then echo "$(RED)✗ $(RUN_DIR)/inputs not found (run make run-thesis-experiment first)$(NC)"; exit 1; fi
	@STATUS=0; N=0; \
	for s in $(RUN_DIR)/inputs/$(if $(MODEL),scores_$(MODEL),*).parquet; do \
		[ -f "$$s" ] || continue; N=$$((N+1)); \
		m=$$(basename $$s .parquet); m=$${m#scores_}; \
		echo "$(BLUE)── model: $$m ──$(NC)"; \
		( cd $(DETECTOR_DIR) && ./venv/bin/python3 scripts/verify_run.py \
			--manifest ../$(RUN_DIR)/inputs/injection_manifest.json \
			--episodes ../$(RUN_DIR)/inputs/anomaly_log_episodes.csv \
			--instruments ../$(RUN_DIR)/inputs/anomaly_log_instruments.csv \
			--silence-log ../$(RUN_DIR)/inputs/silence_alerts.csv \
			--validation-log ../$(RUN_DIR)/inputs/validation_alerts.csv \
			--scores ../$$s \
			--kafka localhost:9092 \
			--json ../$(RUN_DIR)/verify_$$m.json > ../$(RUN_DIR)/verify_$$m.txt 2>&1 ); \
		RC=$$?; cat $(RUN_DIR)/verify_$$m.txt; [ $$RC -eq 0 ] || STATUS=1; \
	done; \
	[ $$N -gt 0 ] || { echo "$(RED)✗ no scores parquet in $(RUN_DIR)/inputs$(if $(MODEL), (MODEL=$(MODEL)))$(NC)"; exit 1; }; \
	exit $$STATUS

evaluate-thesis: ## Evaluate every model of an archived run (RUN_DIR=..., MODEL=... optional; TARGET_FAR, THRESHOLDS)
	@echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(BLUE)  Thesis Evaluation: RQ1 + RQ2   ($(RUN_DIR))$(NC)"
	@echo "$(BLUE)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo ""
	@if [ ! -d $(RUN_DIR)/inputs ]; then echo "$(RED)✗ $(RUN_DIR)/inputs not found (run make run-thesis-experiment first)$(NC)"; exit 1; fi
	@# the alert threshold is picked on the clean days (--target-far), never on the injected data
	@STATUS=0; N=0; \
	for s in $(RUN_DIR)/inputs/$(if $(MODEL),scores_$(MODEL),*).parquet; do \
		[ -f "$$s" ] || continue; N=$$((N+1)); \
		m=$$(basename $$s .parquet); m=$${m#scores_}; \
		echo "$(BLUE)── evaluating model: $$m ──$(NC)"; \
		( cd $(DETECTOR_DIR) && ./venv/bin/python3 scripts/evaluate_thesis.py \
			--episodes ../$(RUN_DIR)/inputs/anomaly_log_episodes.csv \
			--instruments ../$(RUN_DIR)/inputs/anomaly_log_instruments.csv \
			--scores ../$$s --method-name $$m \
			--silence-log ../$(RUN_DIR)/inputs/silence_alerts.csv \
			--validation-log ../$(RUN_DIR)/inputs/validation_alerts.csv \
			--thresholds $(THRESHOLDS) --target-far $(TARGET_FAR) \
			--output ../$(RUN_DIR)/evaluation/$$m ) || { echo "$(RED)✗ evaluation of $$m failed$(NC)"; STATUS=1; }; \
	done; \
	[ $$N -gt 0 ] || { echo "$(RED)✗ no scores parquet in $(RUN_DIR)/inputs$(if $(MODEL), (MODEL=$(MODEL)))$(NC)"; exit 1; }; \
	exit $$STATUS
	@echo ""
	@echo "$(GREEN)✓ Evaluation complete: $(RUN_DIR)/evaluation/<model>  (compare models: make compare-models)$(NC)"

compare-models: ## Side-by-side table of every evaluated model (RUN_DIR=..., default results/latest) -> evaluation/comparison.{csv,md}
	@python3 scripts/compare_models.py $(RUN_DIR) $(if $(MODELS),--models $(MODELS))

thesis-full: run-thesis-experiment evaluate-thesis ## Complete workflow: run + verify + evaluate
	@echo ""
	@echo "$(GREEN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(GREEN)  Thesis Evaluation Complete!$(NC)"
	@echo "$(GREEN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
