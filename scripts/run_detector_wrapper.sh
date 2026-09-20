#!/bin/bash
# Wrapper to run detector in true background mode

cd "$(dirname "$0")/../rrcf-detector"
PYTHONPATH=. exec venv/bin/python3 -u scripts/run_multi_model.py --config config/baselines.yaml
