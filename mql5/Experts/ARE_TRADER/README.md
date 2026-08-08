# ARE_TRADER - MT5 observation foundation

`ARE_TRADER.mq5` is the next incremental deliverable after the offline
analyzer. It is intentionally an **observation-only** Expert Advisor: it sends
no order requests, even if `InpEnableExecution` is changed. This preserves the
development protocol in the master prompt until each risk and execution stage
has been individually validated.

## What it implements

- Dynamic MT5 symbol specification lookup: point, tick size/value, contract
  size, volume limits/step, margin, stops and freeze levels.
- A closed daily-PnL hard-stop gate using MT5 account history.
- Equity-proportional daily budget split 50/25/25 by default, configurable and
  required to total 100%.
- Causal M1 MRS, WDS and REE-proxy calculation using only completed bars.
- Single Asset or Asset Pool monitoring and an Asset Opportunity Score.
- A state machine limited to `IDLE`, `WATCH`, `FREEZE`, and
  `EMERGENCY_STOP` until an execution engine is implemented and tested.
- An observation-only Grid Plan that derives a dynamic distance, volume, and
  safe depth from current ATR, spread, daily Expansion Budget, `OrderCalcProfit`
  and `OrderCalcMargin`. It proposes no order and treats the selected free
  margin reserve as a percentage of account equity.
- Optional read-only basket inspection, filtered by `InpMagicNumber`. A basket
  in drawdown receives a recoverability proxy and blocks Grid expansion. The EA
  can enter `RECOVERY_ANALYSIS` or `PROTECT`, but performs neither resolution
  nor closure.
- Audit logging and an on-chart status panel.

## Installation and validation

1. Copy `ARE_TRADER` into the terminal's `MQL5/Experts` directory, preserving
   its `Include` subfolder.
2. Compile in MetaEditor and attach it to a demo chart.
3. Confirm the terminal's exact symbol suffixes. For example, your broker may
   use `XAUUSD.a` rather than `XAUUSD`.
4. Observe logs and panel output first. Do not enable live execution.

## Not implemented yet

Order placement, pending Grid orders, basket management, recovery, position
resolution, portfolio correlation, external-news filters, and broker-accurate
backtest PnL are deliberately absent. They depend on the validated behavior of
this foundation and must remain blocked until the individual engines are tested.
