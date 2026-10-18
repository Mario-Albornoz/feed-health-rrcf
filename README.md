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

## How to run

### 1. Clone with the submodules

The simulator, feed-handler and detector are git submodules, so clone with `--recurse-submodules` (without it their folders come down empty):

```bash
git clone --recurse-submodules https://github.com/Mario-Albornoz/feed-health-rrcf.git
cd feed-health-rrcf
```

If you already cloned without it: `git submodule update --init --recursive`.

### 2. Get the dataset

The DEBS 2022 Grand Challenge dataset is not part of the repository. Download the trading-day files for 08, 09, 10, 11 and 12 November 2021 and place them in `price-feed-simulator/data/`:

```
price-feed-simulator/data/
├── debs2022-gc-trading-day-08-11-21.csv
├── debs2022-gc-trading-day-09-11-21.csv
├── debs2022-gc-trading-day-10-11-21.csv
├── debs2022-gc-trading-day-11-11-21.csv
└── debs2022-gc-trading-day-12-11-21.csv
```

### 3. Filter it to trading hours

The simulator replays only regular trading hours (09:30–16:00). This script keeps those rows and writes the filtered copies to `price-feed-simulator/data/trading_hours/`, which is where the thesis run reads from:

```bash
python3 price-feed-simulator/scripts/filter_trading_hours.py
```

It uses only the Python standard library, so any Python 3 works; inside the container it is `make docker-shell`, then the same command. If `data/trading_hours/` already exists, the script asks before replacing it. The original files in `data/` are left untouched.

### 4. Run the pipeline with Docker (any OS)

The runner container (`docker/runner.Dockerfile`) holds the whole toolchain: Go, Python 3.12 with the detector's dependencies, and the Kafka command-line tools. It runs the same Makefile targets on Linux. The repository is bind-mounted, so results, logs and the dataset stay on your disk. The binaries the container builds go into a Docker volume and never overwrite `price-feed-simulator/bin/simulator`.

```bash
make docker-build                         # once, and after requirements.txt changes
make docker-setup                         # build the Go binaries inside the container
make docker-smoke-run                     # few-minute check of the whole chain
make docker-thesis-full                   # the full run: reset, run, drain, archive, verify, evaluate
make docker-evaluate-thesis MODEL=zscore  # any target works as docker-<target>; variables are passed through
make docker-shell                         # a shell in the container
```

Kafka is started automatically when needed; stop it with `make kafka-down` on the host.

Notes:
- `thesis-full` runs for hours in the foreground. Start it inside `tmux`/`screen` (or `nohup make docker-thesis-full > run.log 2>&1 &`), because closing the terminal stops the container.
- On macOS and Windows, Docker Desktop runs containers in a VM. Give it most of your CPU cores and memory (Settings → Resources), or runs will be slower than native. `caffeinate` does not apply inside the container, so keep the Mac awake yourself.
- Timestamps in run names (`results/thesis_<stamp>`) are in UTC inside the container.

### 5. Results and evaluation

Each full run is archived in its own folder, and `results/latest` points to the newest one:

```
results/thesis_<stamp>/
├── inputs/              # everything the run produced: scores_<model>.parquet, the injected-anomaly
│                        # ground truth, handler alerts, logs, configs, git revisions, recorded vectors
├── verify_<model>.txt   # PASS/WARN/FAIL checks of the run (also .json)
└── evaluation/<model>/  # evaluation_results.json and sweep.csv per model
```

The live run scores with the models listed in `rrcf-detector/config/baselines.yaml` (currently `zscore`). The other models are scored afterwards on the recorded vectors of the same run, so every model sees identical input:

```bash
make docker-replay-models MODELS=rrcf_forest,isoforest,halfspace,onlineiforest   # adds inputs/scores_<model>.parquet
make docker-evaluate-thesis                    # evaluate every model that has a scores file
make docker-evaluate-thesis MODEL=rrcf_forest  # or just one
make docker-compare-models                     # side-by-side table -> evaluation/comparison.{csv,md}
make docker-verify-run MODEL=zscore            # re-run the PASS/WARN/FAIL checks
```

`MODEL` is the part after `scores_` in the file name. Every command works on `results/latest` by default; pass `RUN_DIR=results/thesis_<stamp>` for an older run. Replaying over an existing scores file needs `FORCE=1`. The alert threshold is chosen on the clean days at `TARGET_FAR` alerts per 1000 scored vectors (default `1.0`, e.g. `TARGET_FAR=0.5`).

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
