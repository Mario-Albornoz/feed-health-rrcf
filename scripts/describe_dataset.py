#!/usr/bin/env python3
"""
Describe the tick dataset that the pipeline ingests (DEBS 2022 Grand Challenge day files).

Streams every day file once and writes a machine-readable profile (JSON) and a readable
report (Markdown), so that what is being ingested is known rather than assumed. Every
statistic is computed from the data; the report lists the definitions used.

    ../rrcf-detector/venv/bin/python scripts/describe_dataset.py \\
        --data-dir price-feed-simulator/data/trading_hours --output results/dataset_profile

Run it on the raw directory as well (price-feed-simulator/data) to see what the filtered
copy leaves out. A quick look: --max-rows 2000000.

Definitions
  equity      SecType == "E" (the feed-handler only forwards equities)
  message     one row of a day file
  kind        which price fields the row carries: trade (Last present and > 0), bid-only,
              ask-only, bid+ask, other (none of them)
  event time  what the simulator's parser gives the pipeline as the tick time: the
              "Trading time" column if it parses (time of day, combined with the row's
              date), else the "Time" column. Reported as seen by the pipeline, including
              the 00:00:00.000 that stale snapshots carry.
"""

import argparse
import json
import math
import re
import sys
import time
from collections import Counter
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np
import pandas as pd
import pyarrow as pa
import pyarrow.csv as pacsv

COLUMNS = [
    "ID", "SecType", "Date", "Time", "Ask", "Bid", "Ask volume", "Bid volume", "Currency",
    "ISIN", "Last", "Last volume", "Trading time", "Total volume", "Trading date",
]

# log-spaced bin edges (ms) for inter-arrival times, plus an exact "zero" bucket
GAP_EDGES = np.concatenate([[0.0], np.logspace(0, 8, 161)])          # 1 ms .. ~28 h
# relative price change between consecutive trades (log-spaced, plus exact zero)
STEP_EDGES = np.concatenate([[0.0], np.logspace(-6, 1, 141)])       # 1e-6 .. 10 (=1000%)
BACKWARD_EDGES = np.array([0, 1, 10, 100, 500, 1000, 5000, 60_000, 3_600_000, 86_400_000, np.inf])
KINDS = ["trade", "bid_only", "ask_only", "bid_and_ask", "other"]


# ------------------------------------------------------------------------- helpers


def _leading_comment_lines(path: Path) -> int:
    n = 0
    with open(path, "rb") as f:
        for line in f:
            if line.startswith(b"#"):
                n += 1
            else:
                break
    return n


def _header_names(path: Path, skip: int) -> list:
    """Column names from the header line. Data rows carry one more field than the header
    (a trailing comma), so a spare name is appended or every row would be rejected."""
    with open(path, "rb") as f:
        for i, line in enumerate(f):
            if i == skip:
                names = line.decode().rstrip("\r\n").split(",")
                return names + ["_trailing"]
    raise ValueError(f"no header found in {path}")


def _tod_ms(series: pd.Series) -> pd.Series:
    """'HH:MM:SS[.mmm]' -> milliseconds since midnight (NaN if empty or unparsable)."""
    return pd.to_timedelta(series, errors="coerce").dt.total_seconds() * 1000.0


def _quantiles_from_hist(counts: np.ndarray, edges: np.ndarray, qs=(0.5, 0.9, 0.99, 0.999)) -> dict:
    """Approximate quantiles from a histogram whose first bucket is exact zeros."""
    total = counts.sum()
    if total == 0:
        return {f"p{q * 100:g}": None for q in qs}
    cum = np.cumsum(counts) / total
    out = {}
    for q in qs:
        i = int(np.searchsorted(cum, q))
        out[f"p{q * 100:g}"] = float(edges[min(i + 1, len(edges) - 1)]) if i > 0 else 0.0  # upper edge of the bucket
    return out


def _series_quantiles(values, qs=(0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 0.99, 1.0)) -> dict:
    values = np.asarray(values, dtype=float)
    if len(values) == 0:
        return {}
    return {f"q{q:g}": float(np.quantile(values, q)) for q in qs}


# ---------------------------------------------------------------------- one day file


