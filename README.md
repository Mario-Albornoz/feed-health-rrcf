# Market Data Anomaly Detection Pipeline

A complete end-to-end system for detecting anomalies in high-frequency market data using RRCF (Robust Random Cut Forest) and other streaming algorithms.

## Overview

This pipeline consists of three main components:

1. **Price Feed Simulator** (Go) - Reads DEBS 2022 dataset and publishes raw market ticks to Kafka
2. **Feed Handler** (Go) - Consumes raw ticks, normalizes them using learned baselines, and publishes feature vectors
3. **RRCF Detector** (Python) - Consumes normalized vectors and performs real-time anomaly detection using multiple models (RRCF, Z-Score, Isolation Forest, Half-Space Trees, Online-iForest)

```
┌─────────────────────┐     ┌─────────────────┐     ┌──────────────────┐
│ Price Feed          │────▶│ Feed Handler    │────▶│ Multi-Model      │
│ Simulator           │     │ (Aggregator)    │     │ Detector         │
│                     │     │                 │     │                  │
│ • Reads CSV data    │     │ • Normalizes    │     │ • RRCF           │
│ • Publishes to      │     │   ticks         │     │ • Z-Score        │
│   raw-ticks         │     │ • Computes      │     │ • Isolation      │
│                     │     │   z-scores      │     │   Forest         │
│                     │     │ • Session       │     │ • Half-Space     │
│                     │     │   detection     │     │   Trees          │
│                     │     │                 │     │ • Online-iForest │
└─────────────────────┘     └─────────────────┘     └──────────────────┘
         │                           │                         │
         └───────────────────────────┴─────────────────────────┘
                                     │
                          ┌──────────┴──────────┐
                          │  Kafka               │
                          │  (Docker)            │
                          └─────────────────────┘
```

## Prerequisites

- **Go** 1.22+ (for simulator and feed-handler)
- **Python** 3.12 (for rrcf-detector - tested on 3.12.4)
- **Docker** and **Docker Compose** (for Kafka)
- **Make** (build automation)

## Quick Start

### 1. Setup (First Time Only)

Install dependencies and build all components:

```bash
make setup
```

This will:
- Build the Go binaries (simulator and aggregator)
- Create Python virtual environment
- Install Python dependencies

### 2. Start Infrastructure

Start Kafka and Zookeeper:

```bash
make kafka-up
```

Wait for the message: `✓ Infrastructure ready`

### 3. Run the Pipeline

Run all three components in the correct order:

```bash
make run-all
```

This will:
1. Start the feed-handler (background)
2. Wait 5 seconds for handler to initialize
3. Start the detector pipeline (background):
   - Stream collector (saves Parquet files to `data/`)
   - Multi-model runner (RRCF, Z-Score, Isolation Forest, Half-Space Trees, Online-iForest)
4. Start the pipeline monitor
5. Start the simulator (foreground)

The simulator will run in the foreground and show real-time statistics. Results are saved to `data/` directory.

**Press `Ctrl+C`** to stop the simulator when done.

> `make run-all` is the general-purpose run: it does not reset Kafka, wait for the pipeline to drain or
> archive anything. For the thesis experiment use the workflow in **Thesis Evaluation** below
> (`make run-thesis-experiment` / `make thesis-full`).

### 4. Stop Everything

Stop all pipeline components:

```bash
make stop-all
```

Stop the infrastructure:

```bash
make kafka-down
```

## Detailed Commands

### Infrastructure Management

```bash
make kafka-up          # Start Kafka + Zookeeper
make kafka-down        # Stop Kafka + Zookeeper (removes volumes)
make kafka-logs        # View Kafka logs
make kafka-status      # Check service status
make kafka-reset       # Delete and recreate the pipeline topics + consumer offsets (empty start)
```

