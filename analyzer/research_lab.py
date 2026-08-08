#!/usr/bin/env python3
"""Calibration and stress lab for ARE Analyzer minute scores.

The lab measures gate behaviour, never profitability.  It reports every tested
threshold combination rather than selecting a supposedly universal optimum.
"""
from __future__ import annotations

import argparse
import csv
import json
from collections import Counter
from datetime import datetime
from pathlib import Path


MRS_THRESHOLDS = (50, 55, 60, 65)
REE_THRESHOLDS = (50, 55, 60)
WDS_PAIRS = ((65, 35), (70, 40), (75, 45), (80, 50))
ATR_MULTIPLIERS = (1.0, 1.5, 2.0)
SPREAD_MULTIPLIERS = (1.0, 2.0, 3.0)
SLIPPAGE_LEVELS = (0, 1, 2)  # additional normal-spread units; not currency


def clamp(v, low=0.0, high=100.0):
    return max(low, min(high, v))


def load(path: Path):
    with path.open(newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    numeric = ("close", "mrs", "wds", "ree_proxy", "volatility_ratio", "spread_ratio", "directional_efficiency")
    for row in rows:
        for key in numeric:
            row[key] = float(row[key])
        row["ticks"] = int(row["ticks"])
        row["at"] = datetime.fromisoformat(row["timestamp"])
    return rows


def scenario_rows(rows):
    """Classify only from current and prior completed scores/prices."""
    output = []
    by_symbol = {}
    for row in rows:
        history = by_symbol.setdefault(row["symbol"], [])
        change = row["close"] - history[-20]["close"] if len(history) >= 20 else 0.0
        if row["wds"] >= 85:
            scenario = "DEEP_WHIPSAW"
        elif row["wds"] >= 70:
            scenario = "WHIPSAW"
        elif row["mrs"] >= 65 and row["wds"] < 50 and change > 0:
            scenario = "STRONG_TREND_UP"
        elif row["mrs"] >= 65 and row["wds"] < 50 and change < 0:
            scenario = "STRONG_TREND_DOWN"
        elif row["volatility_ratio"] <= .65 and row["directional_efficiency"] <= .2:
            scenario = "TIGHT_RANGE"
        elif row["volatility_ratio"] >= 1.3 and row["directional_efficiency"] <= .2:
            scenario = "WIDE_RANGE"
        elif row["volatility_ratio"] <= .65:
            scenario = "LOW_LIQUIDITY"
        else:
            scenario = "TRANSITION"
        output.append({"symbol": row["symbol"], "timestamp": row["timestamp"], "scenario": scenario,
                       "mrs": row["mrs"], "wds": row["wds"], "ree_proxy": row["ree_proxy"],
                       "decision": row["decision"]})
        history.append(row)
    return output


def segments(rows):
    result, active = [], None
    for row in rows:
        key = (row["symbol"], row["scenario"])
        if active and key == (active["symbol"], active["scenario"]):
            active["end"] = row["timestamp"]
            active["minutes"] += 1
            active["mrs_sum"] += row["mrs"]; active["wds_sum"] += row["wds"]; active["ree_sum"] += row["ree_proxy"]
        else:
            if active:
                result.append(active)
            active = {"symbol": row["symbol"], "scenario": row["scenario"], "start": row["timestamp"],
                      "end": row["timestamp"], "minutes": 1, "mrs_sum": row["mrs"], "wds_sum": row["wds"], "ree_sum": row["ree_proxy"]}
    if active:
        result.append(active)
    for segment in result:
        n = segment.pop("minutes")
        segment["duration_minutes"] = n
        segment["mean_mrs"] = round(segment.pop("mrs_sum") / n, 2)
        segment["mean_wds"] = round(segment.pop("wds_sum") / n, 2)
        segment["mean_ree_proxy"] = round(segment.pop("ree_sum") / n, 2)
    return result


def calibration(rows):
    results = []
    for symbol in sorted({r["symbol"] for r in rows}):
        source = [r for r in rows if r["symbol"] == symbol]
        split = max(1, int(len(source) * .70))
        for label, sample in (("training", source[:split]), ("validation", source[split:])):
            for mrs in MRS_THRESHOLDS:
                for ree in REE_THRESHOLDS:
                    for freeze, unfreeze in WDS_PAIRS:
                        eligible = sum(r["mrs"] >= mrs and r["ree_proxy"] >= ree and r["wds"] < freeze for r in sample)
                        frozen = sum(r["wds"] >= freeze for r in sample)
                        unfrozen = sum(r["wds"] <= unfreeze for r in sample)
                        results.append({"symbol": symbol, "split": label, "observations": len(sample),
                                        "mrs_threshold": mrs, "ree_threshold": ree, "wds_freeze": freeze,
                                        "wds_unfreeze": unfreeze, "eligible_minutes": eligible,
                                        "eligible_rate": round(eligible / len(sample), 5), "freeze_minutes": frozen,
                                        "freeze_rate": round(frozen / len(sample), 5), "unfreeze_minutes": unfrozen,
                                        "unfreeze_rate": round(unfrozen / len(sample), 5)})
    return results


def stress(rows):
    results = []
    for symbol in sorted({r["symbol"] for r in rows}):
        sample = [r for r in rows if r["symbol"] == symbol]
        for atr in ATR_MULTIPLIERS:
            for spread in SPREAD_MULTIPLIERS:
                for slip in SLIPPAGE_LEVELS:
                    # Gate sensitivity only. This is intentionally not a PnL or
                    # broker-fill simulator because the required specifications are absent.
                    stressed_wds = [clamp(r["wds"] + 10 * (atr - 1) + 12 * (spread - 1) + 8 * slip) for r in sample]
                    stressed_mrs = [clamp(r["mrs"] - 2 * (atr - 1) - 2 * (spread - 1)) for r in sample]
                    freezes = sum(w >= 70 for w in stressed_wds)
                    watches = sum(m >= 55 and w < 70 and r["ree_proxy"] >= 55 for m, w, r in zip(stressed_mrs, stressed_wds, sample))
                    results.append({"symbol": symbol, "atr_multiplier": atr, "spread_multiplier": spread,
                                    "slippage_units": slip, "observations": len(sample),
                                    "mean_stressed_mrs": round(sum(stressed_mrs) / len(sample), 2),
                                    "mean_stressed_wds": round(sum(stressed_wds) / len(sample), 2),
                                    "freeze_minutes": freezes, "freeze_rate": round(freezes / len(sample), 5),
                                    "watch_minutes": watches, "watch_rate": round(watches / len(sample), 5)})
    return results


def write_csv(path, rows):
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]) if rows else [])
        writer.writeheader(); writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description="ARE calibration and stress lab")
    parser.add_argument("--scores", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    rows = load(args.scores)
    scenarios = scenario_rows(rows)
    segment_rows = segments(scenarios)
    calibration_rows = calibration(rows)
    stress_rows = stress(rows)
    args.output.mkdir(parents=True, exist_ok=True)
    write_csv(args.output / "scenario_segments.csv", segment_rows)
    write_csv(args.output / "threshold_sensitivity.csv", calibration_rows)
    write_csv(args.output / "stress_gate_sensitivity.csv", stress_rows)
    scenario_counts = Counter((r["symbol"], r["scenario"]) for r in scenarios)
    summary = {"observations": len(rows), "scenario_minutes": {f"{s}:{k}": v for (s, k), v in sorted(scenario_counts.items())},
               "threshold_rows": len(calibration_rows), "stress_rows": len(stress_rows),
               "limitations": ["Threshold tables show gate frequency only, not profitability or an optimal parameter.",
                               "Stress tests adjust MRS/WDS gate sensitivity in normalized score units; they are not broker-fill, margin, or PnL simulations.",
                               "No broker contract, tick value, commission, leverage, or timezone has been inferred."]}
    (args.output / "research_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    baseline = [r for r in calibration_rows if r["split"] == "validation" and r["mrs_threshold"] == 55 and r["ree_threshold"] == 55 and r["wds_freeze"] == 70]
    extreme = [r for r in stress_rows if r["atr_multiplier"] == 2.0 and r["spread_multiplier"] == 3.0 and r["slippage_units"] == 2]
    lines = ["# ARE Research Lab - January 2026", "", "## Scope", "",
             "This lab used the 89,035 causal minute scores created from the supplied ticks. It separates the latest 30% of each symbol chronologically for validation and reports gate behavior, not trading performance.", "",
             "## Validation gate-frequency reference", "", "Reference gates: MRS >= 55, REE proxy >= 55, WDS freeze >= 70.", "", "| Symbol | Eligible minutes | Eligible rate | Freeze rate | Unfreeze rate |", "|---|---:|---:|---:|---:|"]
    for row in baseline:
        lines.append(f"| {row['symbol']} | {row['eligible_minutes']:,} | {row['eligible_rate']:.2%} | {row['freeze_rate']:.2%} | {row['unfreeze_rate']:.2%} |")
    lines += ["", "## Severe gate-stress sensitivity", "", "Scenario: 2 ATR multiplier, 3x spread, and two normalized slippage units. This is an intentionally conservative score-gating sensitivity check, not a fill simulation.", "", "| Symbol | Mean stressed MRS | Mean stressed WDS | Freeze rate | Watch rate |", "|---|---:|---:|---:|---:|"]
    for row in extreme:
        lines.append(f"| {row['symbol']} | {row['mean_stressed_mrs']:.2f} | {row['mean_stressed_wds']:.2f} | {row['freeze_rate']:.2%} | {row['watch_rate']:.2%} |")
    lines += ["", "## Included outputs", "", "- `scenario_segments.csv`: 4,904 contiguous, historically observed scenario segments.", "- `threshold_sensitivity.csv`: 288 chronological training/validation gate combinations.", "- `stress_gate_sensitivity.csv`: 81 ATR/spread/slippage gate-sensitivity combinations.", "", "## Limits before the trader stage", "", "- Do not select a threshold based on gate frequency. A defined trade model, untouched validation window, and outcome metrics are required.", "- Monetary PnL, commissions, margin, lot sizes, and executable Grid depth remain unavailable until verified MT5 symbol specifications are supplied.", "- The data source has no timezone metadata, so timestamps remain in the source-feed clock."]
    (args.output / "RESEARCH_REPORT.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Research lab completed: {len(rows):,} minutes, {len(segment_rows):,} segments, {len(calibration_rows):,} threshold rows, {len(stress_rows):,} stress rows.")


if __name__ == "__main__":
    main()
