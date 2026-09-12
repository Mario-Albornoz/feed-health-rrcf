# Market Data Anomaly Detection Pipeline

A complete end-to-end system for detecting anomalies in high-frequency market data using RRCF (Robust Random Cut Forest) and other streaming algorithms.

## Overview

This pipeline consists of three main components:

1. **Price Feed Simulator** (Go) - Reads DEBS 2022 dataset and publishes raw market ticks to Kafka
2. **Feed Handler** (Go) - Consumes raw ticks, normalizes them using learned baselines, and publishes feature vectors
3. **RRCF Detector** (Python) - Consumes normalized vectors and performs real-time anomaly detection

```
┌─────────────────────┐     ┌─────────────────┐     ┌──────────────────┐
│ Price Feed          │────▶│ Feed Handler    │────▶│ RRCF Detector    │
│ Simulator           │     │ (Aggregator)    │     │                  │
│                     │     │                 │     │                  │
│ • Reads CSV data    │     │ • Normalizes    │     │ • Anomaly        │
│ • Publishes to      │     │   ticks         │     │   detection      │
│   raw-ticks         │     │ • Computes      │     │ • Score          │
│                     │     │   z-scores      │     │   calibration    │
│                     │     │ • Session       │     │                  │
│                     │     │   detection     │     │                  │
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
3. Start the rrcf-detector (background)
4. Wait 5 seconds for detector to initialize
5. Start the simulator (foreground)

The simulator will run in the foreground and show real-time statistics.

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
make run-detector      # Run rrcf-detector only (background)
make run-simulator     # Run simulator only (foreground)
make stop-all          # Stop all components
make status            # Show status of all components
```

### Monitoring

```bash
make logs              # Tail all pipeline logs
make status            # Show component status

# Or view individual logs:
tail -f logs/handler.log
tail -f logs/detector.log
```

### Testing

```bash
make test              # Run all tests for all components
```

### Cleanup

```bash
make clean             # Remove build artifacts and logs
make clean-all         # Full cleanup (includes Docker volumes and venv)
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
   - Runs RRCF algorithm
   - Publishes anomaly scores with alert levels

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
- **Detector**: `rrcf-detector/kafka_config.yaml`, `rrcf-detector/.env`

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

**Detector** (`rrcf-detector/.env`):
```yaml
KAFKA_INPUT_TOPIC=normalized-vectors
KAFKA_OUTPUT_TOPIC=anomaly-scores
NUM_WORKERS=4
RRCF_WINDOW_SIZE=1000
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
- **Detector**: ~50k-100k vectors/second per worker (4 workers default)

## Project Structure

```
Thesis/
├── Makefile                    # Main orchestration
├── docker-compose.yml          # Infrastructure setup
├── README.md                   # This file
├── .gitignore                  # Unified gitignore
│
├── price-feed-simulator/       # Component 1: Data source
│   ├── cmd/simulator/
│   ├── internal/
│   ├── config/
│   ├── data/                   # Place CSV files here
│   └── bin/
│
├── feed-handler/               # Component 2: Normalization
│   ├── cmd/aggregator/
│   ├── internal/
│   ├── config/
│   └── data/
│
├── rrcf-detector/              # Component 3: Anomaly detection
│   ├── src/
│   ├── tests/
│   ├── config/
│   ├── venv/                   # Created by make setup
│   └── main.py
│
└── logs/                       # Runtime logs (created automatically)
    ├── handler.log
    └── detector.log
```

## Additional Resources

- **Price Feed Simulator**: See `price-feed-simulator/README.md`
- **Feed Handler**: See `feed-handler/README.md`
- **RRCF Detector**: See `rrcf-detector/README.md`

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
