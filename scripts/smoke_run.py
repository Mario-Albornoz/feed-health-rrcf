#!/usr/bin/env python3
"""
Smoke run: push a slice of real data through the real pipeline, then check it.

Runs the actual simulator, Kafka, feed-handler and RRCF detector on a slice of one day file
(default 600,000 rows), with all four phases injected into it, using isolated Kafka topics
(smoke-*) and its own output directory. Then it runs the run verifier and the evaluation
on what came out. It answers "does the whole chain work, and where does it not?" in a few
minutes, before committing to a multi-day run.

It also checks the sampled-vector recording: the live detector records the vectors that pass
the stride (rrcf and zscore run live), then the recording is replayed through the same models
in a separate run, which must score exactly the same rows (and, for the deterministic zscore,
the same scores) as the live run. This is what makes models run in separate passes comparable.

Needs Kafka on localhost:9092 (make kafka-up) and the detector venv:

    rrcf-detector/venv/bin/python scripts/smoke_run.py [--rows 600000] [--keep-topics]

Everything lands in results/smoke_<timestamp>/ (report.txt, verify.json, evaluation/, logs).
Nothing outside that directory and the smoke-* topics is touched; the tracked simulator
binary is not rebuilt.
"""

import argparse
import copy
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SIM = ROOT / "price-feed-simulator"
HANDLER = ROOT / "feed-handler"
DETECTOR = ROOT / "rrcf-detector"
BROKER = "localhost:9092"


def log(msg: str) -> None:
    print(f"[{datetime.now():%H:%M:%S}] {msg}", flush=True)


def run(cmd, **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=True, **kw)


# ----------------------------------------------------------------------------- topics


def admin():
    from confluent_kafka.admin import AdminClient

    return AdminClient({"bootstrap.servers": BROKER})


def create_topics(names) -> None:
    from confluent_kafka.admin import NewTopic

    a = admin()
    futures = a.create_topics([NewTopic(n, num_partitions=3 if "alerts" not in n else 1, replication_factor=1) for n in names])
    for n, f in futures.items():
        f.result(timeout=20)
    time.sleep(2)  # leaders


def delete_topics(names) -> None:
    a = admin()
    for n, f in a.delete_topics(list(names)).items():
        try:
            f.result(timeout=20)
        except Exception:  # noqa: BLE001 - best effort cleanup
            pass


def end_offsets(topic: str) -> int:
    sys.path.insert(0, str(DETECTOR / "scripts"))
    import verify_run

    return sum(h - l for l, h in verify_run.topic_offsets(BROKER, topic).values())


def group_lag(group: str, topic: str) -> int:
    """Messages on `topic` not yet committed by consumer group `group`."""
    from confluent_kafka import Consumer, TopicPartition

    c = Consumer({"bootstrap.servers": BROKER, "group.id": group, "enable.auto.commit": False})
    try:
        md = c.list_topics(topic, timeout=10)
        parts = [TopicPartition(topic, p) for p in md.topics[topic].partitions]
        committed = c.committed(parts, timeout=10)
        lag = 0
        for tp in committed:
            low, high = c.get_watermark_offsets(tp, timeout=10)
            lag += high - (tp.offset if tp.offset >= 0 else low)
        return lag
    finally:
        c.close()


# ------------------------------------------------------------------------------- data


