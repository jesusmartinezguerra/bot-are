# Execution Engine — Initial Grid Opening (ARE_TRADER, Etapa 10 slice 1)

## Status

Approved by user 2026-08-08. Ready for implementation planning.

## Context

`ARE_TRADER.mq5` (MQL5, observation-only EA) already implements, validated
against real January 2026 XAUUSD tick data via MetaTrader 5 Strategy
Tester:

- Broker Specification Engine (dynamic `SYMBOL_*` lookup)
- Causal MRS/WDS/REE-proxy scoring on M1 bars (no lookahead)
- Freeze/Unfreeze hysteresis (per-symbol persistent state, fixed and
  verified this session — see `mql5/Experts/ARE_TRADER/backtests/REPORT.md`)
- Hard Daily Loss gate, equity-proportional 50/25/25 risk budget
- Grid Depth Engine (`ARE_MakeGridPlan`): computes a dynamic safe depth,
  distance, and volume for an *observation-only* plan, but never places an
  order
- Decision Engine (`ARE_MakeDecision`): reaches at most `WATCH_ONLY` — the
  `ARE_EXPAND` / `ARE_REDUCED_EXPANSION` enum values exist in
  `ARE_Common.mqh` but are never returned

No order-placement code exists anywhere in the project. The most recent
XAUUSD/January-2026 backtest (`mql5/Experts/ARE_TRADER/backtests/`)
therefore shows Net Profit, Max Drawdown, and Profit Factor all at 0.00 —
not because of a bug, but because zero trades were ever possible.

This spec covers the smallest next increment: authorizing and placing the
**initial** Grid orders for a symbol that has no existing exposure yet.
Basket profit-taking, resolve/recovery execution, and portfolio-mode
correlation remain out of scope and will each get their own design pass
later, per master spec section 59's staged protocol and section 60's
"do not build a mountain of code" rule.

## Goal

When conditions genuinely authorize expansion (regime favorable, risk
budget available, Grid Plan valid, no existing basket for the symbol),
`ARE_TRADER` places one directional pending order per evaluation cycle,
building up to the computed safe depth over time — never all at once,
never in both directions by default, never as a martingale response to a
prior loss (there is no prior loss yet in this slice: this is opening
exposure, not recovering it).

## Non-goals (explicitly deferred)

- Closing a basket on profit (spec section 27–28)
- RESOLVE/RECOVERY execution (spec sections 21–24) — `ARE_RESOLVE_DECISION`
  already exists as an analysis-only signal; executing on it is separate
  work
- Adding to an *existing* basket (this slice only opens a basket that does
  not yet exist for the symbol)
- Portfolio-mode cross-symbol risk correlation (spec section 35)
- Live/demo chart execution — deliberately restricted to the Strategy
  Tester in this slice (see Safety below)

## Design

### 1. Decision Engine: WATCH_ONLY → EXPAND

In `ARE_MakeDecision`, after the existing gates (hard daily stop, max
spread, WDS freeze, basket-in-drawdown) and the existing
`scores.mrs>=InpMRSThreshold && scores.ree_proxy>=InpREEThreshold` check
that currently returns `ARE_WATCH_ONLY`:

- If, in addition, a freshly computed `ARE_GridPlan.valid==true` **and**
  `basket.positions==0` (no existing position or pending order tagged with
  `InpMagicNumber` for this symbol) → return `ARE_EXPAND`.
- Otherwise (plan invalid, or a basket already exists) → stays
  `ARE_WATCH_ONLY` as today.

This requires computing the Grid Plan *before* the decision in
`ARE_Assess`, not after (today `ARE_MakeGridPlan` is called only after the
decision, inside `ARE_Evaluate`, for the single best-scoring symbol). The
plan becomes an input to the decision rather than a downstream artifact of
it.

### 2. Basket/pending-order awareness

`ARE_ReadBasket` currently only counts open positions
(`PositionsTotal()`/`PositionGetTicket`). It must also count **pending
orders** tagged with `InpMagicNumber` for the symbol
(`OrdersTotal()`/`OrderGetTicket`/`OrderGetInteger(ORDER_MAGIC)`), since a
partially-built ladder (some levels filled, some still pending) must still
count toward `safe_depth` and toward the `basket.positions==0` gate above.

### 3. Execution: one order per cycle, ladder-aware pricing

On `ARE_EXPAND` for the selected symbol, once per evaluation cycle:

1. Count existing levels (open positions + pending orders, magic-tagged,
   this symbol). If count `>= plan.safe_depth`, do nothing this cycle.
2. Determine direction from `scores.direction` sign: positive →
   `BUY STOP`, negative → `SELL STOP` (matches spec section 18: pending
   directional orders, not simultaneous BUY+SELL).
3. Determine price:
   - No existing level yet → current price ± `plan.grid_distance` in the
     trend direction.
   - Existing level(s) present → furthest existing level's price ±
     `plan.grid_distance` further in the same direction (never
     recalculated from a possibly-moved current price, so spacing stays
     uniform).
4. Send the order via `CTrade::BuyStop` / `CTrade::SellStop` with
   `plan.volume`, tagged with `InpMagicNumber`.

### 4. Safety: Tester-only execution

`InpEnableExecution` remains an input, but the actual `CTrade` call is
additionally gated on `MQLInfoInteger(MQL_TESTER)`. Attaching the compiled
EA to any real chart (demo or live) never sends an order in this slice,
regardless of input values. This is a hard-coded gate, not a
user-configurable one — removing it is explicitly out of scope for this
slice and would need its own explicit design/approval pass.

### 5. Error handling

`CTrade` order-send failures (insufficient margin, broker minimum-distance
violation, symbol trading disabled, etc.) are logged through the existing
`[ARE]` log line (retcode + description) and are not retried within the
same cycle — the next evaluation (next simulated minute) re-checks
conditions from scratch and may try again if still authorized. No
exception-style abort of the whole EA.

### 6. Testing

- A new MQL5 script test (same pattern as
  `mql5/Scripts/Test_FreezeHysteresis.mq5`) for the pure, non-trading
  logic: ladder price calculation given an existing level list, and the
  EXPAND gate given synthetic plan/basket/score combinations. Run via the
  established startup-`.ini` + closed-terminal pattern, asserting on
  `[TEST]` log lines.
- A real Strategy Tester run over XAUUSD, January 2026 (same
  configuration as the prior backtest:
  `mql5/Experts/ARE_TRADER/backtests/`), Single Asset mode, confirming:
  - At least one real order is placed and the tester report no longer
    shows Net Profit / Max Drawdown / Profit Factor pinned at 0.00
  - No martingale-shaped behavior (lot size does not increase because a
    prior order lost — trivially true in this slice since there is no
    loss-driven re-entry logic yet, but worth asserting explicitly)
  - Grid levels are evenly spaced per the ladder rule above

## Open questions / assumptions to revisit later

- This slice does not yet cap total concurrent exposure across a
  Portfolio-mode multi-symbol run (out of scope here; Single Asset only,
  matching current project focus on XAUUSD).
- `plan.safe_depth` is recomputed every cycle from current
  risk/margin/volatility capacity — it can shrink between cycles (e.g. if
  margin tightens), which would stop new levels from being added but does
  not touch already-placed pending orders. Whether existing pending orders
  should ever be proactively cancelled if capacity shrinks below their
  count is deferred to the basket-management design.
