# ARE_TRADER - XAUUSD, January 2026, Single Asset (execution enabled)

## Scope

Real MetaTrader 5 Strategy Tester run of the compiled `ARE_TRADER.ex5`
against real broker tick history (`Model=4`, real ticks), `InpOperatingMode=0`
(Single Asset, XAUUSD only), `InpEnableExecution=true`. This is the same
January 2026 XAUUSD feed used by the observation-only run
(`xauusd_jan2026_single_asset_minute_log.csv` / `REPORT.md`), re-run with the
Task 3 order-placement code path active (CTrade-based, double-gated to
Tester-only + `InpEnableExecution`) to confirm the EA now places real
(Tester-only) orders and that the tester report is no longer pinned at zero.

- Period: 2026.01.01 00:00 - 2026.01.30 23:59 (`ToDate=2026.01.31` is exclusive)
- Deposit: 100,000 USD, leverage 1:100
- History quality: 100% real ticks
- Ticks processed: 6,561,488 -> 28,625 M1 bars -> 43,200 timer evaluations (one per simulated minute) - identical feed size to the observation-only run
- Raw per-minute log: `xauusd_jan2026_execution_minute_log.csv` (same column set as `xauusd_jan2026_single_asset_minute_log.csv`)
- Config used: `MQL5\config\are-trader-xauusd-jan2026-execution.ini` (same `[TesterInputs]` as Task 2's config, `InpEnableExecution=true`, `InpInspectExistingBaskets=false`, `InpDebugLog=true`)

## Results

### Decision tally (43,200 evaluations)

| Decision | Count | Share |
|---|---:|---:|
| NO_TRADE | 38,830 | 89.88% |
| PROTECT | 3,357 | 7.77% |
| WATCH | 676 | 1.56% |
| FREEZE | 323 | 0.75% |
| RESOLVE | 12 | 0.03% |
| EXPAND | 2 | 0.005% |

`FREEZE` again totals exactly 323, matching the observation-only run
one-for-one on the same feed - confirms nothing in the execution code path
disturbed the Freeze/Unfreeze hysteresis logic validated in the prior run.

### Execution outcome tally

| Placed | Count |
|---|---:|
| true | 2 |

| Reason | Count |
|---|---:|
| LEVEL_PLACED | 2 |

Both `[ARE] Execution` lines report `Placed=true Reason=LEVEL_PLACED`, and
both correspond 1:1 to the two `EXPAND` decisions in the tally above (no
`EXPAND` decision failed to place, and no execution attempt happened outside
an `EXPAND` decision).

### Tester report (`are_trader_xauusd_jan2026_execution.htm`)

The report is no longer pinned at zero. Real numbers, as shown:

| Metric | Value |
|---|---:|
| Total operations executed (positions) | 2 |
| Total transactions (deals) | 4 |
| Net profit | 48,750.24 USD |
| Gross profit | 52,048.68 USD |
| Gross loss | -3,298.44 USD |
| Profit factor | 15.78 |
| Recovery factor | 0.51 |
| Sharpe ratio | 0.10 |
| Max balance drawdown | 3,298.44 USD (3.30%) |
| Max equity drawdown | 95,125.70 USD (42.60%) |
| Profitable positions | 1 / 2 (50%) |

Deal-level detail from the report's Transactions table:

| # | Time | Type | Volume | Price | Note |
|---|---|---|---:|---:|---|
| 2 | 2026.01.02 01:35:53 | buy in | 1.00 | 4343.61 | first ladder level of the basket |
| 3 | 2026.01.30 04:21:00 | buy in | 0.12 | 5156.31 | second ladder level, same basket |
| 4 | 2026.01.30 23:59:00 | sell out | 0.12 | 4881.44 | forced close, "end of test", P/L -3,298.44 |
| 5 | 2026.01.30 23:59:00 | sell out | 1.00 | 4881.44 | forced close, "end of test", P/L +53,783.00, swap -1,734.32 |

Both `EXPAND` decisions add to the **same basket**: `BasketPositions` goes
0 -> 1 at the first `EXPAND` (2026.01.02 01:25:00) and 1 -> 2 at the second
(2026.01.30 04:21:00). No second, independent basket was ever opened.

## Consistency checks

- No crash, no NaN/garbage values, across all 43,200 evaluations of a full
  real month of tick data, with order placement active.
- `EXPAND` decision count (2) equals `Placed=true` count (2) equals
  `Reason=LEVEL_PLACED` count (2) equals the "Total operations executed"
  figure in the `.htm` report (2) - decision, execution log, and broker-side
  tester report all agree.
- `FREEZE` decision count (323) matches the observation-only run's `FREEZE`
  count exactly, on the same tick feed - the execution code path did not
  perturb the previously-validated Freeze/Unfreeze hysteresis.
- Same bar/tick counts (28,625 bars / 6,561,488 ticks / 100% real ticks) as
  the observation-only run, confirming both runs used the identical
  underlying data.

## Observations for later calibration (not conclusions)

- `PROTECT` (`BASKET_NOT_WORTH_RECOVERING_PROXY`) accounts for 3,357 of the
  43,200 evaluations (7.77%) - almost entirely the stretch after the first
  ladder level opened on 2026.01.02, while the basket sat in a floating
  loss for an extended period before price recovered later in the month.
  `RESOLVE` (`BASKET_RECOVERABLE_PROXY`) only fires 12 times. Both are
  decision-engine outputs only; **neither `PROTECT` nor `RESOLVE` triggers
  any execution in this slice** (see Explicit limits below).
- Only 2 `EXPAND` decisions occurred in the entire month, 28 days apart, both
  on the same basket. This is far fewer ladder-level placements than the
  observation-only run's Grid Plan validity count (30,511 of 43,200 evaluations
  had a valid grid plan) would suggest, but the `MRS_REE_GATE` is not the
  reason for most of that gap. Both the Grid Plan (`ARE_MakeGridPlan`) and the
  Decision Engine (`ARE_MakeDecision`) check `basket.exists &&
  basket.floating_pnl<0.0` *before* ever reaching the MRS/REE gate - when a
  real basket exists and is floating negative, the code routes straight to
  `RESOLVE`/`PROTECT` and the `MRS_REE_GATE` branch is never evaluated for
  that tick. The 28-day gap between the two `EXPAND` events is explained
  primarily by this: the basket opened on 2026.01.02 immediately went net
  negative and sat in `PROTECT`/`RESOLVE` (see the bullet above - 3,357
  `PROTECT` + 12 `RESOLVE` evaluations) rather than by `MRS_REE_GATE`
  failures. The gate only becomes reachable again once the basket
  either doesn't exist or is no longer floating negative. Worth revisiting
  once the Calibration Engine (spec section 41) exists.