`kafka-reset` is what makes a run start from nothing: it deletes `raw-ticks`, `normalized-vectors`,
`health-events` and `anomaly-scores` and the two consumers' committed offsets, then recreates the
topics (4 partitions, 1 for `health-events`, 2 h retention, as in `docker-compose.yml`). `kafka-up`
alone keeps whatever an earlier run left in the topics. `run-thesis-experiment` calls it for you.

### Pipeline Execution

```bash
make run-all           # Run complete pipeline (recommended)
make run-handler       # Run feed-handler only (background)
make run-detector      # Run multi-model detector pipeline (background)
make run-simulator     # Run simulator only (foreground)
make drain             # Wait until the handler and detector processed everything (see below)
make stop-all          # Stop all components (gracefully: waits for the detector and handler to exit)
make status            # Show status of all components
```

`make stop-all` sends SIGTERM and then **waits** (up to 2 min for the detector, 1 min for the handler)
before forcing a kill, because the detector has to close its parquet file (the footer is written on
close; a killed file is unreadable) and the handler runs a final silence scan. Never stop a run with
`kill -9`.

`make drain` is for the moment after the simulator has finished: the handler and detector are
usually still working through the backlog in Kafka. It waits for (1) the handler to consume
everything in `raw-ticks`, (2) the detector to consume everything in `normalized-vectors`, (3) the
scores file to stop growing. It fails if nothing was published, if a consumer group is missing, or
after `DRAIN_TIMEOUT` seconds (default 21600). Only then is it safe to `stop-all`.

**Note**: `make run-detector` starts `scripts/run_multi_model.py` with `config/baselines.yaml`.
The models it runs are hard-coded in `_init_models` of that script (only `rrcf` is active; the
baselines are commented out there; the `models:` list in `baselines.yaml` is not read by it). Each
model writes its own `rrcf-detector/data/scores_<model>.parquet`. The stream collector is disabled in
`scripts/start_detector.sh`.

For standalone RRCF only: `cd rrcf-detector && python main.py`

### Anomaly Injection (Testing)

To test anomaly detection with injected anomalies:

```bash
# Use the anomaly injection config
cd price-feed-simulator
./bin/simulator -config config/simulator-with-anomalies.yaml
```

### Monitoring

```bash
make logs              # Tail all pipeline logs
make status            # Show component status

# Or view individual logs:
tail -f logs/handler.log
tail -f logs/simulator.log
tail -f logs/detector-collector.log  # Stream collector logs
tail -f logs/detector-rrcf.log       # RRCF model logs
tail -f logs/detector-zscore.log     # Z-Score model logs
```

**Note**: All components now log to files in the `logs/` directory for complete log capture.

**Pipeline Monitor**: The `scripts/monitor_pipeline.sh` script automatically monitors pipeline health when using `make run-all`.

**Results & Evaluation**: Detection results and evaluation data are saved to the `data/` directory in Parquet format for analysis.

### Testing

```bash
make test              # Run all unit tests for all components
make integration-test  # Feed-handler integration test: real aggregator binary against Kafka (needs make kafka-up)
make smoke-run         # Whole chain on a small slice of real data, then verify + evaluate (needs make kafka-up)
make test-integration  # Older shell-based pipeline test (30s)
```

`make integration-test` builds and starts the real aggregator, publishes simulator-format messages
and prints a 20-item PASS/FAIL checklist (price crosses the wire, quarantine, silence reported once,
sequence numbers, graceful shutdown, ...). `make smoke-run` runs the real simulator, Kafka, handler
and detector on ~600,000 rows with all four phases injected into that slice, on its own `smoke-*` topics,
and writes `results/smoke_<stamp>/` (`report.txt`, `verify.json`, `evaluation/`, logs). It takes a few
minutes and touches nothing else. **Run both before a real run**; their numbers are a sanity check on a
tiny slice, not results.

#### Integration Test

The `test-integration` target runs a comprehensive end-to-end test:
- Verifies all prerequisites
- Starts all components in order
- Monitors for 30 seconds
- Tests stop-all functionality
- Analyzes logs for errors
- Generates detailed report