def make_slice(src: Path, dest: Path, first_line: int, rows: int) -> tuple:
    """Copy the file's header block and `rows` data rows from `first_line`. Returns the
    first and last update time (seconds since midnight) of the slice."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    header_lines = 0
    with open(src, "rb") as f:
        for line in f:
            header_lines += 1
            if line.startswith(b"ID,"):
                break
    with open(dest, "wb") as out:
        run(["head", "-n", str(header_lines), str(src)], stdout=out)
        p = subprocess.Popen(["sed", "-n", f"{first_line},{first_line + rows - 1}p;{first_line + rows}q", str(src)], stdout=out)
        p.wait()

    def secs(line: bytes) -> int:
        t = line.decode().split(",")[3]
        h, m, s = t.split(":")
        return int(h) * 3600 + int(m) * 60 + int(float(s))

    with open(dest, "rb") as f:
        f.readline()
        for _ in range(header_lines - 1):
            f.readline()
        first = f.readline()
    tail = subprocess.run(["tail", "-n", "1", str(dest)], capture_output=True, check=True).stdout
    return secs(first), secs(tail)


def hms(sec: int) -> str:
    return f"{sec // 3600:02d}:{(sec % 3600) // 60:02d}:{sec % 60:02d}"


# ---------------------------------------------------------------------------- configs


def write_configs(work: Path, topics: dict, span: tuple, day: str, ids: dict) -> dict:
    t0, t1 = span
    length = t1 - t0
    q = lambda f: t0 + int(length * f)  # noqa: E731 - readable enough here

    sim = yaml.safe_load((SIM / "config/simulator-with-anomalies.yaml").read_text())
    sim["kafka"]["topic"] = topics["raw"]
    sim["simulator"]["data_dir"] = str(work / "data")
    sim["simulator"]["file_pattern"] = "debs2022-gc-trading-day-*.csv"
    a = sim["anomaly"]
    a["log_file"] = str(work / "sim" / "anomaly_log.csv")
    windows = {"phase1_tick_rate_decline": (q(0.02), q(0.30)), "phase2_contextual_anomalies": (q(0.32), q(0.60)),
               "phase3_feed_silence": (q(0.62), q(0.75)), "phase4_point_failures": (q(0.77), q(0.98))}
    for key, (s, e) in windows.items():
        a[key]["enabled"] = True
        a[key]["date_filter"] = [day]
        a[key]["window"] = {"start": hms(s), "end": hms(e)}
    # dense injection so a small slice yields episodes; quota needs an earlier day, so off
    for st in a["phase2_contextual_anomalies"]["strategies"]:
        st["probability"] = 0.02
    a["phase2_contextual_anomalies"]["per_instrument_quota"] = {"min_episodes": 0}
    a["phase3_feed_silence"]["blackout_seconds"] = 60
    for st in a["phase4_point_failures"]["strategies"]:
        st["probability"] = 0.02 if st["type"] == "implausible_price" else 0.005
    a["phase4_point_failures"]["per_instrument_quota"] = {"min_episodes": 0}
    (work / "sim").mkdir(parents=True, exist_ok=True)
    (work / "sim" / "data").mkdir(exist_ok=True)  # the manifest is written to ./data
    (work / "sim" / "config.yaml").write_text(yaml.safe_dump(sim, sort_keys=False))

    h = yaml.safe_load((HANDLER / "config/aggregator.yaml").read_text())
    h["kafka"].update(input_topic=topics["raw"], output_topic=topics["vectors"], alert_topic=topics["alerts"],
                      consumer_group=ids["handler"])
    h["alerts"] = {"silence_log": str(work / "handler/eval/silence_alerts.csv"),
                   "validation_log": str(work / "handler/eval/validation_alerts.csv"), "kafka_silence_alerts": False}
    (work / "handler").mkdir(parents=True, exist_ok=True)
    (work / "handler" / "aggregator.yaml").write_text(yaml.safe_dump(h, sort_keys=False))

    d = yaml.safe_load((DETECTOR / "config/baselines.yaml").read_text())
    d["kafka"].update(input_topic=topics["vectors"], output_topic=topics["scores"], consumer_group_id=ids["detector"],
                      auto_offset_reset="earliest")
    d["models"] = ["rrcf", "zscore"]  # zscore is deterministic: its replay must equal its live scores
    (work / "detector").mkdir(parents=True, exist_ok=True)
    (work / "detector" / "baselines.yaml").write_text(yaml.safe_dump(d, sort_keys=False))
    return {"windows": {k: (hms(s), hms(e)) for k, (s, e) in windows.items()}}


# ------------------------------------------------------------------------- processes


def wait_for(path: Path, text: str, timeout: float, proc: subprocess.Popen, what: str) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            raise SystemExit(f"{what} exited early ({proc.returncode}); see {path}")
        if path.exists() and text in path.read_text(errors="replace"):
            return
        time.sleep(0.5)
    raise SystemExit(f"{what} did not report '{text}' within {timeout:.0f}s; see {path}")


def stop(proc: subprocess.Popen, name: str, timeout: float = 30) -> None:
    if proc.poll() is not None:
        return
    proc.send_signal(signal.SIGTERM)
    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        log(f"{name} did not stop in {timeout:.0f}s; killing it")
        proc.kill()


def wait_lag(group: str, topic: str, timeout: float) -> int:
    """Wait until a consumer group has committed everything on the topic (two polls in a
    row, since offsets are auto-committed every few seconds). Returns the remaining lag."""
    deadline = time.time() + timeout
    zero = 0
    lag = -1
    while time.time() < deadline:
        lag = group_lag(group, topic)
        zero = zero + 1 if lag == 0 else 0
        if zero >= 2:
            return 0
        time.sleep(3)
    log(f"warning: {group} still had {lag:,} messages to consume after {timeout:.0f}s")
    return lag


def wait_stable(fn, quiet_seconds: float, timeout: float, what: str) -> int:
    """Poll fn() until its value stops changing for `quiet_seconds`."""
    deadline = time.time() + timeout
    last, since = None, time.time()
    while time.time() < deadline:
        v = fn()
        if v != last:
            last, since = v, time.time()
        elif time.time() - since >= quiet_seconds and v:
            return v
        time.sleep(2)
    log(f"warning: {what} did not settle within {timeout:.0f}s (last value {last})")
    return last or 0


def check_sample_and_replay(work: Path, topics: dict, models: list) -> list:
    """Check the recorded vector sample, then replay it through `models` in a separate run
    and compare with the live scores. Returns [(check, passed, detail), ...]."""
    import numpy as np
    import pyarrow.parquet as pq

    results = []

    def check(name: str, ok: bool, detail: str = "") -> bool:
        results.append((name, bool(ok), detail))
        log(f"  {'PASS' if ok else 'FAIL'}: {name}" + (f" ({detail})" if detail else ""))
        return ok

    sample = work / "detector/vectors_sample.parquet"
    if not check("vector sample was recorded and closed", sample.exists(), str(sample)):
        return results

    stride = 10
    n_vectors = end_offsets(topics["vectors"])
    rows = pq.ParquetFile(sample).metadata.num_rows
    check("sample holds one vector in ten", rows == n_vectors // stride,
          f"{rows:,} rows for {n_vectors:,} vectors on the topic")
    sys.path.insert(0, str(DETECTOR / "scripts"))
    import check_vector_sample

    summary_file = sample.with_suffix(".summary.json")
    for desc, ok, detail in check_vector_sample.check(str(sample)):
        check(f"sample vs the runner's summary: {desc}", ok, detail)
    if summary_file.exists():
        summary = json.loads(summary_file.read_text())
        check("the runner consumed every vector on the topic", summary["consumed"] == n_vectors,
              f"runner consumed {summary['consumed']:,}, topic holds {n_vectors:,}")
    idx = pq.read_table(sample, columns=["stream_index"]).column("stream_index").to_numpy()
    check("stream_index is every 10th position, in order",
          len(idx) > 0 and idx[0] == stride and bool(np.all(np.diff(idx) == stride)))

    log("replaying the sample through the same models in a separate run...")
    replay_dir = work / "replay"
    replay_dir.mkdir(exist_ok=True)
    r = subprocess.run(
        [str(DETECTOR / "venv/bin/python"), "-u", "scripts/run_multi_model.py", "--config",
         str(work / "detector/baselines.yaml"), "--from-file", str(sample), "--models", ",".join(models),
         "--output", str(replay_dir / "scores.parquet")],
        cwd=DETECTOR, env=dict(os.environ, PYTHONPATH=str(DETECTOR)),
        stdout=open(work / "logs/replay.log", "w"), stderr=subprocess.STDOUT)
    if not check("replay run exited cleanly", r.returncode == 0, f"exit {r.returncode}; see logs/replay.log"):
        return results

    cols = ["exchange", "instrument", "timestamp_ms", "seq"]
    for m in models:
        live = pq.read_table(work / f"detector/scores_{m}.parquet").to_pandas()
        rep = pq.read_table(replay_dir / f"scores_{m}.parquet").to_pandas()
        check(f"{m}: replay scores exactly the rows the live run scored",
              live[cols].reset_index(drop=True).equals(rep[cols].reset_index(drop=True)),
              f"live {len(live):,} rows, replay {len(rep):,} rows")
        if m == "zscore":  # deterministic model: the scores themselves must match
            check("zscore: replay scores equal the live scores",
                  np.array_equal(live["z_score"].to_numpy(), rep["z_score"].to_numpy()))
    return results


# ------------------------------------------------------------------------------ main


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rows", type=int, default=600_000, help="rows of the day file to replay")
    ap.add_argument("--first-line", type=int, default=20_000_000, help="where in the day file the slice starts")
    ap.add_argument("--day-file", default=str(SIM / "data/trading_hours/debs2022-gc-trading-day-10-11-21.csv"))
    ap.add_argument("--keep-topics", action="store_true")
    args = ap.parse_args()

    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    work = ROOT / "results" / f"smoke_{stamp}"
    work.mkdir(parents=True, exist_ok=True)
    (work / "logs").mkdir()
    log(f"working directory: {work}")

    topics = {k: f"smoke-{k}-{stamp}" for k in ("raw", "vectors", "alerts", "scores")}
    ids = {"handler": f"smoke-handler-{stamp}", "detector": f"smoke-detector-{stamp}"}
    procs = []
    try:
        log("building binaries (the tracked simulator binary is left alone)...")
        (work / "bin").mkdir()
        run(["go", "build", "-o", str(work / "bin/simulator"), "./cmd/simulator"], cwd=SIM)
        run(["go", "build", "-o", str(work / "bin/aggregator"), "./cmd/aggregator"], cwd=HANDLER)

        log(f"slicing {args.rows:,} rows of {Path(args.day_file).name} from line {args.first_line:,}...")
        day_file = Path(args.day_file)
        span = make_slice(day_file, work / "data" / day_file.name, args.first_line, args.rows)
        day = f"{day_file.stem[-8:-6]}-{day_file.stem[-5:-3]}-20{day_file.stem[-2:]}"  # 10-11-2021
        log(f"slice covers {hms(span[0])} - {hms(span[1])} on {day}")
        info = write_configs(work, topics, span, day, ids)
        for k, v in info["windows"].items():
            log(f"  {k}: {v[0]} - {v[1]}")

        log("creating isolated topics...")
        create_topics(list(topics.values()))

        log("starting the feed-handler...")
        hlog = work / "logs" / "handler.log"
        handler = subprocess.Popen([str(work / "bin/aggregator"), str(work / "handler/aggregator.yaml")],
                                   cwd=work / "handler", stdout=open(hlog, "w"), stderr=subprocess.STDOUT)
        procs.append(handler)
        wait_for(hlog, "System fully operational", 40, handler, "the feed-handler")

        log("starting the RRCF detector...")
        dlog = work / "logs" / "detector.log"
        env = dict(os.environ, PYTHONPATH=str(DETECTOR))
        detector = subprocess.Popen([str(DETECTOR / "venv/bin/python"), "-u", "scripts/run_multi_model.py", "--config",
                                     str(work / "detector/baselines.yaml"), "--output", str(work / "detector/scores.parquet"),
                                     "--record", str(work / "detector/vectors_sample.parquet")],
                                    cwd=DETECTOR, env=env, stdout=open(dlog, "w"), stderr=subprocess.STDOUT)
        procs.append(detector)
        time.sleep(8)
        if detector.poll() is not None:
            raise SystemExit(f"the detector exited during startup; see {dlog}")

        log("running the simulator...")
        slog = work / "logs" / "simulator.log"
        t = time.time()
        with open(slog, "w") as f:
            sim = subprocess.run([str(work / "bin/simulator"), "-config", str(work / "sim/config.yaml")],
                                 cwd=work / "sim", stdout=f, stderr=subprocess.STDOUT)
        log(f"simulator finished (exit {sim.returncode}) in {time.time() - t:.0f}s")
        if sim.returncode != 0:
            raise SystemExit(f"the simulator failed; see {slog}")

        log("waiting for the feed-handler to drain...")
        raw_total = end_offsets(topics["raw"])
        vectors = wait_stable(lambda: end_offsets(topics["vectors"]), 10, 240, "vector topic")
        log(f"  {raw_total:,} raw messages -> {vectors:,} vectors")
        stop(handler, "the feed-handler")

        log("waiting for the detector to drain...")
        # run_multi_model.py consumes with group.id = <consumer_group_id>-multi
        wait_lag(ids["detector"] + "-multi", topics["vectors"], 300)
        stop(detector, "the detector", timeout=180)

        log("checking the recorded vector sample and its replay...")
        sample_checks = check_sample_and_replay(work, topics, ["rrcf", "zscore"])
        (work / "sample_check.json").write_text(json.dumps(
            [{"check": c, "passed": ok, "detail": d} for c, ok, d in sample_checks], indent=2))
        sample_ok = all(ok for _, ok, _ in sample_checks)

        # ------------------------------------------------------------- verify and evaluate
        log("verifying the run...")
        sys.path.insert(0, str(DETECTOR / "scripts"))
        import verify_run

        # the manifest is written to <cwd>/data by the simulator
        manifest = work / "sim/data/injection_manifest.json"
        scores = work / "detector/scores_rrcf.parquet"
        rc = verify_run.main([
            "--manifest", str(manifest), "--episodes", str(work / "sim/anomaly_log_episodes.csv"),
            "--instruments", str(work / "sim/anomaly_log_instruments.csv"),
            "--silence-log", str(work / "handler/eval/silence_alerts.csv"),
            "--validation-log", str(work / "handler/eval/validation_alerts.csv"),
            "--scores", str(scores), "--kafka", BROKER, "--raw-topic", topics["raw"], "--vector-topic", topics["vectors"],
            "--json", str(work / "verify.json"),
        ])

        log("running the evaluation on the smoke output...")
        import evaluate_thesis

        try:
            evaluate_thesis.main([
                "--episodes", str(work / "sim/anomaly_log_episodes.csv"),
                "--instruments", str(work / "sim/anomaly_log_instruments.csv"),
                "--scores", str(scores),
                "--silence-log", str(work / "handler/eval/silence_alerts.csv"),
                "--validation-log", str(work / "handler/eval/validation_alerts.csv"),
                "--output", str(work / "evaluation"), "--bootstrap", "100", "--warmup-days", "0",
            ])
        except SystemExit as e:
            log(f"evaluation stopped: {e}")

        log(f"done. Verifier exit status {rc}; vector sample/replay checks "
            f"{'passed' if sample_ok else 'FAILED (see sample_check.json)'}. Everything is in {work}")
        return rc or (0 if sample_ok else 1)
    finally:
        for p in procs:
            stop(p, "process", timeout=10)
        if not args.keep_topics:
            delete_topics(topics.values())


if __name__ == "__main__":
    sys.exit(main())
