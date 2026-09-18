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
```

### Pipeline Execution

```bash
make run-all           # Run complete pipeline (recommended)
make run-handler       # Run feed-handler only (background)
make run-detector      # Run multi-model detector pipeline (background)
make run-simulator     # Run simulator only (foreground)
make stop-all          # Stop all components
make status            # Show status of all components
```

**Note**: `make run-detector` runs the **multi-model pipeline** including:
- Stream collector (`scripts/stream_collector.py`) - saves Parquet files
- Multi-model runner (`scripts/run_multi_model.py`) - runs all detection models

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
make test-integration  # Run full pipeline integration test (30s)
```

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

# Handler integration tests (requires Kafka via Docker Compose)
cd feed-handler
make kafka-up
make test-integration
make kafka-down

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