See `test-run/README.md` for full documentation.

#### Component-Specific Testing

**Go Components (Simulator & Handler)**:
```bash
# Unit tests (co-located with code in internal/**/*_test.go)
cd price-feed-simulator && go test ./internal/... -v
cd feed-handler && go test ./internal/... -v

# With race detection
go test ./internal/... -v -race

# With coverage
go test ./internal/... -v -cover

# Handler integration test (requires Kafka; from the repo root)
make kafka-up
make integration-test

# Simulator benchmarks
cd price-feed-simulator && make benchmark
```

**Python Component (Detector)**:
```bash
cd rrcf-detector

# Activate virtual environment
source venv/bin/activate

# Run all tests with pytest
pytest tests/ -v

# Run specific test modules
pytest tests/test_detect5_baselines.py -v

# With coverage
pytest tests/ -v --cov=src --cov-report=html

# Integration tests
python scripts/test_integration.py
```

**Test Frameworks**:
- **Go**: Standard `testing` package with `go test`
- **Python**: `pytest` with `pytest-cov` for coverage

### Cleanup

```bash
make clean-output-files # Remove the working outputs of the last run (scores, anomaly logs, episodes, alert logs, logs/*.log)
make clean             # Remove build artifacts and logs
make clean-all         # Full cleanup (includes Docker volumes and venv)
```

## Viewing Results

The multi-model detector pipeline saves evaluation results to the `data/` directory in Parquet format. These files contain:
- Anomaly scores from all models
- Timestamps and instrument metadata
- Alert levels and statistical metrics

You can analyze results using Python:

```python
import pandas as pd

# Load results
df = pd.read_parquet('data/anomaly_results.parquet')

# View summary statistics
print(df.groupby('model')['raw_score'].describe())

# Filter high-severity anomalies
high_alerts = df[df['alert_level'] == 'high']
```

## Architecture Details

### Data Flow

1. **Simulator → Kafka (`raw-ticks`)**
   - Reads DEBS 2022 CSV files
   - Publishes at 700k+ ticks/second
   - JSON format with bid/ask/volume/timestamp

2. **Handler → Kafka (`normalized-vectors`)**
   - Consumes from `raw-ticks`
   - Learns per-instrument baselines
   - Computes z-scores and CUSUM values
   - Emits normalized feature vectors

3. **Detector → Kafka (`anomaly-scores`)**
   - Consumes from `normalized-vectors`
   - Runs multiple detection models in parallel:
     - **RRCF** (Robust Random Cut Forest)
     - **Z-Score** baseline
     - **Isolation Forest** baseline
     - **Half-Space Trees** baseline
     - **Online-iForest** baseline
   - Publishes anomaly scores with alert levels
   - Stream collector saves results to Parquet files

4. **Handler → Kafka (`health-events`)**
   - Feed silence detection
   - Quote inversion alerts
   - System health monitoring

### Kafka Topics

| Topic                | Producer      | Consumer      | Description                    |
|----------------------|---------------|---------------|--------------------------------|
| `raw-ticks`          | Simulator     | Handler       | Raw market data ticks          |
| `normalized-vectors` | Handler       | Detector      | Normalized feature vectors     |
| `anomaly-scores`     | Detector      | (External)    | Anomaly detection results      |
| `health-events`      | Handler       | (External)    | System health alerts           |

All topics are created automatically with 4 partitions (except `health-events` with 1 partition).

### Configuration

Each component has its own configuration file:

- **Simulator**: `price-feed-simulator/config/simulator.yaml`
- **Handler**: `feed-handler/config/aggregator.yaml`
- **Detector**: 
  - Standalone: `rrcf-detector/config/default.yaml`
  - Multi-model (used by `make run-detector`): `rrcf-detector/config/baselines.yaml`
  - Additional Kafka settings: `rrcf-detector/kafka_config.yaml`

