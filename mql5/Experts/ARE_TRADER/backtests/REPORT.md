# ARE_TRADER - XAUUSD, January 2026, Single Asset (observation-only)

## Scope

Real MetaTrader 5 Strategy Tester run of the compiled `ARE_TRADER.ex5`
against real broker tick history (`Model=4`, real ticks), `InpOperatingMode=0`
(Single Asset, XAUUSD only), `InpEnableExecution=false` throughout. No
order was ever placed; this validates the causal MRS/WDS/REE engine, the
Freeze/Unfreeze hysteresis fix, and the Grid Depth Engine's gating logic
against a full month of real tick data end-to-end inside MT5 itself
(complementary to the Python `analyzer/` research, which uses the same
January 2026 data but its own causal proxy implementation).

- Period: 2026.01.01 00:00 - 2026.01.30 23:59 (`ToDate=2026.01.31` is exclusive)
- Deposit: 100,000 USD, leverage 1:100 (arbitrary - no trade uses them yet)
- Ticks processed: 6,561,488 -> 28,625 M1 bars -> 43,200 timer evaluations (one per simulated minute)
- Raw per-minute log: `xauusd_jan2026_single_asset_minute_log.csv`

## Results

| Decision | Count | Share |
|---|---:|---:|
| NO_TRADE | 42,198 | 97.68% |
| WATCH | 679 | 1.57% |
| FREEZE | 323 | 0.75% |

`Frozen=true` also occurs exactly 323 times, matching the FREEZE decision
count one-for-one - confirms the Decision Engine and the Grid Depth Engine
now agree on hysteresis state (this was the bug fixed this session; before
the fix, they evaluated the raw WDS threshold independently and could
disagree mid-freeze).

| Grid Plan | Count | Share |
|---|---:|---:|
| Valid | 30,511 | 70.6% |
| Invalid: NO_SAFE_GRID_DEPTH | 12,366 | 28.6% |
| Invalid: WDS_FREEZE | 323 | 0.75% |

## Consistency checks

- No crash, no NaN/garbage values, across all 43,200 evaluations of a full
  real month of tick data.
- FREEZE decisions and `WDS_FREEZE` grid-plan rejections both total exactly
  323 - no drift between the two call sites that read the freeze state.

## Observations for later calibration (not conclusions)

- `NO_SAFE_GRID_DEPTH` is the dominant reason a grid plan is rejected even
  when MRS/WDS/REE would otherwise allow one - the risk/margin/volatility
  capacity formula (Grid Depth Engine, spec section 15) is the binding
  constraint most of the time at the current default risk budget (1%
  daily, 50/25/25 split) on a 100,000 USD account. Worth a closer look once
  the Calibration Engine (spec section 41) exists.
- This run never exercises the Asset Selector/Pool-vs-Portfolio behavior or
  cross-symbol margin correlation (section 35) - it deliberately only
  covers Single Asset XAUUSD, per current project scope.

## Explicit limits

- No order was placed. This is not a profitability or drawdown result -
  section 58 of the spec explicitly forbids treating gate frequency as a
  performance claim.
- `InpMaxSpreadPoints=0` (dynamic-baseline-only) was used; no fixed max
  spread was tested.
- This is one parameter set, not a calibration sweep (spec section 41 is
  still open).