- The second ladder level (2026.01.30, 0.12 lot) is an order of magnitude
  smaller than the first (1.00 lot) despite the basket being in a large
  floating **profit** (`BasketPnL=+79,505.68`) at that moment, not a loss -
  the Grid Depth Engine's sizing at that point was not investigated further
  here; this is only a raw observation, not a diagnosis.

## Explicit limits

- Both open positions were closed only because the Tester period ended
  (`"end of test"` in the deals table, 2026.01.30 23:59:00) - **not** by any
  strategy exit logic. RESOLVE/PROTECT decisions still do not execute
  anything (no partial close, no hedge, no basket-level exit) - this is
  explicitly out of scope per the design's Non-goals. The basket spent a
  large part of the month sitting in `PROTECT` with a real floating loss and
  nothing in the code acted on it; it was carried open, unresolved, until the
  test simply stopped. The 42.60% max equity drawdown reported by the tester
  happened to this same unresolved basket, with no code-level response.
- This is one uncalibrated parameter set on one month of historical data with
  a single, arbitrary starting deposit (100,000 USD) and no risk-of-ruin or
  walk-forward analysis. Per spec section 58, none of the numbers above
  ("net profit", "profit factor", "drawdown") should be read as a claim that
  the strategy is profitable or unprofitable - they are reported as-is,
  produced by a single run of unoptimized inputs.
- `InpMaxSpreadPoints=0` (dynamic-baseline-only) was used, same as the
  observation-only run; no fixed max spread was tested.
- Order placement is Tester-only (double-gated on `MQLInfoInteger(MQL_TESTER)`
  and `InpEnableExecution`); nothing in this run exercises the live/demo
  order path.
- Only 2 trades occurred, so profit factor (15.78), recovery factor (0.51)
  and Sharpe ratio (0.10) are statistically meaningless as performance
  indicators - they are reported for completeness only, per the framing
  above.
- Grid spacing is not guaranteed once price has drifted far from an idle
  ladder. The second ladder level (Order #3, placed 2026.01.30 04:21:00)
  was placed at 5156.21, but the ladder's furthest existing level at that
  point (the first level, filled 2026.01.02 01:35:53) was 4343.61 - a gap
  of roughly $812, far exceeding the maximum possible `grid_distance`
  (`InpMaxGridDistanceTicks=2000` * XAUUSD tick size, roughly $20). The
  first level sat unfilled/idle for about 28 days before the second was
  placed, during which price moved well past where the intended
  ladder-distance calculation (furthest level's price + `grid_distance`)
  would have placed it. The live-tick clamp added in Task 3
  (`ARE_PlaceNextGridLevel` in `ARE_TRADER.mq5`:
  `price=MathMax(price,current_tick.ask+min_broker_distance)` for
  `BUY_STOP`, `MathMin(...)` for `SELL_STOP`) then overrode the ladder
  spacing to keep the stop price valid relative to the live market, so the
  order it produced was pinned near the live price and filled almost
  immediately rather than sitting as a genuinely spaced pending order. The
  clamp itself is correct and necessary - without it the order would be
  rejected as an invalid stop price - but its interaction with the lack of
  any stale-pending-order expiry (there is no mechanism to cancel or
  re-price a pending level that has sat unfilled for a long time; see the
  design spec's "Open questions" section on whether existing pending
  orders should be proactively cancelled or re-priced) means grid spacing
  can silently collapse after a level sits idle long enough for price to
  drift far away.