#### Key Settings

**Simulator** (`price-feed-simulator/config/simulator.yaml`):
```yaml
kafka:
  topic: "raw-ticks"
simulator:
  mode: "realtime"          # realtime | accelerated | fullspeed
  acceleration_factor: 1.0  # Use > 1 for faster replay
  data_dir: "data"
```

**Handler** (`feed-handler/config/aggregator.yaml`):
```yaml
kafka:
  input_topic: "raw-ticks"
  output_topic: "normalized-vectors"
windows:
  fast_window_ticks: 60      # Fast EMA window
  slow_window_ticks: 14400   # Slow EMA window
```

**Detector** (`rrcf-detector/config/default.yaml` for standalone, `config/baselines.yaml` for multi-model):
```yaml
# default.yaml - Single RRCF model
service:
  num_workers: 4
detector:
  window_size: 1000
kafka:
  input_topic: "normalized-vectors"
  output_topic: "anomaly-scores"

# baselines.yaml - Multi-model configuration (used by make run-detector)
models:
  - name: "rrcf"
    window_size: 1000
  - name: "zscore"
    window_size: 500
  - name: "iforest"
  - name: "hstrees"
  - name: "online_iforest"
```

## Data Requirements

### DEBS 2022 Dataset

Place DEBS 2022 CSV files in `price-feed-simulator/data/`:

```bash
price-feed-simulator/data/
├── debs2022-gc-trading-day-01-11-21.csv
├── debs2022-gc-trading-day-02-11-21.csv
└── ...
```

**Download**: https://doi.org/10.5281/zenodo.6382482

**Format**: CSV with columns for ID, SecType, Bid, Ask, ISIN, TradingTime, TotalVolume

## Troubleshooting

### Kafka Connection Issues

```bash
# Check if Kafka is running
make kafka-status

# View Kafka logs
make kafka-logs

# Restart Kafka
make kafka-down
make kafka-up
```

### Pipeline Not Starting

```bash
# Check component status
make status

# View logs
make logs

# Or individual logs
tail -f logs/handler.log
tail -f logs/detector.log
```

### Python Import Errors

```bash
# Recreate virtual environment
cd rrcf-detector
rm -rf venv
cd ..
make setup-detector
```

### Go Build Errors

```bash
# Clean and rebuild
make clean
make build-simulator
make build-handler
```

### "No data" or Low Throughput

- Ensure CSV files are in `price-feed-simulator/data/`
- Check simulator mode in config (use `fullspeed` for maximum throughput)
- Verify Kafka is healthy: `make kafka-status`

## Performance Expectations

- **Simulator**: 700k+ ticks/second
- **Handler**: Real-time processing with sub-millisecond latency
- **Detector**: 
  - Single RRCF model: ~50k-100k vectors/second per worker (4 workers default)
  - Multi-model pipeline: Runs all 5 models in parallel processes
  - Results saved to Parquet for offline analysis

## Project Structure

