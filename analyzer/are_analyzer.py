#!/usr/bin/env python3
"""ARE Analyzer - tick-streaming historical research tool.

This tool deliberately does not place orders or claim profitability.  It reads
HistData tick archives one row at a time, validates the feed, aggregates
one-minute bars and scores only information known at each bar close.
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import math
import statistics
import zipfile
from collections import Counter, deque
from dataclasses import dataclass, asdict
from datetime import datetime
from pathlib import Path
from typing import Deque, Iterator


@dataclass
class Config:
    bar_seconds: int = 60
    feature_window: int = 20
    baseline_window: int = 120
    gap_seconds: int = 60
    initial_equity: float = 1000.0
    daily_risk_pct: float = 0.01
    expansion_fraction: float = 0.50
    resolution_fraction: float = 0.25
    emergency_fraction: float = 0.25
    mrs_minimum: float = 55.0
    wds_freeze: float = 70.0
    wds_unfreeze: float = 45.0
    ree_minimum: float = 55.0


@dataclass
class Quality:
    rows: int = 0
    valid_ticks: int = 0
    duplicate_ticks: int = 0
    invalid_timestamps: int = 0
    out_of_order: int = 0
    impossible_quotes: int = 0
    suspicious_jumps: int = 0
    gaps: int = 0
    max_gap_seconds: float = 0.0


@dataclass
class Bar:
    minute: int
    open: float
    high: float
    low: float
    close: float
    average_spread: float
    ticks: int


def clamp(value: float, low: float = 0.0, high: float = 100.0) -> float:
    return max(low, min(high, value))


def mean(values) -> float:
    return sum(values) / len(values) if values else 0.0


def parse_timestamp(raw: str, day_ordinals: dict[str, int]) -> tuple[int, int]:
    """Return a monotonic source-clock millisecond key and minute key.

    Conversion is deliberately calendar based, not timezone based.  Caching
    each date avoids a costly datetime parse for every individual tick.
    """
    if len(raw) != 18 or raw[8] != " " or not (raw[:8] + raw[9:]).isdigit():
        raise ValueError("invalid timestamp format")
    date = raw[:8]
    ordinal = day_ordinals.get(date)
    if ordinal is None:
        ordinal = datetime(int(date[:4]), int(date[4:6]), int(date[6:8])).toordinal()
        day_ordinals[date] = ordinal
    hour, minute, second, millisecond = int(raw[9:11]), int(raw[11:13]), int(raw[13:15]), int(raw[15:18])
    if hour > 23 or minute > 59 or second > 59:
        raise ValueError("invalid timestamp time")
    second_key = ordinal * 86400 + hour * 3600 + minute * 60 + second
    return second_key * 1000 + millisecond, ordinal * 1440 + hour * 60 + minute


def find_csv(archive: zipfile.ZipFile) -> str:
    names = [info.filename for info in archive.infolist() if info.filename.lower().endswith(".csv")]
    if len(names) != 1:
        raise ValueError(f"archive must contain exactly one CSV, found {names}")
    return names[0]


def stream_bars(symbol: str, archive_path: Path, cfg: Config) -> tuple[list[Bar], Quality]:
    quality = Quality()
    bars: list[Bar] = []
    previous_ms: int | None = None
    previous_mid: float | None = None
    current: dict | None = None
    day_ordinals: dict[str, int] = {}

    with zipfile.ZipFile(archive_path) as archive:
        with archive.open(find_csv(archive)) as binary:
            reader = csv.reader(io.TextIOWrapper(binary, encoding="ascii", newline=""))
            for row in reader:
                quality.rows += 1
                if len(row) < 3:
                    continue
                try:
                    timestamp_ms, minute = parse_timestamp(row[0], day_ordinals)
                    bid, ask = float(row[1]), float(row[2])
                except (ValueError, OverflowError):
                    quality.invalid_timestamps += 1
                    continue
                if not (math.isfinite(bid) and math.isfinite(ask)) or bid <= 0 or ask <= bid:
                    quality.impossible_quotes += 1
                    continue
                mid = (bid + ask) / 2.0
                if previous_ms is not None:
                    delta = timestamp_ms - previous_ms
                    if delta == 0:
                        quality.duplicate_ticks += 1
                    elif delta < 0:
                        quality.out_of_order += 1
                        continue
                    elif delta > cfg.gap_seconds * 1000:
                        quality.gaps += 1
                        quality.max_gap_seconds = max(quality.max_gap_seconds, delta / 1000.0)
                    # A 1% tick-to-tick move is flagged but retained: it can be real.
                    if previous_mid and abs(mid / previous_mid - 1.0) > 0.01:
                        quality.suspicious_jumps += 1
                previous_ms, previous_mid = timestamp_ms, mid
                quality.valid_ticks += 1
                if current is None or minute != current["minute"]:
                    if current is not None:
                        bars.append(Bar(**current))
                    current = {"minute": minute, "open": mid, "high": mid, "low": mid,
                               "close": mid, "average_spread": ask - bid, "ticks": 1}
                else:
                    current["high"] = max(current["high"], mid)
                    current["low"] = min(current["low"], mid)
                    current["close"] = mid
                    current["average_spread"] += ask - bid
                    current["ticks"] += 1
            if current is not None:
                current["average_spread"] /= current["ticks"]
                bars.append(Bar(**current))
    # Close prior bars also need their spread averaged.
    for bar in bars[:-1]:
        # Spread was stored as a sum until the bar was closed.  Normalize once.
        bar.average_spread /= bar.ticks
    return bars, quality


def score_bars(symbol: str, bars: list[Bar], cfg: Config) -> list[dict]:
    """Calculate causal MRS/WDS/REE proxies at each completed minute bar.

    Scores are research features, not calibrated trading rules.  No future bar
    is accessed.  REE is an *estimated* recoverability score for a generic
    adverse basket, not an observed recovery result.
    """
    out: list[dict] = []
    closes: Deque[float] = deque(maxlen=cfg.baseline_window + 1)
    ranges: Deque[float] = deque(maxlen=cfg.baseline_window)
    spreads: Deque[float] = deque(maxlen=cfg.baseline_window)
    activities: Deque[int] = deque(maxlen=cfg.baseline_window)
    returns: Deque[float] = deque(maxlen=cfg.baseline_window)

    for bar in bars:
        if closes:
            returns.append((bar.close - closes[-1]) / closes[-1])
        closes.append(bar.close)
        ranges.append((bar.high - bar.low) / bar.close)
        spreads.append(bar.average_spread / bar.close)
        activities.append(bar.ticks)
        if len(closes) < cfg.feature_window + 1:
            continue

        closes_list = list(closes)
        recent = closes_list[-(cfg.feature_window + 1):]
        diffs = [recent[i] - recent[i - 1] for i in range(1, len(recent))]
        abs_path = sum(abs(x) for x in diffs)
        direction = recent[-1] - recent[0]
        efficiency = abs(direction) / abs_path if abs_path else 0.0
        avg_abs_move = abs_path / len(diffs) if diffs else 0.0
        direction_strength = abs(direction) / (avg_abs_move * len(diffs) + 1e-12)
        momentum = (recent[-1] - recent[-6]) / (avg_abs_move * 5 + 1e-12)
        signs = [1 if x > 0 else -1 if x < 0 else 0 for x in diffs]
        nonzero = [x for x in signs if x]
        reversals = sum(nonzero[i] != nonzero[i - 1] for i in range(1, len(nonzero)))
        reversal_ratio = reversals / max(1, len(nonzero) - 1)
        recent_range = mean(list(ranges)[-cfg.feature_window:])
        historic_range = mean(ranges)
        volatility_ratio = recent_range / (historic_range + 1e-12)
        recent_spread = mean(list(spreads)[-cfg.feature_window:])
        historic_spread = mean(spreads)
        spread_ratio = recent_spread / (historic_spread + 1e-12)
        activity_ratio = mean(list(activities)[-cfg.feature_window:]) / (mean(activities) + 1e-12)
        # A false breakout proxy: intrawindow excursion that failed to persist.
        excursion = max(recent) - min(recent)
        false_break = 1.0 - min(1.0, abs(direction) / (excursion + 1e-12))

        trend_score = clamp(100 * efficiency)
        momentum_score = clamp(50 + 25 * max(-2.0, min(2.0, momentum)))
        volatility_score = clamp(100 * min(volatility_ratio, 2.0) / 2.0)
        activity_score = clamp(50 * min(activity_ratio, 2.0))
        structure_score = clamp(100 * min(1.0, direction_strength / 1.0))
        # Elevated volatility only helps MRS when directional efficiency is present.
        mrs = clamp(0.30 * trend_score + 0.22 * momentum_score + 0.18 * structure_score +
                    0.15 * volatility_score * efficiency + 0.15 * activity_score)
        spread_damage = clamp(100 * (spread_ratio - 0.8) / 1.2)
        wds = clamp(0.38 * 100 * reversal_ratio + 0.28 * 100 * false_break +
                    0.20 * spread_damage + 0.14 * clamp(100 * (volatility_ratio - 1.0)))
        # Conservative recoverability proxy. Margin/contract valuation needs a
        # verified MT5 symbol specification and is intentionally not inferred.
        ree = clamp(0.46 * mrs + 0.34 * (100 - wds) + 0.20 * (100 - spread_damage))
        if wds >= cfg.wds_freeze:
            decision = "FREEZE"
        elif mrs >= cfg.mrs_minimum and ree >= cfg.ree_minimum:
            decision = "WATCH"
        else:
            decision = "NO_TRADE"
        out.append({
            "symbol": symbol, "timestamp": datetime.fromordinal(bar.minute // 1440).replace(
                hour=(bar.minute % 1440) // 60, minute=bar.minute % 60).isoformat(sep=" "),
            "close": round(bar.close, 8), "ticks": bar.ticks,
            "mrs": round(mrs, 2), "wds": round(wds, 2), "ree_proxy": round(ree, 2),
            "volatility_ratio": round(volatility_ratio, 4), "spread_ratio": round(spread_ratio, 4),
            "directional_efficiency": round(efficiency, 4), "decision": decision,
        })
    return out


def classify(row: dict) -> str:
    if row["wds"] >= 70:
        return "WHIPSAW"
    if row["volatility_ratio"] >= 1.6 and row["directional_efficiency"] >= 0.45:
        return "EXTREME_VOLATILITY"
    if row["mrs"] >= 65:
        return "TREND_UP_OR_DOWN"
    if row["volatility_ratio"] <= 0.65:
        return "LOW_ACTIVITY"
    if row["directional_efficiency"] <= 0.20:
        return "RANGE"
    return "TRANSITION"


def summarize(symbol: str, rows: list[dict], quality: Quality, cfg: Config) -> dict:
    regimes = Counter(classify(row) for row in rows)
    decisions = Counter(row["decision"] for row in rows)
    return {
        "symbol": symbol,
        "quality": asdict(quality),
        "scored_minutes": len(rows),
        "score_means": {key: round(mean([r[key] for r in rows]), 2) for key in ("mrs", "wds", "ree_proxy")},
        "regimes": dict(regimes), "decisions": dict(decisions),
        "risk_budget": {
            "equity": cfg.initial_equity,
            "daily_budget": round(cfg.initial_equity * cfg.daily_risk_pct, 2),
            "expansion_budget": round(cfg.initial_equity * cfg.daily_risk_pct * cfg.expansion_fraction, 2),
            "resolution_budget": round(cfg.initial_equity * cfg.daily_risk_pct * cfg.resolution_fraction, 2),
            "emergency_budget": round(cfg.initial_equity * cfg.daily_risk_pct * cfg.emergency_fraction, 2),
            "status": "Currency conversion, lot sizing and margin are withheld until verified MT5 symbol specifications are supplied.",
        },
    }


def write_reports(output: Path, summaries: list[dict], all_rows: list[dict], cfg: Config) -> None:
    output.mkdir(parents=True, exist_ok=True)
    (output / "run_summary.json").write_text(json.dumps({"config": asdict(cfg), "symbols": summaries}, indent=2), encoding="utf-8")
    fields = list(all_rows[0]) if all_rows else ["symbol", "timestamp", "close", "mrs", "wds", "ree_proxy", "decision"]
    with (output / "minute_scores.csv").open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader(); writer.writerows(all_rows)
    lines = ["# ARE Analyzer - January 2026 report", "", "## Scope", "",
             "Tick archives were streamed directly from the supplied HistData ZIP files. Scores are causal research features, not an executable strategy, broker simulation, or profitability claim.", "",
             "## Results", "", "| Symbol | Valid ticks | Scored minutes | Mean MRS | Mean WDS | Mean REE proxy | FREEZE | WATCH |", "|---|---:|---:|---:|---:|---:|---:|---:|"]
    for s in summaries:
        q, m, d = s["quality"], s["score_means"], s["decisions"]
        lines.append(f"| {s['symbol']} | {q['valid_ticks']:,} | {s['scored_minutes']:,} | {m['mrs']:.2f} | {m['wds']:.2f} | {m['ree_proxy']:.2f} | {d.get('FREEZE', 0):,} | {d.get('WATCH', 0):,} |")
    lines += ["", "## Data-quality findings", ""]
    for s in summaries:
        q = s["quality"]
        lines.append(f"- **{s['symbol']}**: {q['gaps']:,} gaps over {cfg.gap_seconds}s (maximum {q['max_gap_seconds']:.1f}s), {q['duplicate_ticks']:,} duplicate timestamps, {q['out_of_order']:,} out-of-order rows, and {q['impossible_quotes']:,} impossible quotes.")
    lines += ["", "## Important limitations and next calibration", "",
              "- The source archives have no broker contract, tick-value, leverage, margin, commission, or timezone specification. The analyzer does **not** invent them; therefore lot sizing, monetary PnL, margin stress, and an executable Grid-depth calculation are not reported.",
              "- MRS, WDS, and REE weights and thresholds are initial, documented research defaults. Calibrate them on a training split and validate on a later, untouched split before building the execution engine.",
              "- `REE` is a contemporaneous recoverability proxy. A future-outcome Recovery Success Rate requires an explicitly defined basket and broker-verified valuation model.",
              "- The generated `minute_scores.csv` is suitable for scenario segmentation and threshold experiments. No future tick or bar is used to form a score."]
    (output / "REPORT.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def parse_input(value: str) -> tuple[str, Path]:
    if "=" not in value:
        raise argparse.ArgumentTypeError("input must be SYMBOL=PATH_TO_ZIP")
    symbol, path = value.split("=", 1)
    return symbol.upper(), Path(path)


def main() -> None:
    parser = argparse.ArgumentParser(description="ARE tick-streaming research analyzer")
    parser.add_argument("--input", action="append", type=parse_input, required=True, help="SYMBOL=ZIP path; repeat per symbol")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--config", type=Path, help="optional JSON config overrides")
    args = parser.parse_args()
    cfg = Config()
    if args.config:
        supplied = json.loads(args.config.read_text(encoding="utf-8"))
        for name, value in supplied.items():
            if not hasattr(cfg, name):
                raise ValueError(f"Unknown config field: {name}")
            setattr(cfg, name, value)
    if cfg.bar_seconds != 60:
        raise ValueError("this release aggregates completed one-minute bars only (bar_seconds must be 60)")
    if not math.isclose(cfg.expansion_fraction + cfg.resolution_fraction + cfg.emergency_fraction, 1.0):
        raise ValueError("risk fractions must sum to 1.0")
    summaries, all_rows = [], []
    for symbol, path in args.input:
        if not path.is_file():
            raise FileNotFoundError(path)
        bars, quality = stream_bars(symbol, path, cfg)
        rows = score_bars(symbol, bars, cfg)
        summaries.append(summarize(symbol, rows, quality, cfg))
        all_rows.extend(rows)
        print(f"{symbol}: {quality.valid_ticks:,} valid ticks -> {len(rows):,} scored minutes")
    write_reports(args.output, summaries, all_rows, cfg)
    print(f"Reports written to {args.output}")


if __name__ == "__main__":
    main()