def profile_file(args_tuple) -> dict:
    path, max_rows, block_mb = args_tuple
    path = Path(path)
    t0 = time.time()

    skip = _leading_comment_lines(path)
    invalid = Counter()

    def handler(row):
        invalid["malformed_rows"] += 1
        return "skip"

    reader = pacsv.open_csv(
        path,
        read_options=pacsv.ReadOptions(skip_rows=skip + 1, column_names=_header_names(path, skip),
                                       block_size=block_mb << 20),
        parse_options=pacsv.ParseOptions(invalid_row_handler=handler),
        convert_options=pacsv.ConvertOptions(
            include_columns=COLUMNS,
            column_types={c: pa.string() for c in COLUMNS},
            strings_can_be_null=False,
        ),
    )

    P = {
        "file": path.name, "rows": 0, "rows_equity": 0, "rows_index": 0, "rows_other_sectype": 0,
        "kinds": {},  # exchange -> Counter of kinds
        "field_presence": Counter(),
        "hour_rows": {}, "hour_trades": {},      # "exchange|hour" -> count (event time hour)
        "sys_hour_rows": Counter(),               # hour of the "Time" column
        "trade_missing_volume": 0, "trades": 0,
        "trading_time_present": 0, "trading_time_midnight": 0, "trading_time_midnight_by_kind": Counter(),
        "event_midnight_rows": 0, "event_midnight_by_hour_of_time": Counter(),
        "time_ms_nonzero": 0,
        "currency": Counter(), "isin_present": 0,
        "inst_rows": Counter(), "inst_trades": Counter(), "inst_exchange": {},
        "gap_hist": np.zeros(len(GAP_EDGES) - 1, dtype=np.int64),
        "gap_hist_trades": np.zeros(len(GAP_EDGES) - 1, dtype=np.int64),
        "gap_zero": 0, "gap_total": 0,
        "backward_hist": np.zeros(len(BACKWARD_EDGES) - 1, dtype=np.int64),
        "backward_total": 0, "forward_or_equal": 0,
        "global_backward": 0, "global_pairs": 0,
        "step_hist": np.zeros(len(STEP_EDGES) - 1, dtype=np.int64), "step_total": 0,
        "price_min": math.inf, "price_max": 0.0, "trade_repeat_same_price": 0, "trade_pairs": 0,
        "event_first_ms": math.inf, "event_last_ms": 0.0,
        "date_mismatch": 0, "dates": Counter(),
        "bid_ask_both_rows": 0, "crossed_quotes": 0,
        "invalid": invalid,
    }

    last_time = {}        # instrument -> event time ms of previous row
    last_trade_price = {}  # instrument -> price of previous trade
    last_trade_time = {}   # instrument -> event time ms of previous trade
    prev_global = None     # event time of the last row of the previous batch

    for batch in reader:
        df = batch.to_pandas()
        n_all = len(df)
        if max_rows and P["rows"] >= max_rows:
            break
        P["rows"] += n_all

        sec = df["SecType"]
        P["rows_index"] += int((sec == "I").sum())
        P["rows_equity"] += int((sec == "E").sum())
        P["rows_other_sectype"] += int((~sec.isin(["E", "I"])).sum())
        df = df[sec == "E"]
        if df.empty:
            continue

        ids = df["ID"]
        exch = ids.str.extract(r"\.([A-Za-z0-9]+)$", expand=False).fillna("UNKNOWN")

        last = pd.to_numeric(df["Last"], errors="coerce")
        bid = df["Bid"] != ""
        ask = df["Ask"] != ""
        trade = last > 0
        kind = np.select(
            [trade, bid & ask, bid, ask], ["trade", "bid_and_ask", "bid_only", "ask_only"], default="other"
        )

        for field in ("Last", "Last volume", "Bid", "Ask", "Bid volume", "Ask volume", "Total volume", "Trading time", "Trading date", "ISIN"):
            P["field_presence"][field] += int((df[field] != "").sum())
        P["isin_present"] += int((df["ISIN"] != "").sum())
        P["currency"].update(df["Currency"][df["Currency"] != ""].value_counts().to_dict())
        P["trades"] += int(trade.sum())
        P["trade_missing_volume"] += int((trade & (df["Last volume"] == "")).sum())

        # quote sanity where both sides are on the same row
        both = (df["Bid"] != "") & (df["Ask"] != "")
        if both.any():
            b = pd.to_numeric(df["Bid"][both], errors="coerce")
            a = pd.to_numeric(df["Ask"][both], errors="coerce")
            P["bid_ask_both_rows"] += int(both.sum())
            P["crossed_quotes"] += int((b > a).sum())

        # ---- event time as the pipeline sees it
        sys_ms = _tod_ms(df["Time"])
        tt_ms = _tod_ms(df["Trading time"])
        tt_present = tt_ms.notna()
        tt_midnight = tt_present & (tt_ms == 0)
        event_ms = tt_ms.where(tt_present, sys_ms)          # NaN if neither parses
        event_ms = event_ms.fillna(0)

        P["trading_time_present"] += int(tt_present.sum())
        P["trading_time_midnight"] += int(tt_midnight.sum())
        for k, c in pd.Series(kind[tt_midnight.to_numpy()]).value_counts().items():
            P["trading_time_midnight_by_kind"][k] += int(c)
        P["event_midnight_rows"] += int((event_ms == 0).sum())
        sys_hour = (sys_ms // 3_600_000).fillna(-1).astype(int)
        for h, c in sys_hour.value_counts().items():
            P["sys_hour_rows"][int(h)] += int(c)
        mid_h = sys_hour[event_ms == 0].value_counts()
        for h, c in mid_h.items():
            P["event_midnight_by_hour_of_time"][int(h)] += int(c)
        P["time_ms_nonzero"] += int(((sys_ms % 1000) != 0).sum())
        P["dates"].update(df["Date"].value_counts().to_dict())
        P["date_mismatch"] += int(((df["Trading date"] != "") & (df["Trading date"] != df["Date"])).sum())

        ev_hour = (event_ms // 3_600_000).astype(int)
        agg = pd.DataFrame({"e": exch.to_numpy(), "h": ev_hour.to_numpy(), "k": kind}).value_counts().reset_index(name="n")
        for e, h, k, n in agg.itertuples(index=False):
            P["kinds"].setdefault(e, Counter())[k] += int(n)
            key = f"{e}|{h}"
            P["hour_rows"][key] = P["hour_rows"].get(key, 0) + int(n)
            if k == "trade":
                P["hour_trades"][key] = P["hour_trades"].get(key, 0) + int(n)

        valid_event = event_ms[event_ms > 0]
        if len(valid_event):
            P["event_first_ms"] = min(P["event_first_ms"], float(valid_event.min()))
            P["event_last_ms"] = max(P["event_last_ms"], float(valid_event.max()))

        # ---- per-instrument counts
        for inst, c in ids.value_counts().items():
            P["inst_rows"][inst] += int(c)
        for inst, c in ids[trade].value_counts().items():
            P["inst_trades"][inst] += int(c)
        for inst, e in zip(ids.drop_duplicates(), exch[ids.drop_duplicates().index]):
            P["inst_exchange"][inst] = e

        # ---- global file order
        ev = event_ms.to_numpy()
        if prev_global is not None:
            P["global_pairs"] += 1
            P["global_backward"] += int(ev[0] < prev_global)
        P["global_pairs"] += len(ev) - 1
        P["global_backward"] += int((ev[1:] < ev[:-1]).sum())
        prev_global = ev[-1]

        # ---- per-instrument ordering and inter-arrival (all rows)
        work = pd.DataFrame({"id": ids.to_numpy(), "t": ev, "trade": trade.to_numpy(), "price": last.to_numpy()})
        work["row"] = np.arange(len(work))
        work = work.sort_values(["id", "row"], kind="stable")
        prev_t = work.groupby("id")["t"].shift(1)
        first_of_group = prev_t.isna()
        carry = work["id"].map(last_time)
        prev_t = prev_t.where(~first_of_group, carry)
        diff = (work["t"] - prev_t).to_numpy()
        diff = diff[~np.isnan(diff)]
        fwd = diff[diff >= 0]
        back = -diff[diff < 0]
        P["gap_total"] += len(fwd)
        P["gap_zero"] += int((fwd == 0).sum())
        P["gap_hist"] += np.histogram(fwd, bins=GAP_EDGES)[0]
        P["forward_or_equal"] += len(fwd)
        P["backward_total"] += len(back)
        P["backward_hist"] += np.histogram(back, bins=BACKWARD_EDGES)[0]
        for inst, t in work.groupby("id")["t"].last().items():
            last_time[inst] = t

        # ---- trade-to-trade: inter-arrival and price change
        tw = work[work["trade"]]
        if len(tw):
            tprev_t = tw.groupby("id")["t"].shift(1)
            tprev_p = tw.groupby("id")["price"].shift(1)
            firsts = tprev_t.isna()
            tprev_t = tprev_t.where(~firsts, tw["id"].map(last_trade_time))
            tprev_p = tprev_p.where(~firsts, tw["id"].map(last_trade_price))
            tdiff = (tw["t"] - tprev_t).to_numpy()
            tdiff = tdiff[~np.isnan(tdiff) & (tdiff >= 0)]
            P["gap_hist_trades"] += np.histogram(tdiff, bins=GAP_EDGES)[0]
            ok = tprev_p.notna()
            if ok.any():
                p1, p0 = tw["price"][ok].to_numpy(), tprev_p[ok].to_numpy()
                rel = np.abs(p1 - p0) / p0
                P["trade_pairs"] += len(rel)
                P["trade_repeat_same_price"] += int((rel == 0).sum())
                P["step_total"] += len(rel)
                P["step_hist"] += np.histogram(rel, bins=STEP_EDGES)[0]
            P["price_min"] = min(P["price_min"], float(tw["price"].min()))
            P["price_max"] = max(P["price_max"], float(tw["price"].max()))
            for inst, row in tw.groupby("id").last().iterrows():
                last_trade_time[inst] = row["t"]
                last_trade_price[inst] = row["price"]

    P["seconds"] = round(time.time() - t0, 1)
    return P


# --------------------------------------------------------------------------- report


def _pct(a, b):
    return None if not b else 100.0 * a / b


def summarise(P: dict) -> dict:
    """Reduce one file's accumulators to plain, serialisable numbers."""
    rows_eq = P["rows_equity"]
    inst_rows = np.array(list(P["inst_rows"].values()))
    inst_trades = np.array([P["inst_trades"].get(k, 0) for k in P["inst_rows"]])
    by_exch = {}
    for e, kinds in sorted(P["kinds"].items()):
        n = sum(kinds.values())
        by_exch[e] = {"rows": n, **{k: kinds.get(k, 0) for k in KINDS},
                      "trade_share_pct": _pct(kinds.get("trade", 0), n),
                      "instruments": sum(1 for i, x in P["inst_exchange"].items() if x == e)}

    hours = sorted({int(k.split("|")[1]) for k in P["hour_rows"]})
    exchanges = sorted(P["kinds"])
    profile = {e: {str(h): {"rows": P["hour_rows"].get(f"{e}|{h}", 0), "trades": P["hour_trades"].get(f"{e}|{h}", 0)}
                   for h in hours} for e in exchanges}

    def tier(n):
        return int(((inst_rows >= n[0]) & (inst_rows < n[1])).sum())

    tiers = {"<100": tier((0, 100)), "100-999": tier((100, 1000)), "1k-9,999": tier((1000, 10000)),
             "10k-99,999": tier((10000, 100000)), ">=100k": tier((100000, float("inf")))}

    return {
        "file": P["file"], "seconds": P["seconds"],
        "rows": P["rows"], "rows_equity": rows_eq, "rows_index": P["rows_index"],
        "rows_other_sectype": P["rows_other_sectype"], "malformed_rows_skipped": P["invalid"].get("malformed_rows", 0),
        "dates_in_file": dict(P["dates"]), "trading_date_differs_from_date": P["date_mismatch"],
        "equity_instruments": len(inst_rows), "by_exchange": by_exch,
        "field_presence_pct_of_equity_rows": {k: _pct(v, rows_eq) for k, v in P["field_presence"].items()},
        "trades": P["trades"], "trades_pct_of_equity_rows": _pct(P["trades"], rows_eq),
        "trades_without_last_volume_pct": _pct(P["trade_missing_volume"], P["trades"]),
        "currency": dict(P["currency"]), "isin_present_rows": P["isin_present"],
        "time": {
            "time_column_has_milliseconds_pct": _pct(P["time_ms_nonzero"], rows_eq),
            "trading_time_present_pct": _pct(P["trading_time_present"], rows_eq),
            "trading_time_exactly_midnight_rows": P["trading_time_midnight"],
            "trading_time_exactly_midnight_by_kind": dict(P["trading_time_midnight_by_kind"]),
            "event_time_midnight_rows": P["event_midnight_rows"],
            "event_time_midnight_by_hour_of_Time_column": dict(P["event_midnight_by_hour_of_time"]),
            "system_time_hour_rows": {str(k): v for k, v in sorted(P["sys_hour_rows"].items())},
            "event_first_hhmm": None if math.isinf(P["event_first_ms"]) else _fmt_ms(P["event_first_ms"]),
            "event_last_hhmm": _fmt_ms(P["event_last_ms"]),
        },
        "intraday_profile_by_event_hour": profile,
        "ordering": {
            "file_order_backward_steps_pct": _pct(P["global_backward"], P["global_pairs"]),
            "per_instrument_backward_steps_pct": _pct(P["backward_total"], P["backward_total"] + P["forward_or_equal"]),
            "per_instrument_backward_magnitude_ms": dict(zip(
                [f"[{a:g},{b:g})" for a, b in zip(BACKWARD_EDGES[:-1], BACKWARD_EDGES[1:])], P["backward_hist"].tolist())),
        },
        "inter_arrival_ms_per_instrument": {
            "pairs": P["gap_total"], "identical_timestamp_pct": _pct(P["gap_zero"], P["gap_total"]),
            **_quantiles_from_hist(P["gap_hist"], GAP_EDGES)},
        "inter_arrival_ms_between_trades": _quantiles_from_hist(P["gap_hist_trades"], GAP_EDGES),
        "trade_price": {
            "min": None if math.isinf(P["price_min"]) else P["price_min"], "max": P["price_max"],
            "consecutive_trade_pairs": P["trade_pairs"],
            "same_price_as_previous_trade_pct": _pct(P["trade_repeat_same_price"], P["trade_pairs"]),
            "abs_relative_change_between_trades": _quantiles_from_hist(P["step_hist"], STEP_EDGES, (0.5, 0.9, 0.99, 0.999, 0.9999)),
            "changes_over_10_pct": int(P["step_hist"][STEP_EDGES.searchsorted(0.1) :].sum()) if P["step_total"] else 0,
        },
        "bid_ask_rows_with_both_sides": P["bid_ask_both_rows"], "crossed_quotes_on_those_rows": P["crossed_quotes"],
        "rows_per_instrument": _series_quantiles(inst_rows), "trades_per_instrument": _series_quantiles(inst_trades),
        "instruments_without_any_trade": int((inst_trades == 0).sum()),
        "instrument_liquidity_tiers_by_rows": tiers,
        "_instruments": sorted(P["inst_rows"]),
    }


def _day(d: dict) -> str:
    m = re.search(r"(\d{2}-\d{2}-\d{2})", d["file"])
    return m.group(1) if m else d["file"]


def _fmt_ms(ms: float) -> str:
    s = int(ms // 1000)
    return f"{s // 3600:02d}:{(s % 3600) // 60:02d}:{s % 60:02d}"


def render_markdown(days: list, directory: str) -> str:
    out = ["# Dataset profile", "",
           f"Directory: `{directory}`. Generated by `scripts/describe_dataset.py`. Every number is computed from the",
           "files; definitions are in the script header. Percentages of rows refer to equity rows unless stated.", ""]

    out += ["## 1. Volume", "", "| Day file | Rows | Equity rows | Index rows | Equity instruments | Skipped malformed | Event-time span |",
            "|---|---:|---:|---:|---:|---:|---|"]
    for d in days:
        t = d["time"]
        out.append(f"| {d['file']} | {d['rows']:,} | {d['rows_equity']:,} | {d['rows_index']:,} | {d['equity_instruments']:,} | "
                   f"{d['malformed_rows_skipped']:,} | {t['event_first_hhmm']} - {t['event_last_hhmm']} |")
    total = sum(d["rows"] for d in days)
    universe = set()
    for d in days:
        universe |= set(d["_instruments"])
    common = set(days[0]["_instruments"])
    for d in days[1:]:
        common &= set(d["_instruments"])
    out += ["", f"Total rows: {total:,}. Distinct equity instruments over all days: {len(universe):,}; "
                f"present on every day: {len(common):,}.", ""]

    out += ["## 2. What a message is", "",
            "Each row is one update carrying only the fields that changed. Share of equity rows by kind, per exchange and day:", "",
            "| Day | Exchange | Rows | Trade | Bid only | Ask only | Bid + ask | Other | Instruments |", "|---|---|---:|---:|---:|---:|---:|---:|---:|"]
    for d in days:
        for e, v in d["by_exchange"].items():
            n = v["rows"]
            out.append(f"| {_day(d)} | {e} | {n:,} | {100 * v['trade'] / n:.1f}% | {100 * v['bid_only'] / n:.1f}% | "
                       f"{100 * v['ask_only'] / n:.1f}% | {100 * v['bid_and_ask'] / n:.1f}% | {100 * v['other'] / n:.1f}% | {v['instruments']:,} |")
    out += ["", "Field presence (% of equity rows):", "", "| Day | " + " | ".join(f"`{k}`" for k in days[0]["field_presence_pct_of_equity_rows"]) + " |",
            "|---|" + "---:|" * len(days[0]["field_presence_pct_of_equity_rows"])]
    for d in days:
        out.append(f"| {_day(d)} | " + " | ".join(f"{v:.1f}" for v in d["field_presence_pct_of_equity_rows"].values()) + " |")
    out += ["", "Trades (rows with a last price > 0):", "", "| Day | Trades | % of equity rows | Without last volume | Price min | Price max | Same price as previous trade |",
            "|---|---:|---:|---:|---:|---:|---:|"]
    for d in days:
        tp = d["trade_price"]
        out.append(f"| {_day(d)} | {d['trades']:,} | {d['trades_pct_of_equity_rows']:.2f}% | {d['trades_without_last_volume_pct']:.1f}% | "
                   f"{tp['min']} | {tp['max']:,.2f} | {tp['same_price_as_previous_trade_pct']:.1f}% |")
    out += [""]

    out += ["## 3. Instruments and liquidity", "", "| Day | Instruments | Rows/instr. median | p90 | p99 | max | Trades/instr. median | p90 | Instruments with no trade |",
            "|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for d in days:
        r, t = d["rows_per_instrument"], d["trades_per_instrument"]
        out.append(f"| {_day(d)} | {d['equity_instruments']:,} | {r['q0.5']:.0f} | {r['q0.9']:.0f} | {r['q0.99']:.0f} | {r['q1']:.0f} | "
                   f"{t['q0.5']:.0f} | {t['q0.9']:.0f} | {d['instruments_without_any_trade']:,} |")
    out += ["", "Instruments by rows per day:", "", "| Day | " + " | ".join(days[0]["instrument_liquidity_tiers_by_rows"]) + " |", "|---|" + "---:|" * 5]
    for d in days:
        out.append(f"| {_day(d)} | " + " | ".join(f"{v:,}" for v in d["instrument_liquidity_tiers_by_rows"].values()) + " |")
    out += [""]

    out += ["## 4. Time", "",
            "The pipeline's event time is the `Trading time` column when it parses, else `Time`. Update times in `Time` have",
            "whole-second resolution in most rows; `Trading time` carries milliseconds.", "",
            "| Day | `Time` with ms | `Trading time` present | `Trading time` = 00:00:00.000 | Event time at midnight | Trading date differs from date |",
            "|---|---:|---:|---:|---:|---:|"]
    for d in days:
        t = d["time"]
        out.append(f"| {_day(d)} | {t['time_column_has_milliseconds_pct']:.1f}% | {t['trading_time_present_pct']:.1f}% | "
                   f"{t['trading_time_exactly_midnight_rows']:,} | {t['event_time_midnight_rows']:,} | {d['trading_date_differs_from_date']:,} |")
    out += ["", "Rows with `Trading time` = 00:00:00.000 by kind (stale snapshots carry a last price with a zero trading time):", ""]
    for d in days:
        out.append(f"* {_day(d)}: {d['time']['trading_time_exactly_midnight_by_kind']}")
    out += ["", "Rows per event-time hour and exchange (all equity rows / trades):", ""]
    exchanges = sorted({e for d in days for e in d["intraday_profile_by_event_hour"]})
    for d in days:
        prof = d["intraday_profile_by_event_hour"]
        hours = sorted({int(h) for e in prof for h in prof[e]})
        out += [f"**{_day(d)}**", "", "| Hour | " + " | ".join(exchanges) + " |", "|---|" + "---:|" * len(exchanges)]
        for h in hours:
            cells = []
            for e in exchanges:
                c = prof.get(e, {}).get(str(h), {"rows": 0, "trades": 0})
                cells.append(f"{c['rows']:,} / {c['trades']:,}")
            out.append(f"| {h:02d} | " + " | ".join(cells) + " |")
        out.append("")

    out += ["## 5. Ordering and timing", "",
            "| Day | Backward steps in file order | Per-instrument backward steps | Identical timestamp as previous row of the instrument | Gap p50 / p90 / p99 (ms) | Gap between trades p50 / p90 / p99 (ms) |",
            "|---|---:|---:|---:|---|---|"]
    for d in days:
        o, g, gt = d["ordering"], d["inter_arrival_ms_per_instrument"], d["inter_arrival_ms_between_trades"]
        out.append(f"| {_day(d)} | {o['file_order_backward_steps_pct']:.1f}% | {o['per_instrument_backward_steps_pct']:.1f}% | "
                   f"{g['identical_timestamp_pct']:.1f}% | {g['p50']:.0f} / {g['p90']:.0f} / {g['p99']:.0f} | {gt['p50']:.0f} / {gt['p90']:.0f} / {gt['p99']:.0f} |")
    out += ["", "Magnitude of per-instrument backward steps (count of steps in each range, ms):", ""]
    for d in days:
        out.append(f"* {_day(d)}: {d['ordering']['per_instrument_backward_magnitude_ms']}")
    out += ["", "Trade-to-trade price change (absolute relative change, approximate quantiles from a log histogram):", "",
            "| Day | Pairs | p50 | p90 | p99 | p99.9 | p99.99 | Changes over 10% |", "|---|---:|---:|---:|---:|---:|---:|---:|"]
    for d in days:
        tp = d["trade_price"]
        q = tp["abs_relative_change_between_trades"]
        out.append(f"| {_day(d)} | {tp['consecutive_trade_pairs']:,} | {q['p50']:.2e} | {q['p90']:.2e} | {q['p99']:.2e} | {q['p99.9']:.2e} | "
                   f"{q['p99.99']:.2e} | {tp['changes_over_10_pct']:,} |")
    out += ["", "## 6. Other", "",
            "| Day | ISIN present (rows) | Currencies | Bid+ask rows | Crossed quotes |", "|---|---:|---|---:|---:|"]
    for d in days:
        out.append(f"| {_day(d)} | {d['isin_present_rows']:,} | {d['currency']} | {d['bid_ask_rows_with_both_sides']:,} | {d['crossed_quotes_on_those_rows']:,} |")
    return "\n".join(out) + "\n"


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--data-dir", required=True, help="directory with the day files")
    p.add_argument("--pattern", default="debs2022-gc-trading-day-*.csv")
    p.add_argument("--output", required=True, help="output directory")
    p.add_argument("--workers", type=int, default=3, help="files processed in parallel (each needs ~1.5 GB)")
    p.add_argument("--block-mb", type=int, default=32, help="CSV read block size")
    p.add_argument("--max-rows", type=int, default=0, help="stop each file after about this many rows (0 = all)")
    args = p.parse_args(argv)

    files = sorted(Path(args.data_dir).glob(args.pattern))
    if not files:
        print(f"no files match {args.pattern} in {args.data_dir}", file=sys.stderr)
        return 1
    print(f"Profiling {len(files)} files with {args.workers} workers...")

    jobs = [(str(f), args.max_rows, args.block_mb) for f in files]
    with ProcessPoolExecutor(max_workers=args.workers) as pool:
        results = list(pool.map(profile_file, jobs))
    days = [summarise(r) for r in results]

    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    slim = [{k: v for k, v in d.items() if k != "_instruments"} for d in days]
    (out / "dataset_profile.json").write_text(json.dumps({"directory": args.data_dir, "days": slim}, indent=2, default=str))
    (out / "dataset_profile.md").write_text(render_markdown(days, args.data_dir))
    print(f"Wrote {out / 'dataset_profile.md'} and dataset_profile.json")
    for d in days:
        print(f"  {d['file']}: {d['rows']:,} rows in {d['seconds']}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