```
Thesis/
├── Makefile                    # Main orchestration
├── docker-compose.yml          # Infrastructure setup
├── README.md                   # This file
├── .gitignore                  # Unified gitignore
├── .gitmodules                 # Git submodule configuration
│
├── scripts/                    # Orchestration scripts
│   └── monitor_pipeline.sh    # Pipeline health monitor
│
├── logs/                       # Runtime logs (created automatically)
│   ├── handler.log
│   ├── detector-collector.log
│   ├── detector-rrcf.log
│   └── detector-*.log         # Per-model logs
│
├── data/                       # Evaluation outputs (Parquet files)
│
├── test-run/                   # Integration testing
│   ├── README.md              # Test documentation
│   ├── test_pipeline.sh       # Integration test script
│   ├── test_execution.log     # Test run logs (generated)
│   └── test_results.txt       # Test results (generated)
│
├── price-feed-simulator/       # Component 1: Data source
│   ├── cmd/simulator/
│   ├── internal/
│   ├── test/
│   │   ├── integration/
│   │   └── benchmark/
│   ├── config/
│   │   ├── simulator.yaml
│   │   └── simulator-with-anomalies.yaml
│   ├── data/                  # Place CSV files here
│   └── bin/
│
├── feed-handler/               # Component 2: Normalization
│   ├── cmd/aggregator/
│   ├── internal/
│   ├── test/integration/
│   ├── config/
│   ├── data/                  # Registry persistence
│   └── docker-compose.test.yml
│
└── rrcf-detector/              # Component 3: Anomaly detection
    ├── src/
    │   ├── detection/
    │   ├── baselines/
    │   ├── kafka/
    │   ├── multiprocessing/
    │   └── partitioning/
    ├── scripts/
    │   ├── run_multi_model.py
    │   ├── stream_collector.py
    │   └── test_integration.py
    ├── tests/
    ├── config/
    │   ├── default.yaml        # Standalone RRCF config
    │   └── baselines.yaml      # Multi-model config
    ├── venv/                   # Created by make setup
    └── main.py                 # Standalone RRCF entry point
```

## Additional Resources

### Documentation Files

- **Main README**: `README.md` (this file)
- **Price Feed Simulator**: 
  - `price-feed-simulator/README.md` - Component overview and usage
  - `price-feed-simulator/TESTING_GUIDE.md` - Testing procedures
  - `price-feed-simulator/ANOMALY_INJECTION.md` - Anomaly injection details
- **Feed Handler**: 
  - `feed-handler/README.md` - Component overview and usage
  - `feed-handler/test/integration/README.md` - Integration test details
- **RRCF Detector**: 
  - `rrcf-detector/README.md` - Component overview and usage
  - `rrcf-detector/WORKFLOW_GUIDE.md` - Development workflow
  - `rrcf-detector/docs/RUNNING.md` - Running instructions
  - `rrcf-detector/config/README.md` - Configuration guide

## License

Components use different licenses:
- DEBS 2022 Dataset: CC BY-NC-SA 4.0
- Individual components: See respective directories

## Support

For issues or questions:
1. Check component-specific READMEs
2. Review logs with `make logs`
3. Check Kafka status with `make kafka-status`
4. Ensure all prerequisites are installed

---

## Thesis Evaluation

### What this does

The experiment replays the DEBS 2022 days (8-12 Nov 2021) through the whole pipeline while the
simulator injects anomalies on some days, then measures how well each anomaly is detected.

- **RQ1**: can the two-timescale adaptive RRCF detect all four phases of feed degradation?
- **RQ2**: how does it compare with baselines? (**not wired into `make` yet**: the baselines have
  not been run through the new protocol; only RRCF is run and evaluated by the targets below.)

| Day (Nov 2021) | What is injected | Who detects it |
|---|---|---|
| 08 | nothing (clean warm-up) | - |
| 09 | Phase 1: tick-rate decline (40% of instruments, rate falls 100% -> 30%, 09:30-14:00) | RRCF |
| 10 | Phase 2: contextual price anomalies on last traded price (09:30-15:00); Phase 3: 120 s feed silence on 70% of the `ETR` instruments (15:30-16:00) | RRCF (phase 2), silence detector in the feed-handler (phase 3) |
| 11 | Phase 4: implausible prices (RRCF) and timestamp rewinds (validator in the feed-handler), 09:30-15:30 | RRCF / validator |
| 12 | nothing (clean, used to set the alert threshold) | - |

The schedule and densities live in `price-feed-simulator/config/simulator-with-anomalies.yaml`.
Design, reasons and measurements are in `docs/EVALUATION_METHODOLOGY.md`.

**Do not lower the worker stride (1 vector in 10 is scored, `rrcf-detector/src/detection/generic_worker.py`)
and do not slow the playback.** Both are deliberate CPU workarounds; the evaluation is built around them.

### Before you start (once)

