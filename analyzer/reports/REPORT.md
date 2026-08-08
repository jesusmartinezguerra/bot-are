# ARE Analyzer - January 2026 report

## Scope

Tick archives were streamed directly from the supplied HistData ZIP files. Scores are causal research features, not an executable strategy, broker simulation, or profitability claim.

## Results

| Symbol | Valid ticks | Scored minutes | Mean MRS | Mean WDS | Mean REE proxy | FREEZE | WATCH |
|---|---:|---:|---:|---:|---:|---:|---:|
| XAUUSD | 9,135,062 | 28,808 | 30.81 | 37.60 | 51.99 | 42 | 697 |
| GBPJPY | 3,401,562 | 30,118 | 30.42 | 38.01 | 51.41 | 133 | 605 |
| USDJPY | 2,201,188 | 30,109 | 31.30 | 37.76 | 51.78 | 120 | 842 |

## Data-quality findings

- **XAUUSD**: 21 gaps over 60s (maximum 176404.9s), 0 duplicate timestamps, 0 out-of-order rows, and 0 impossible quotes.
- **GBPJPY**: 77 gaps over 60s (maximum 173056.8s), 0 duplicate timestamps, 0 out-of-order rows, and 0 impossible quotes.
- **USDJPY**: 186 gaps over 60s (maximum 172833.6s), 0 duplicate timestamps, 0 out-of-order rows, and 0 impossible quotes.

## Important limitations and next calibration

- The source archives have no broker contract, tick-value, leverage, margin, commission, or timezone specification. The analyzer does **not** invent them; therefore lot sizing, monetary PnL, margin stress, and an executable Grid-depth calculation are not reported.
- MRS, WDS, and REE weights and thresholds are initial, documented research defaults. Calibrate them on a training split and validate on a later, untouched split before building the execution engine.
- `REE` is a contemporaneous recoverability proxy. A future-outcome Recovery Success Rate requires an explicitly defined basket and broker-verified valuation model.
- The generated `minute_scores.csv` is suitable for scenario segmentation and threshold experiments. No future tick or bar is used to form a score.
