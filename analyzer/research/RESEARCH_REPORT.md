# ARE Research Lab - January 2026

## Scope

This lab used the 89,035 causal minute scores created from the supplied ticks. It separates the latest 30% of each symbol chronologically for validation and reports gate behavior, not trading performance.

## Validation gate-frequency reference

Reference gates: MRS >= 55, REE proxy >= 55, WDS freeze >= 70.

| Symbol | Eligible minutes | Eligible rate | Freeze rate | Unfreeze rate |
|---|---:|---:|---:|---:|
| GBPJPY | 175 | 1.94% | 0.21% | 56.65% |
| USDJPY | 252 | 2.79% | 0.40% | 57.30% |
| XAUUSD | 207 | 2.40% | 0.26% | 58.78% |

## Severe gate-stress sensitivity

Scenario: 2 ATR multiplier, 3x spread, and two normalized slippage units. This is an intentionally conservative score-gating sensitivity check, not a fill simulation.

| Symbol | Mean stressed MRS | Mean stressed WDS | Freeze rate | Watch rate |
|---|---:|---:|---:|---:|
| GBPJPY | 24.42 | 87.30 | 96.93% | 0.28% |
| USDJPY | 25.30 | 86.99 | 96.37% | 0.36% |
| XAUUSD | 24.81 | 87.10 | 97.04% | 0.22% |

## Included outputs

- `scenario_segments.csv`: 4,904 contiguous, historically observed scenario segments.
- `threshold_sensitivity.csv`: 288 chronological training/validation gate combinations.
- `stress_gate_sensitivity.csv`: 81 ATR/spread/slippage gate-sensitivity combinations.

## Limits before the trader stage

- Do not select a threshold based on gate frequency. A defined trade model, untouched validation window, and outcome metrics are required.
- Monetary PnL, commissions, margin, lot sizes, and executable Grid depth remain unavailable until verified MT5 symbol specifications are supplied.
- The data source has no timezone metadata, so timestamps remain in the source-feed clock.