1. **Prerequisites**: Docker (running), Go, Python 3.12 (`brew install python@3.12`), and the data
   in `price-feed-simulator/data/` (raw day files) and `price-feed-simulator/data/trading_hours/`
   (the 09:30-16:00 copies that are actually replayed).
2. `make setup` builds the two Go binaries and creates the detector venv
   (`rrcf-detector/venv`). Needed again after `make clean` / `make clean-all` (which delete them).
3. `make kafka-up` starts Kafka and Zookeeper.
4. Checks, in this order (each is quick):
   ```bash
   make test              # unit tests of the three components
   make integration-test  # feed-handler against real Kafka, 20-item checklist
   make smoke-run         # whole chain on a small slice; read the report it prints
   ```
   Anything FAIL: fix that first; a real run will not fix it.
   (`make smoke-run` may show one warning about how many episode instruments appear in the scores on a
   small slice; that is expected.)

### Running the experiment

```bash
make thesis-full            # = run-thesis-experiment + evaluate-thesis
```

or the two halves separately (recommended for the first real run, so you can read the verifier report
before evaluating):

```bash
make run-thesis-experiment  # the run; ends with the verifier report
make evaluate-thesis        # scores and tables; uses the run it just archived (results/latest)
```

The run takes **hours** (about 200 M rows are replayed; a full run has not been timed). Progress:
`tail -f logs/simulator.log`, `logs/handler.log`, `logs/detector-multi.log`, `logs/monitor.log`.
The Mac is kept awake with `caffeinate` for as long as `make` runs. Keep the terminal open.

`make run-thesis-experiment` does, in this order:

1. **Rebuilds** the feed-handler and simulator binaries (`build-handler`, `build-simulator`). Note that
   this overwrites the tracked `price-feed-simulator/bin/simulator`.
2. **Cleans** the previous run's working files (`stop-all`, `clean-output-files`): scores, `anomaly_log*.csv`,
   `feed-handler/data/eval/`, `logs/*.log`. Archived runs in `results/` are not touched.
