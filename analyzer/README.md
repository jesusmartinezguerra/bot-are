# ARE_ANALYZER

The first deliverable defined by the Adaptive Regime Engine specification. It
streams HistData tick ZIP files, validates quotes, aggregates one-minute bars,
and calculates causal, documented research proxies for MRS, WDS, and REE.

It does not open trades, optimize parameters blindly, use martingale, assume
broker specifications, or assert profitability.

## Run

Use Python 3.11+ with no third-party packages:

```powershell
python .\are_analyzer.py `
  --input "XAUUSD=C:\path\HISTDATA_COM_ASCII_XAUUSD_T202601.zip" `
  --input "GBPJPY=C:\path\HISTDATA_COM_ASCII_GBPJPY_T202601.zip" `
  --input "USDJPY=C:\path\HISTDATA_COM_ASCII_USDJPY_T202601.zip" `
  --output .\reports
```

Generated files:

- `run_summary.json`: provenance-free, machine-readable summary and defaults.
- `minute_scores.csv`: one causal score per completed minute bar.
- `REPORT.md`: a compact review of results, data quality, and limits.

## Research lab

After producing the minute scores, run the calibration and stress lab:

```powershell
python .\research_lab.py --scores .\reports\minute_scores.csv --output .\research
```

It produces a chronological 70/30 training/validation threshold-sensitivity
table, real historical regime segments, and score-gating stress sensitivity for
ATR, spread, and slippage assumptions. These outputs do not select an optimum
or simulate currency PnL: broker specifications are still required for that.

## Design choices

- The source timestamp is retained as supplied because HistData ZIP archives do
  not include timezone metadata.
- Gaps are detected and counted. They are never filled.
- A suspicious 1% tick-to-tick price jump is flagged but retained; deleting it
  would silently alter historical evidence.
- MRS, WDS, and REE are research proxies with explicit defaults, not universal
  truths. The next step is separated training/validation calibration.
- Monetary PnL, lot size, margin, and broker-safe Grid depth require verified
  MetaTrader 5 symbol properties. They are intentionally not inferred from
  quote data.
