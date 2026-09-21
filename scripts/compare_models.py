#!/usr/bin/env python3
"""
Put the evaluation results of every model of one run side by side.

Reads <run>/evaluation/<model>/evaluation_results.json (written by `make evaluate-thesis`,
one directory per model) and prints one table with a column per model. Also writes
<run>/evaluation/comparison.csv and comparison.md.

    python3 scripts/compare_models.py                          # results/latest
    python3 scripts/compare_models.py results/thesis_20260921_015547
    python3 scripts/compare_models.py results/latest --models zscore,isoforest

Standard library only. Values are recalls / rates in percent, with the 95% bootstrap CI
in brackets where the evaluation computed one. Phase 3 (feed silence) and phase 4 validator
rows are left out: those alerts come from the feed-handler, not from the scoring model.
"""

import argparse
import csv
import json
import sys
from pathlib import Path


def load(path):
    with open(path) as f:
        d = json.load(f)
    name = d.get("method") or path.parent.name
    # the model's block is keyed by its name; old files (before the key was made generic) use "rrcf"
    block = d.get(name) or d.get("rrcf")
    fa = d.get("false_alarms", {})
    far = fa.get(name) or fa.get("rrcf") or {}
    return name, d, block, far


def pct(x):
    return "n/a" if x is None else f"{100 * x:.1f}%"


def pct_ci(block, key="recall_scorable"):
    """'12.3% [10.1, 14.5]' from a metrics dict holding <key> and <key>_ci95 (None if absent)."""
    if not block or block.get(key) is None:
        return "n/a"
    ci = block.get(key + "_ci95")
    s = pct(block[key])
    return s if not ci else f"{s} [{100 * ci[0]:.1f}, {100 * ci[1]:.1f}]"


def num(x, fmt="{:.2f}"):
    return "n/a" if x is None else fmt.format(x)


def rows_for(name, d, block, far):
    """Ordered (label, value) pairs for one model."""
    thr = d["operating_threshold"]
    by_thr = far.get("by_threshold", {})
    at_thr = by_thr.get(str(thr)) or by_thr.get(f"{thr:.1f}") or {}
    p1 = block.get("phase1", {})
    p2 = block.get("phase2", {})
    p4 = block.get("phase4_implausible_price", {})
    cp = block.get("cluster_precision_at_injected_density", {})

    r = [
        ("Operating threshold (z-score)", num(thr, "{:g}")),
        ("Clean-day false alarms / 1000 vectors", num(at_thr.get("headline_alerts_per_1000_vectors"), "{:.3f}")),
        ("-- Phase 1: gradual decline / feed degradation", ""),
        ("Affected instruments detected (recall)", pct_ci(p1.get("affected"))),
        ("Control instruments flagged (same days)", pct_ci(p1.get("control_unaffected"), "detection_rate")),
        ("Difference affected - control (CI95)",
         "n/a" if not p1.get("detection_rate_difference_ci95")
         else "[{:.1f}, {:.1f}] pp".format(*[100 * v for v in p1["detection_rate_difference_ci95"]])),
        ("-- Phase 2: point anomalies (strict = exact tick)", ""),
    ]
    for t, b in sorted(p2.get("point", {}).items()):
        r.append((f"{t}: recall", pct_ci(b.get("strict_exact_tick"))))
    r.append(("stale_price: recall", pct_ci(p2.get("stale_price"))))
    r += [
        ("-- Phase 4: implausible price", ""),
        ("implausible_price: strict recall", pct_ci(p4.get("strict_exact_tick"))),
        ("implausible_price: lenient recall (5 s window)", pct_ci(p4.get("lenient_within_window"))),
        ("-- Alert precision at the injected density", ""),
    ]
    for fam, b in sorted(cp.items()):
        r.append((f"{fam}: cluster precision", pct(b.get("precision"))))
    return r


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("run_dir", nargs="?", default="results/latest", help="archived run (default results/latest)")
    p.add_argument("--models", help="comma-separated subset / order of models (default: all found)")
    args = p.parse_args(argv)

    ev = Path(args.run_dir) / "evaluation"
    files = sorted(ev.glob("*/evaluation_results.json"))
    if not files:
        print(f"no {ev}/<model>/evaluation_results.json found: run `make evaluate-thesis` first", file=sys.stderr)
        return 1
    loaded = {}
    for f in files:
        name, d, block, far = load(f)
        if block is None:
            print(f"skipping {f}: no results block for '{name}'", file=sys.stderr)
            continue
        loaded[name] = (d, block, far)
    if args.models:
        order = [m.strip() for m in args.models.split(",") if m.strip()]
        missing = [m for m in order if m not in loaded]
        if missing:
            print(f"unknown model(s) {missing}; found {sorted(loaded)}", file=sys.stderr)
            return 1
        loaded = {m: loaded[m] for m in order}
    if not loaded:
        return 1

    models = list(loaded)
    table = {m: rows_for(m, *loaded[m]) for m in models}
    labels = [lab for lab, _ in table[models[0]]]
    # models can differ in the families present (e.g. no stale episodes): align on the union of labels
    for m in models[1:]:
        for lab, _ in table[m]:
            if lab not in labels:
                labels.append(lab)
    cell = {m: dict(table[m]) for m in models}

    w0 = max(len(l) for l in labels)
    ws = {m: max(len(m), *(len(cell[m].get(l, "n/a")) for l in labels)) for m in models}
    line = "  ".join(m.rjust(ws[m]) for m in models)
    out = [f"Run: {args.run_dir}", "", f"{'':<{w0}}  {line}", "-" * (w0 + 2 + len(line))]
    for l in labels:
        if l.startswith("--"):
            out.append("")
            out.append(l.strip("- ").upper())
        else:
            out.append(f"{l:<{w0}}  " + "  ".join(cell[m].get(l, "n/a").rjust(ws[m]) for m in models))
    out += ["", "Recalls are over scorable episodes; [..] is the 95% bootstrap CI over instruments."]
    text = "\n".join(out)
    print(text)

    with open(ev / "comparison.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["metric"] + models)
        for l in labels:
            if not l.startswith("--"):
                w.writerow([l] + [cell[m].get(l, "n/a") for m in models])
    md = ["| metric | " + " | ".join(models) + " |", "|---|" + "---|" * len(models)]
    for l in labels:
        md.append(f"| **{l.strip('- ')}** |" + " |" * len(models) if l.startswith("--")
                  else f"| {l} | " + " | ".join(cell[m].get(l, "n/a") for m in models) + " |")
    (ev / "comparison.md").write_text("\n".join(md) + "\n")
    print(f"\nWritten: {ev / 'comparison.csv'} and {ev / 'comparison.md'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