3. **Starts Kafka** and runs `kafka-reset` (empty topics, no committed offsets).
4. Starts the **handler**, the **detector** and the **monitor**.
5. Runs the **simulator in the foreground** with `simulator-with-anomalies.yaml` (output in `logs/simulator.log`).
6. Runs `make drain`: waits until the handler and detector have processed everything the simulator published.
7. `make stop-all` (graceful).
8. **Archives** the run (the separate target `make archive-run`, see below) to
   `results/thesis_<timestamp>/inputs/` and points `results/latest` at it:
   - `anomaly_log_episodes.csv` (ground truth, one row per episode, with message `Seq`),
     `anomaly_log_instruments.csv` (rows and trades per instrument per day), `anomaly_log.csv`
     (tick-level log), `injection_manifest.json`
   - `silence_alerts.csv`, `validation_alerts.csv` (the handler's rule-based detectors)
   - `scores_rrcf.parquet` (RRCF scores; large)
   - `logs/`, `config/` (the three configs used) and `versions.txt` (git revision of each repo and
     how many uncommitted files it had)
9. Runs `make verify-run` on it and writes `verify.txt` / `verify.json` next to `inputs/`.

If the simulator fails, or `drain` times out, everything is stopped and **nothing is archived**; the
message says why.

### Reading the verifier report

`make verify-run` (also `make verify-run RUN_DIR=results/thesis_<stamp>` for an older run) prints, per stage
(*Ground truth (simulator)*, *Kafka*, *Kafka: raw messages*, *Kafka: feature vectors*, *Feed-handler
evaluation logs*, *Detector scores*, *Scores meet ground truth*), `PASS`, `WARN`, `FAIL` or `skip`, and for a
WARN/FAIL what was expected and a hint about the likely cause. Rule of thumb:

- **FAIL**: do not evaluate; the hint names the stage that broke (e.g. no episodes, messages lost
  between Kafka topics, scores missing for the injected instruments).
- **WARN**: read it; some are expected (see the methodology chapter), some mean a run is thinner than planned.
- Kafka topics have 2 h retention; run the verifier soon after the run (the run does it for you).

### Evaluating

```bash
make evaluate-thesis                                     # latest run
make evaluate-thesis RUN_DIR=results/thesis_20260921_101500   # a specific run
make evaluate-thesis TARGET_FAR=0.5 THRESHOLDS=1,2,3,4       # other settings
```

`TARGET_FAR` (default 1.0) is the false-alarm rate, in alerts per 1000 scored vectors, at which the alert
threshold is fixed. It is chosen on the **clean days** (days with no injected episode; day 12 is the headline,
day 08 is excluded as warm-up but reported), never on the injected data. `THRESHOLDS`
adds a sweep. Output: `results/thesis_<stamp>/evaluation/evaluation_results.json` and `sweep.csv`.
It is safe to run this many times on the same run.

### If something goes wrong

| Symptom | What to do |
|---|---|
| `make ...: rrcf-detector/venv/bin/python3 not found` | `make setup` (the venv is deleted by `make clean-all`) |
| `Kafka is not running` | `make kafka-up` |
| Run interrupted / terminal closed | `make stop-all`, then just start `make run-thesis-experiment` again (it cleans and resets) |
| `drain` timed out or a consumer group is missing | look at `logs/handler.log` / `logs/detector-multi.log`; a stopped consumer never finishes |
| Simulator failed | `tail logs/simulator.log`; the usual causes are missing data files or a Kafka connection |
| Evaluation stops with "No threshold in [...] reaches N alerts per 1000 vectors" | no threshold in `THRESHOLDS` is high enough for `TARGET_FAR`: `make evaluate-thesis THRESHOLDS=1,2,3,4,5,6,8,10` |
| Evaluation says a file is missing | the run was not archived; check `results/latest` and `results/thesis_<stamp>/inputs/`. The outputs are still in the module `data/` directories until the next run: `make archive-run ARCHIVE_DIR=results/thesis_<stamp>` repeats the archive step (it refuses to overwrite an archive that holds a different run's scores unless `FORCE=1`, and exits 1 if an essential file is missing). Then `make verify-run` / `make evaluate-thesis` |
| `make stop-all` printed `Terminated: 15` and killed the run | fixed: a pid file holding `0` (the disabled collector) made `kill 0` signal the whole process group. Regression tests: `make test-stop-all` (dummy processes) and `make test-stop-all-real` (real handler and detector; needs `make kafka-up`) |

### Other commands

```bash
make describe-dataset       # profile the whole dataset -> docs/dataset_profile/ (about 15 minutes)
make kafka-reset            # empty Kafka topics without a run
make drain                  # only the waiting step
make verify-run             # only the verifier
```

Older scripts `scripts/preflight_test.sh`, `scripts/check_kafka_messages.sh` and `test-run/*` (used by
`make test-thesis`) predate this workflow and still look for `scores.parquet` and the old `anomaly_log.csv`
layout; they are not part of the procedure above.

### Configuration

- Injection (days, windows, densities, per-instrument quota): `price-feed-simulator/config/simulator-with-anomalies.yaml`
- Feed-handler (windows, silence quantile rule, validator tolerance, alert logs, session hours): `feed-handler/config/aggregator.yaml`
- Detector (models, windows, Kafka group): `rrcf-detector/config/baselines.yaml`
- Evaluation parameters: command-line options of `rrcf-detector/scripts/evaluate_thesis.py` (`--help`)

### Complete documentation

- `docs/EVALUATION_METHODOLOGY.md` - what is measured and why, the fixes made and the measurements behind them
- `docs/dataset_profile/` - dataset profile
- `price-feed-simulator/ANOMALY_INJECTION.md` - injection details
- `feed-handler/test/integration/README.md` - integration test
