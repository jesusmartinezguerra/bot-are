# Execution Engine — Initial Grid Opening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `ARE_TRADER.mq5` place its first real (Strategy-Tester-only) directional Grid orders — one pending order per evaluation cycle, up to a dynamically computed safe depth — instead of staying permanently observation-only.

**Architecture:** The Decision Engine gains a new `ARE_EXPAND` outcome, gated on a Grid Plan that is now computed *before* the decision (not after, as today) and on how many ladder levels (open + pending, magic-tagged) already exist for the symbol. A new pure function computes the next ladder level's price/direction from that state; a thin `CTrade`-based wrapper sends it, hard-gated to only ever run inside the Strategy Tester.

**Tech Stack:** MQL5, MetaTrader 5 `CTrade` (`Trade\Trade.mqh`), MetaEditor64 CLI compilation, Strategy Tester `.ini` automation (same pattern used earlier this session for the Freeze/Unfreeze hysteresis fix).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-08-execution-engine-grid-open-design.md` — every task below implements one numbered section of it.
- Project root: `C:\SAMBU\bot-are`. MT5 terminal data folder (this machine): `C:\Users\Peter\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075`.
- MetaEditor CLI: `C:\Program Files\MetaTrader 5\MetaEditor64.exe`. Terminal exe: `C:\Program Files\MetaTrader 5\terminal64.exe`.
- Python (for CSV parsing in Task 4 only): `C:\Users\Peter\AppData\Local\Programs\Python\Python312\python.exe`.
- Order sending happens only when **both** `InpEnableExecution==true` **and** `MQLInfoInteger(MQL_TESTER)==true`. Attaching the EA to any live/demo chart never sends an order regardless of input values — this gate is hard-coded, not user-configurable, per spec section 4.
- Never place more than one order per evaluation cycle. Never place both a BUY-side and SELL-side order for the same symbol. All orders use `InpMagicNumber` (default `2600101`).
- Order volume always comes from `plan.volume` (Grid Depth Engine output) — never increased because a prior order lost (no martingale, master spec section 20/56).
- Every file edit in this plan is inside `mql5/Experts/ARE_TRADER/` (source of truth) and must be copied into the terminal's `MQL5\Experts\ARE_TRADER\` before compiling — the terminal only compiles from its own MQL5 folder, never from `C:\SAMBU\bot-are` directly.
- After every compile, read the resulting log file and confirm `0 errors` before proceeding — do not assume success from a non-crashing command.

---

## Task 1: Basket/Ladder state tracking

**Files:**
- Modify: `mql5/Experts/ARE_TRADER/Include/ARE_Common.mqh` (`ARE_BasketSnapshot` struct, add `ARE_TrackLadderLevel`)
- Modify: `mql5/Experts/ARE_TRADER/ARE_TRADER.mq5` (`ARE_ReadBasket`)
- Create: `mql5/Scripts/Test_LadderTracking.mq5`

**Interfaces:**
- Produces: `ARE_TrackLadderLevel(ARE_BasketSnapshot &basket, const bool is_buy_side, const double price)` — pure mutator, no MT5 API calls. Later tasks (2, 3) rely on the fields it maintains: `basket.ladder_level_count` (int), `basket.furthest_level_price` (double), `basket.ladder_is_buy_side` (bool), `basket.pending_orders` (int).

- [ ] **Step 1: Add the new fields and the pure helper to `ARE_Common.mqh`**

Open `C:\SAMBU\bot-are\mql5\Experts\ARE_TRADER\Include\ARE_Common.mqh`. Find the `ARE_BasketSnapshot` struct:

```mql5
struct ARE_BasketSnapshot
  {
   bool   exists;
   int    positions;
   double buy_volume;
   double sell_volume;
   double net_volume;
   double floating_pnl;
   double margin;
   double weighted_entry;
   double current_price;
   double distance_to_weighted_entry;
   double ree;
   string status;
  };
```

Replace it with:

```mql5
struct ARE_BasketSnapshot
  {
   bool   exists;
   int    positions;
   double buy_volume;
   double sell_volume;
   double net_volume;
   double floating_pnl;
   double margin;
   double weighted_entry;
   double current_price;
   double distance_to_weighted_entry;
   double ree;
   string status;
   int    pending_orders;
   int    ladder_level_count;
   double furthest_level_price;
   bool   ladder_is_buy_side;
  };

// Tracks the furthest-out price of a one-directional order ladder as each
// open position / pending order tagged with our magic number is scanned.
// Pure: mutates only the struct passed in, no MT5 API calls, safe to unit
// test standalone.
void ARE_TrackLadderLevel(ARE_BasketSnapshot &basket,const bool is_buy_side,const double price)
  {
   basket.ladder_level_count++;
   if(basket.ladder_level_count==1)
     {
      basket.furthest_level_price=price;
      basket.ladder_is_buy_side=is_buy_side;
     }
   else if(is_buy_side==basket.ladder_is_buy_side)
     {
      basket.furthest_level_price=(is_buy_side ? MathMax(basket.furthest_level_price,price) : MathMin(basket.furthest_level_price,price));
     }
  }
```

- [ ] **Step 2: Write the failing test**

Create `C:\SAMBU\bot-are\mql5\Scripts\Test_LadderTracking.mq5`:

```mql5
#property strict

#include "..\Experts\ARE_TRADER\Include\ARE_Common.mqh"

void OnStart(void)
  {
   bool all_passed=true;

   ARE_BasketSnapshot b1;
   ZeroMemory(b1);
   ARE_TrackLadderLevel(b1,true,4300.0);
   bool ok1=(b1.ladder_level_count==1 && b1.ladder_is_buy_side==true && b1.furthest_level_price==4300.0);
   PrintFormat("[TEST] case=1 %s -- first level seeds state",(ok1?"PASS":"FAIL"));
   all_passed=all_passed && ok1;

   ARE_TrackLadderLevel(b1,true,4310.0);
   bool ok2=(b1.ladder_level_count==2 && b1.furthest_level_price==4310.0);
   PrintFormat("[TEST] case=2 %s -- extends furthest buy level upward",(ok2?"PASS":"FAIL"));
   all_passed=all_passed && ok2;

   ARE_TrackLadderLevel(b1,true,4305.0);
   bool ok3=(b1.ladder_level_count==3 && b1.furthest_level_price==4310.0);
   PrintFormat("[TEST] case=3 %s -- closer level does not move furthest back",(ok3?"PASS":"FAIL"));
   all_passed=all_passed && ok3;

   ARE_BasketSnapshot b2;
   ZeroMemory(b2);
   ARE_TrackLadderLevel(b2,false,4300.0);
   ARE_TrackLadderLevel(b2,false,4290.0);
   ARE_TrackLadderLevel(b2,false,4295.0);
   bool ok4=(b2.ladder_level_count==3 && b2.ladder_is_buy_side==false && b2.furthest_level_price==4290.0);
   PrintFormat("[TEST] case=4 %s -- sell side tracks minimum price",(ok4?"PASS":"FAIL"));
   all_passed=all_passed && ok4;

   PrintFormat("[TEST] RESULT=%s",(all_passed?"ALL_PASSED":"FAILURES_PRESENT"));
  }
```

This will not compile yet in the terminal until Step 1's header change is also deployed there — that is expected and is the point of the next step.

- [ ] **Step 3: Deploy only the test script (not yet the header change) and confirm it fails to compile**

```bash
TERM="/c/Users/Peter/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075"
cp "/c/SAMBU/bot-are/mql5/Scripts/Test_LadderTracking.mq5" "$TERM/MQL5/Scripts/"
```

```powershell
$term = "C:\Users\Peter\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075"
& 'C:\Program Files\MetaTrader 5\MetaEditor64.exe' /compile:"$term\MQL5\Scripts\Test_LadderTracking.mq5" /log:"$term\MQL5\Logs\test_ladder_compile.log"
Get-Content -Encoding Unicode "$term\MQL5\Logs\test_ladder_compile.log" | Select-String "error|Result"
```

Expected: `error 258: undeclared identifier` (or similar) referencing `ARE_TrackLadderLevel`, and `Result: N errors`. If it compiles with 0 errors here, the terminal already has a stale copy of `ARE_Common.mqh` from a previous step — stop and check `$term\MQL5\Experts\ARE_TRADER\Include\ARE_Common.mqh` before continuing.

- [ ] **Step 4: Deploy the header change and recompile**

```bash
TERM="/c/Users/Peter/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075"
cp "/c/SAMBU/bot-are/mql5/Experts/ARE_TRADER/Include/ARE_Common.mqh" "$TERM/MQL5/Experts/ARE_TRADER/Include/"
```

```powershell
$term = "C:\Users\Peter\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075"
& 'C:\Program Files\MetaTrader 5\MetaEditor64.exe' /compile:"$term\MQL5\Scripts\Test_LadderTracking.mq5" /log:"$term\MQL5\Logs\test_ladder_compile.log"
Get-Content -Encoding Unicode "$term\MQL5\Logs\test_ladder_compile.log" | Select-String "error|Result"
```

Expected: `Result: 0 errors, 0 warnings`.

- [ ] **Step 5: Run the test and verify all cases pass**

```powershell
Get-Process terminal64 -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
$term = "C:\Users\Peter\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075"
@"
[StartUp]
Symbol=XAUUSD
Period=M1
Script=Test_LadderTracking
ShutdownTerminal=1
"@ | Set-Content -Encoding ASCII "$term\MQL5\config\run-ladder-tracking-test.ini"
Start-Process -FilePath 'C:\Program Files\MetaTrader 5\terminal64.exe' -ArgumentList "/config:$term\MQL5\config\run-ladder-tracking-test.ini" -Wait
```

```bash
TERM="/c/Users/Peter/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075"
LOGFILE=$(ls -t "$TERM/MQL5/Logs/"*.log | head -1)
iconv -f UTF-16LE -t UTF-8 "$LOGFILE" 2>/dev/null | grep "\[TEST\]" | tail -10
```

Expected: four `PASS` lines and `[TEST] RESULT=ALL_PASSED`. If any case fails, fix `ARE_TrackLadderLevel` (not the test) and repeat from Step 4.

- [ ] **Step 6: Extend `ARE_ReadBasket` to populate the new fields**

Open `C:\SAMBU\bot-are\mql5\Experts\ARE_TRADER\ARE_TRADER.mq5`. Find:

```mql5
bool ARE_ReadBasket(const string symbol,const ARE_Scores &scores,ARE_BasketSnapshot &basket)
  {
   ZeroMemory(basket);
   basket.status="NO_BASKET_INSPECTION";
   if(!InpInspectExistingBaskets)
      return true;
   double buy_value=0.0,sell_value=0.0;
   for(int i=0;i<PositionsTotal();i++)
     {
      const ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=symbol || PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber)
         continue;
      const double volume=PositionGetDouble(POSITION_VOLUME);
      const double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      const long type=PositionGetInteger(POSITION_TYPE);
      basket.exists=true;
      basket.positions++;
      basket.floating_pnl+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      double position_margin=0.0;
      const ENUM_ORDER_TYPE margin_side=(type==POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
      if(OrderCalcMargin(margin_side,symbol,volume,entry,position_margin))
         basket.margin+=position_margin;
      if(type==POSITION_TYPE_BUY) { basket.buy_volume+=volume; buy_value+=volume*entry; }
      else if(type==POSITION_TYPE_SELL) { basket.sell_volume+=volume; sell_value+=volume*entry; }
     }
   if(!basket.exists)
     { basket.status="NO_MATCHING_BASKET"; return true; }
```

Replace with:

```mql5
bool ARE_ReadBasket(const string symbol,const ARE_Scores &scores,ARE_BasketSnapshot &basket)
  {
   ZeroMemory(basket);
   basket.status="NO_BASKET_INSPECTION";
   // Inside the Tester, ladder/basket state must always be read accurately
   // regardless of InpInspectExistingBaskets - the Execution Engine (Task 2
   // onward) depends on it to avoid re-opening level 1 forever or
   // overshooting safe_depth. Outside the Tester this stays a cheap no-op
   // by default, matching the existing observation-only behavior.
   if(!InpInspectExistingBaskets && !MQLInfoInteger(MQL_TESTER))
      return true;
   double buy_value=0.0,sell_value=0.0;
   for(int i=0;i<PositionsTotal();i++)
     {
      const ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=symbol || PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber)
         continue;
      const double volume=PositionGetDouble(POSITION_VOLUME);
      const double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      const long type=PositionGetInteger(POSITION_TYPE);
      basket.exists=true;
      basket.positions++;
      basket.floating_pnl+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      double position_margin=0.0;
      const ENUM_ORDER_TYPE margin_side=(type==POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
      if(OrderCalcMargin(margin_side,symbol,volume,entry,position_margin))
         basket.margin+=position_margin;
      if(type==POSITION_TYPE_BUY) { basket.buy_volume+=volume; buy_value+=volume*entry; }
      else if(type==POSITION_TYPE_SELL) { basket.sell_volume+=volume; sell_value+=volume*entry; }
      ARE_TrackLadderLevel(basket,type==POSITION_TYPE_BUY,entry);
     }
   for(int i=0;i<OrdersTotal();i++)
     {
      const ulong ticket=OrderGetTicket(i);
      if(ticket==0 || !OrderSelect(ticket))
         continue;
      if(OrderGetString(ORDER_SYMBOL)!=symbol || OrderGetInteger(ORDER_MAGIC)!=InpMagicNumber)
         continue;
      const long type=OrderGetInteger(ORDER_TYPE);
      if(type!=ORDER_TYPE_BUY_STOP && type!=ORDER_TYPE_SELL_STOP)
         continue;
      const double price=OrderGetDouble(ORDER_PRICE_OPEN);
      basket.pending_orders++;
      ARE_TrackLadderLevel(basket,type==ORDER_TYPE_BUY_STOP,price);
     }
   if(!basket.exists)
     { basket.status="NO_MATCHING_BASKET"; return true; }
```

Leave the rest of the function (from `basket.net_volume=basket.buy_volume-basket.sell_volume;` onward) unchanged.

- [ ] **Step 7: Deploy and compile the full EA to confirm no regressions**

```bash
TERM="/c/Users/Peter/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075"
cp "/c/SAMBU/bot-are/mql5/Experts/ARE_TRADER/ARE_TRADER.mq5" "$TERM/MQL5/Experts/ARE_TRADER/"
```

```powershell
$term = "C:\Users\Peter\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075"
& 'C:\Program Files\MetaTrader 5\MetaEditor64.exe' /compile:"$term\MQL5\Experts\ARE_TRADER\ARE_TRADER.mq5" /log:"$term\MQL5\Logs\are_trader_compile_task1.log"
Get-Content -Encoding Unicode "$term\MQL5\Logs\are_trader_compile_task1.log" | Select-String "error|Result"
```

Expected: `Result: 0 errors, 0 warnings`.

- [ ] **Step 8: Copy the test script and updated sources back into the project and commit**

```bash
cp "/c/Users/Peter/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075/MQL5/Scripts/Test_LadderTracking.mq5" "/c/SAMBU/bot-are/mql5/Scripts/"
cd "C:\SAMBU\bot-are"
git add mql5/Experts/ARE_TRADER/Include/ARE_Common.mqh mql5/Experts/ARE_TRADER/ARE_TRADER.mq5 mql5/Scripts/Test_LadderTracking.mq5
git commit -m "feat(mt5): track ladder level count and furthest price in basket read

Adds pending-order scanning and a pure ARE_TrackLadderLevel helper so
ARE_ReadBasket knows how many grid levels (open + pending) already exist
for a symbol and how far the ladder currently reaches. Verified with a
dedicated script test (4 cases). Basket/ladder reading is now always
accurate inside the Tester regardless of InpInspectExistingBaskets,
since the Execution Engine (next task) depends on it."
```

---

## Task 2: Grid Plan as a decision input, and the EXPAND gate

**Files:**
- Modify: `mql5/Experts/ARE_TRADER/Include/ARE_Common.mqh` (`ARE_Assessment` struct)
- Modify: `mql5/Experts/ARE_TRADER/ARE_TRADER.mq5` (`ARE_MakeDecision`, `ARE_Assess`, `ARE_Evaluate`)

**Interfaces:**
- Consumes: `ARE_GridPlan` (existing struct, unchanged), `basket.ladder_level_count` (from Task 1).
- Produces: `ARE_Assessment.plan` (`ARE_GridPlan`) — Task 3 reads `best.plan` and `best.decision==ARE_EXPAND` to decide whether to place an order.

- [ ] **Step 1: Add `plan` to `ARE_Assessment`**

In `C:\SAMBU\bot-are\mql5\Experts\ARE_TRADER\Include\ARE_Common.mqh`, find:

```mql5
struct ARE_Assessment
  {
   string       symbol;
   ARE_SymbolSpec spec;
   ARE_Scores   scores;
   ARE_BasketSnapshot basket;
   ARE_Decision decision;
   string       reason;
  };
```

Replace with:

```mql5
struct ARE_Assessment
  {
   string       symbol;
   ARE_SymbolSpec spec;
   ARE_Scores   scores;
   ARE_BasketSnapshot basket;
   ARE_GridPlan plan;
   ARE_Decision decision;
   string       reason;
  };
```

- [ ] **Step 2: Change `ARE_MakeDecision` to take the plan and add the EXPAND branch**

In `C:\SAMBU\bot-are\mql5\Experts\ARE_TRADER\ARE_TRADER.mq5`, find:

```mql5
ARE_Decision ARE_MakeDecision(const ARE_SymbolSpec &spec,const ARE_Scores &scores,const ARE_BasketSnapshot &basket,string &reason)
  {
   if(g_risk.HardDailyStop())
     { reason="HARD_DAILY_RISK_LIMIT"; return ARE_EMERGENCY_STOP_DECISION; }
   if(InpMaxSpreadPoints>0 && (int)SymbolInfoInteger(spec.name,SYMBOL_SPREAD)>InpMaxSpreadPoints)
     { reason="MAX_SPREAD"; return ARE_FREEZE_DECISION; }
   if(scores.frozen)
     { reason="WDS_FREEZE_THRESHOLD"; return ARE_FREEZE_DECISION; }
   if(basket.exists && basket.floating_pnl<0.0)
     {
      if(basket.ree>=InpREEThreshold)
        { reason="BASKET_RECOVERABLE_PROXY"; return ARE_RESOLVE_DECISION; }
      reason="BASKET_NOT_WORTH_RECOVERING_PROXY";
      return ARE_PROTECT_DECISION;
     }
   if(scores.mrs>=InpMRSThreshold && scores.ree_proxy>=InpREEThreshold)
     { reason="MRS_AND_REE_GATE"; return ARE_WATCH_ONLY; }
   reason="NO_QUALIFYING_SETUP";
   return ARE_NO_TRADE;
  }
```

Replace with:

```mql5
ARE_Decision ARE_MakeDecision(const ARE_SymbolSpec &spec,const ARE_Scores &scores,const ARE_BasketSnapshot &basket,const ARE_GridPlan &plan,string &reason)
  {
   if(g_risk.HardDailyStop())
     { reason="HARD_DAILY_RISK_LIMIT"; return ARE_EMERGENCY_STOP_DECISION; }
   if(InpMaxSpreadPoints>0 && (int)SymbolInfoInteger(spec.name,SYMBOL_SPREAD)>InpMaxSpreadPoints)
     { reason="MAX_SPREAD"; return ARE_FREEZE_DECISION; }
   if(scores.frozen)
     { reason="WDS_FREEZE_THRESHOLD"; return ARE_FREEZE_DECISION; }
   if(basket.exists && basket.floating_pnl<0.0)
     {
      if(basket.ree>=InpREEThreshold)
        { reason="BASKET_RECOVERABLE_PROXY"; return ARE_RESOLVE_DECISION; }
      reason="BASKET_NOT_WORTH_RECOVERING_PROXY";
      return ARE_PROTECT_DECISION;
     }
   if(scores.mrs>=InpMRSThreshold && scores.ree_proxy>=InpREEThreshold)
     {
      // A basket already at drawdown was intercepted above. Reaching here
      // with basket.ladder_level_count>0 means a still-nonnegative,
      // still-under-safe-depth ladder that is allowed to keep building -
      // this is continuing the SAME opening sequence, not martingale
      // recovery (spec section 20 concerns adding exposure to recover a
      // loss, which is excluded above).
      if(plan.valid && basket.ladder_level_count<plan.safe_depth)
        { reason="MRS_REE_GATE_AND_VALID_PLAN"; return ARE_EXPAND; }
      reason="MRS_AND_REE_GATE";
      return ARE_WATCH_ONLY;
     }
   reason="NO_QUALIFYING_SETUP";
   return ARE_NO_TRADE;
  }
```

- [ ] **Step 3: Compute the plan before the decision in `ARE_Assess`**

Find:

```mql5
bool ARE_Assess(const string symbol,ARE_Assessment &assessment)
  {
   assessment.symbol=symbol;
   if(!ARE_LoadSymbolSpec(symbol,assessment.spec))
     { assessment.reason="INVALID_OR_UNAVAILABLE_SYMBOL_SPEC"; assessment.decision=ARE_NO_TRADE; return false; }
   if(!ARE_CalculateScores(symbol,assessment.spec,assessment.scores))
     { assessment.reason="INSUFFICIENT_COMPLETED_M1_BARS"; assessment.decision=ARE_NO_TRADE; return false; }
   // Computed once per symbol per cycle so Decision and Grid Plan never
   // disagree about whether this symbol is currently latched in FREEZE.
   assessment.scores.frozen=ARE_UpdateFreezeState(symbol,assessment.scores.wds,InpWDSFreezeThreshold,InpWDSUnfreezeThreshold);
   if(!ARE_ReadBasket(symbol,assessment.scores,assessment.basket))
     { assessment.reason="BASKET_READ_FAILED"; assessment.decision=ARE_PROTECT_DECISION; return false; }
   assessment.decision=ARE_MakeDecision(assessment.spec,assessment.scores,assessment.basket,assessment.reason);
   return true;
  }
```

Replace with:

```mql5
bool ARE_Assess(const string symbol,ARE_Assessment &assessment)
  {
   assessment.symbol=symbol;
   if(!ARE_LoadSymbolSpec(symbol,assessment.spec))
     { assessment.reason="INVALID_OR_UNAVAILABLE_SYMBOL_SPEC"; assessment.decision=ARE_NO_TRADE; return false; }
   if(!ARE_CalculateScores(symbol,assessment.spec,assessment.scores))
     { assessment.reason="INSUFFICIENT_COMPLETED_M1_BARS"; assessment.decision=ARE_NO_TRADE; return false; }
   // Computed once per symbol per cycle so Decision and Grid Plan never
   // disagree about whether this symbol is currently latched in FREEZE.
   assessment.scores.frozen=ARE_UpdateFreezeState(symbol,assessment.scores.wds,InpWDSFreezeThreshold,InpWDSUnfreezeThreshold);
   if(!ARE_ReadBasket(symbol,assessment.scores,assessment.basket))
     { assessment.reason="BASKET_READ_FAILED"; assessment.decision=ARE_PROTECT_DECISION; return false; }
   // Computed before the decision (not after, as before this task) so
   // EXPAND can be gated on plan validity and remaining ladder depth.
   ARE_MakeGridPlan(assessment.spec,assessment.scores,assessment.basket,assessment.plan);
   assessment.decision=ARE_MakeDecision(assessment.spec,assessment.scores,assessment.basket,assessment.plan,assessment.reason);
   return true;
  }
```

- [ ] **Step 4: Remove the redundant post-loop plan computation in `ARE_Evaluate` and add the EXPANSION state**

Find:

```mql5
   if(best.decision==ARE_EMERGENCY_STOP_DECISION) g_state=ARE_EMERGENCY_STOP;
   else if(best.decision==ARE_FREEZE_DECISION) g_state=ARE_FREEZE;
   else if(best.decision==ARE_RESOLVE_DECISION) g_state=ARE_RECOVERY_ANALYSIS;
   else if(best.decision==ARE_PROTECT_DECISION) g_state=ARE_PROTECT;
   else if(best.decision==ARE_WATCH_ONLY) g_state=ARE_WATCH;
   else g_state=ARE_IDLE;
   ARE_GridPlan plan;
   ARE_MakeGridPlan(best.spec,best.scores,best.basket,plan);
   if(InpDebugLog)
      PrintFormat("[ARE] GridPlan Symbol=%s Valid=%s Depth=%d RiskCapacity=%d MarginCapacity=%d VolatilityCapacity=%d Volume=%.8f Distance=%.8f Reason=%s",
                  best.symbol,(plan.valid ? "true" : "false"),plan.safe_depth,plan.risk_capacity,plan.margin_capacity,plan.volatility_capacity,plan.volume,plan.grid_distance,plan.reason);
   ARE_RenderPanel(best,plan);
  }
```

Replace with:

```mql5
   if(best.decision==ARE_EMERGENCY_STOP_DECISION) g_state=ARE_EMERGENCY_STOP;
   else if(best.decision==ARE_FREEZE_DECISION) g_state=ARE_FREEZE;
   else if(best.decision==ARE_RESOLVE_DECISION) g_state=ARE_RECOVERY_ANALYSIS;
   else if(best.decision==ARE_PROTECT_DECISION) g_state=ARE_PROTECT;
   else if(best.decision==ARE_EXPAND) g_state=ARE_EXPANSION;
   else if(best.decision==ARE_WATCH_ONLY) g_state=ARE_WATCH;
   else g_state=ARE_IDLE;
   if(InpDebugLog)
      PrintFormat("[ARE] GridPlan Symbol=%s Valid=%s Depth=%d RiskCapacity=%d MarginCapacity=%d VolatilityCapacity=%d Volume=%.8f Distance=%.8f Reason=%s",
                  best.symbol,(best.plan.valid ? "true" : "false"),best.plan.safe_depth,best.plan.risk_capacity,best.plan.margin_capacity,best.plan.volatility_capacity,best.plan.volume,best.plan.grid_distance,best.plan.reason);
   ARE_RenderPanel(best,best.plan);
  }
```

- [ ] **Step 5: Deploy and compile**

```bash
TERM="/c/Users/Peter/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075"
cp "/c/SAMBU/bot-are/mql5/Experts/ARE_TRADER/Include/ARE_Common.mqh" "$TERM/MQL5/Experts/ARE_TRADER/Include/"
cp "/c/SAMBU/bot-are/mql5/Experts/ARE_TRADER/ARE_TRADER.mq5" "$TERM/MQL5/Experts/ARE_TRADER/"
```

```powershell
$term = "C:\Users\Peter\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075"
& 'C:\Program Files\MetaTrader 5\MetaEditor64.exe' /compile:"$term\MQL5\Experts\ARE_TRADER\ARE_TRADER.mq5" /log:"$term\MQL5\Logs\are_trader_compile_task2.log"
Get-Content -Encoding Unicode "$term\MQL5\Logs\are_trader_compile_task2.log" | Select-String "error|Result"
```

Expected: `Result: 0 errors, 0 warnings`.

- [ ] **Step 6: Verify EXPAND is now reachable, with a real backtest (still zero orders — Task 3 wires execution)**

Reuse the tester config pattern from the earlier Freeze/Unfreeze validation. Create `MQL5\config\are-trader-xauusd-jan2026-task2.ini` in the terminal:

```ini
[Tester]
Expert=ARE_TRADER\ARE_TRADER.ex5
Symbol=XAUUSD
Period=M1
Model=4
Optimization=0
Dates=1
FromDate=2026.01.01
ToDate=2026.01.31
ForwardMode=0
Deposit=100000
Currency=USD
Leverage=1:100
ExecutionMode=0
Visual=0
Report=MQL5\backtest\reports\are_trader_xauusd_jan2026_task2
ReplaceReport=1
ShutdownTerminal=1
UseLocal=1
UseRemote=0
UseCloud=0

[TesterInputs]
InpOperatingMode=0||0||0||2||N
InpSingleSymbol=XAUUSD
InpPoolSymbol1=XAUUSD
InpPoolSymbol2=GBPJPY
InpPoolSymbol3=USDJPY
InpFeatureWindow=20||20||1||200||N
InpBaselineWindow=120||120||1||1200||N
InpDailyRiskPercent=1.0||1.0||0.100000||10.000000||N
InpExpansionPercent=50.0||50.0||5.000000||500.000000||N
InpResolutionPercent=25.0||25.0||2.500000||250.000000||N
InpEmergencyPercent=25.0||25.0||2.500000||250.000000||N
InpMRSThreshold=55.0||55.0||5.500000||550.000000||N
InpWDSFreezeThreshold=70.0||70.0||7.000000||700.000000||N
InpWDSUnfreezeThreshold=45.0||45.0||4.500000||450.000000||N
InpREEThreshold=55.0||55.0||5.500000||550.000000||N
InpMaxSpreadPoints=0||0||1||10||N
InpMaxGridDepth=30||30||1||300||N
InpMinGridDistanceTicks=10||10||1||100||N
InpMaxGridDistanceTicks=2000||2000||1||20000||N
InpATRMultiplier=1.5||1.5||0.150000||15.000000||N
InpSpreadMultiplier=3.0||3.0||0.300000||30.000000||N
InpStressDistanceATR=2.0||2.0||0.200000||20.000000||N
InpMinFreeMarginReservePercent=70.0||70.0||7.000000||700.000000||N
InpInspectExistingBaskets=false||false||0||true||N
InpEnableExecution=false||false||0||true||N
InpDebugLog=true||true||0||true||N
```

```powershell
Get-Process terminal64 -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
$term = "C:\Users\Peter\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075"
Start-Process -FilePath 'C:\Program Files\MetaTrader 5\terminal64.exe' -ArgumentList "/config:$term\MQL5\config\are-trader-xauusd-jan2026-task2.ini" -Wait
```

```bash
TERM="/c/Users/Peter/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075"
iconv -f UTF-16LE -t UTF-8 "$TERM/Tester/logs/"*.log 2>/dev/null | grep -oP 'Decision=\K\S+' | sort | uniq -c
```

Expected: `EXPAND` now appears in the tally alongside `NO_TRADE`/`WATCH`/`FREEZE`. `InpEnableExecution=false` in this config on purpose — this step only confirms the decision reaches EXPAND, not that an order is sent.

- [ ] **Step 7: Commit**

```bash
cd "C:\SAMBU\bot-are"
git add mql5/Experts/ARE_TRADER/Include/ARE_Common.mqh mql5/Experts/ARE_TRADER/ARE_TRADER.mq5
git commit -m "feat(mt5): compute Grid Plan before the decision and add EXPAND

ARE_MakeGridPlan now runs inside ARE_Assess before ARE_MakeDecision
(previously only computed after, for the already-chosen best symbol).
WATCH_ONLY is promoted to EXPAND when the plan is valid and the ladder
still has room under safe_depth. No order is sent yet - verified via a
real Strategy Tester run over XAUUSD/January 2026 that EXPAND now
appears in the decision tally with InpEnableExecution left at false."
```

---

## Task 3: Send the order (CTrade, Tester-only)

**Files:**
- Modify: `mql5/Experts/ARE_TRADER/Include/ARE_Common.mqh` (add `ARE_NextLadderLevel`)
- Modify: `mql5/Experts/ARE_TRADER/ARE_TRADER.mq5` (add `#include <Trade\Trade.mqh>`, `CTrade g_trade`, `ARE_PlaceNextGridLevel`, wire into `ARE_Evaluate`, update panel text)
- Create: `mql5/Scripts/Test_GridPricing.mq5`

**Interfaces:**
- Consumes: `ARE_Scores.direction`, `ARE_Scores.last_close` (existing fields), `ARE_GridPlan.grid_distance`/`.safe_depth`/`.volume` (existing fields), `ARE_BasketSnapshot.ladder_level_count`/`.furthest_level_price`/`.ladder_is_buy_side` (Task 1).
- Produces: `ARE_NextLadderLevel(const ARE_Scores &scores, const ARE_BasketSnapshot &basket, const ARE_GridPlan &plan, ENUM_ORDER_TYPE &order_type, double &price) -> bool` (pure). `ARE_PlaceNextGridLevel(const ARE_SymbolSpec &spec, const ARE_Scores &scores, const ARE_BasketSnapshot &basket, const ARE_GridPlan &plan, string &result_reason) -> bool` (side-effecting, lives in the .mq5).

- [ ] **Step 1: Write the failing test for the pure pricing logic**

Create `C:\SAMBU\bot-are\mql5\Scripts\Test_GridPricing.mq5`:

```mql5
#property strict

#include "..\Experts\ARE_TRADER\Include\ARE_Common.mqh"

void OnStart(void)
  {
   bool all_passed=true;
   ARE_Scores scores;
   ZeroMemory(scores);
   scores.last_close=4300.0;
   scores.direction=1.0;

   ARE_GridPlan plan;
   ZeroMemory(plan);
   plan.safe_depth=3;
   plan.grid_distance=5.0;

   ARE_BasketSnapshot basket;
   ZeroMemory(basket);

   ENUM_ORDER_TYPE order_type;
   double price;

   bool got1=ARE_NextLadderLevel(scores,basket,plan,order_type,price);
   bool ok1=(got1 && order_type==ORDER_TYPE_BUY_STOP && price==4305.0);
   PrintFormat("[TEST] case=1 %s -- first level is BUY STOP at close+distance",(ok1?"PASS":"FAIL"));
   all_passed=all_passed && ok1;

   ARE_TrackLadderLevel(basket,true,4305.0);
   bool got2=ARE_NextLadderLevel(scores,basket,plan,order_type,price);
   bool ok2=(got2 && order_type==ORDER_TYPE_BUY_STOP && price==4310.0);
   PrintFormat("[TEST] case=2 %s -- second level stacks distance above furthest",(ok2?"PASS":"FAIL"));
   all_passed=all_passed && ok2;

   ARE_TrackLadderLevel(basket,true,4310.0);
   ARE_TrackLadderLevel(basket,true,4315.0);
   bool got3=ARE_NextLadderLevel(scores,basket,plan,order_type,price);
   bool ok3=(got3==false);
   PrintFormat("[TEST] case=3 %s -- refuses a new level once safe_depth is reached",(ok3?"PASS":"FAIL"));
   all_passed=all_passed && ok3;

   ARE_BasketSnapshot empty_basket;
   ZeroMemory(empty_basket);
   scores.direction=-1.0;
   bool got4=ARE_NextLadderLevel(scores,empty_basket,plan,order_type,price);
   bool ok4=(got4 && order_type==ORDER_TYPE_SELL_STOP && price==4295.0);
   PrintFormat("[TEST] case=4 %s -- downtrend places SELL STOP below close",(ok4?"PASS":"FAIL"));
   all_passed=all_passed && ok4;

   PrintFormat("[TEST] RESULT=%s",(all_passed?"ALL_PASSED":"FAILURES_PRESENT"));
  }
```

- [ ] **Step 2: Deploy the test only and confirm it fails to compile**

```bash
TERM="/c/Users/Peter/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075"
cp "/c/SAMBU/bot-are/mql5/Scripts/Test_GridPricing.mq5" "$TERM/MQL5/Scripts/"
```

```powershell
$term = "C:\Users\Peter\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075"
& 'C:\Program Files\MetaTrader 5\MetaEditor64.exe' /compile:"$term\MQL5\Scripts\Test_GridPricing.mq5" /log:"$term\MQL5\Logs\test_pricing_compile.log"
Get-Content -Encoding Unicode "$term\MQL5\Logs\test_pricing_compile.log" | Select-String "error|Result"
```

Expected: undeclared-identifier error for `ARE_NextLadderLevel`.

- [ ] **Step 3: Add `ARE_NextLadderLevel` to `ARE_Common.mqh`**

Open `C:\SAMBU\bot-are\mql5\Experts\ARE_TRADER\Include\ARE_Common.mqh`. Add this function directly after `ARE_TrackLadderLevel` (added in Task 1):

```mql5
// Pure: given the current ladder state, returns the direction and price of
// the next level to place, or false if safe_depth is already reached. No
// MT5 order/account API calls - the side-effecting order send lives in
// ARE_TRADER.mq5's ARE_PlaceNextGridLevel, which calls this first.
bool ARE_NextLadderLevel(const ARE_Scores &scores,const ARE_BasketSnapshot &basket,const ARE_GridPlan &plan,ENUM_ORDER_TYPE &order_type,double &price)
  {
   if(basket.ladder_level_count>=plan.safe_depth)
      return false;
   if(basket.ladder_level_count==0)
     {
      order_type=(scores.direction>=0.0 ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP);
      price=(scores.direction>=0.0 ? scores.last_close+plan.grid_distance : scores.last_close-plan.grid_distance);
      return true;
     }
   order_type=(basket.ladder_is_buy_side ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP);
   price=(basket.ladder_is_buy_side ? basket.furthest_level_price+plan.grid_distance : basket.furthest_level_price-plan.grid_distance);
   return true;
  }
```

- [ ] **Step 4: Deploy, recompile, and run the pricing test**

```bash
TERM="/c/Users/Peter/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075"
cp "/c/SAMBU/bot-are/mql5/Experts/ARE_TRADER/Include/ARE_Common.mqh" "$TERM/MQL5/Experts/ARE_TRADER/Include/"
```

```powershell
$term = "C:\Users\Peter\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075"
& 'C:\Program Files\MetaTrader 5\MetaEditor64.exe' /compile:"$term\MQL5\Scripts\Test_GridPricing.mq5" /log:"$term\MQL5\Logs\test_pricing_compile.log"
Get-Content -Encoding Unicode "$term\MQL5\Logs\test_pricing_compile.log" | Select-String "error|Result"
Get-Process terminal64 -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
@"
[StartUp]
Symbol=XAUUSD
Period=M1
Script=Test_GridPricing
ShutdownTerminal=1
"@ | Set-Content -Encoding ASCII "$term\MQL5\config\run-grid-pricing-test.ini"
Start-Process -FilePath 'C:\Program Files\MetaTrader 5\terminal64.exe' -ArgumentList "/config:$term\MQL5\config\run-grid-pricing-test.ini" -Wait
```

```bash
TERM="/c/Users/Peter/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075"
LOGFILE=$(ls -t "$TERM/MQL5/Logs/"*.log | head -1)
iconv -f UTF-16LE -t UTF-8 "$LOGFILE" 2>/dev/null | grep "\[TEST\]" | tail -10
```

Expected: `Result: 0 errors, 0 warnings` on compile, and all four `[TEST]` cases `PASS` with `RESULT=ALL_PASSED`. If a case fails, fix `ARE_NextLadderLevel` and repeat from the compile sub-step.

- [ ] **Step 5: Add `CTrade` and `ARE_PlaceNextGridLevel` to `ARE_TRADER.mq5`**

Open `C:\SAMBU\bot-are\mql5\Experts\ARE_TRADER\ARE_TRADER.mq5`. Find:

```mql5
#include "Include/ARE_Common.mqh"
```

Replace with:

```mql5
#include "Include/ARE_Common.mqh"
#include <Trade\Trade.mqh>
```

Find:

```mql5
ARE_State g_state=ARE_IDLE;
```

Replace with:

```mql5
ARE_State g_state=ARE_IDLE;
CTrade    g_trade;
```

Find the closing brace of `ARE_MakeGridPlan` (the function ending in `plan.reason="OBSERVATION_ONLY_PLAN"; return true; }`) and insert this new function immediately after it, before `ARE_Decision ARE_MakeDecision(...)`:

```mql5
// Side-effecting: sends the next ladder level via CTrade. Execution is
// double-gated (input + Tester-only) so attaching this EA to any live or
// demo chart never sends an order, regardless of input values.
bool ARE_PlaceNextGridLevel(const ARE_SymbolSpec &spec,const ARE_Scores &scores,const ARE_BasketSnapshot &basket,const ARE_GridPlan &plan,string &result_reason)
  {
   if(!InpEnableExecution)
     { result_reason="EXECUTION_DISABLED_BY_INPUT"; return false; }
   if(!MQLInfoInteger(MQL_TESTER))
     { result_reason="EXECUTION_BLOCKED_OUTSIDE_TESTER"; return false; }
   ENUM_ORDER_TYPE order_type;
   double price;
   if(!ARE_NextLadderLevel(scores,basket,plan,order_type,price))
     { result_reason="SAFE_DEPTH_REACHED"; return false; }
   price=NormalizeDouble(price,(int)SymbolInfoInteger(spec.name,SYMBOL_DIGITS));
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   const bool sent=(order_type==ORDER_TYPE_BUY_STOP ?
                     g_trade.BuyStop(plan.volume,price,spec.name) :
                     g_trade.SellStop(plan.volume,price,spec.name));
   if(!sent)
     {
      result_reason=StringFormat("ORDER_SEND_FAILED_%d_%s",g_trade.ResultRetcode(),g_trade.ResultRetcodeDescription());
      return false;
     }
   result_reason="LEVEL_PLACED";
   return true;
  }
```

- [ ] **Step 6: Wire it into `ARE_Evaluate` and update the panel's execution line**

Find (this is the block Task 2 last modified):

```mql5
   if(InpDebugLog)
      PrintFormat("[ARE] GridPlan Symbol=%s Valid=%s Depth=%d RiskCapacity=%d MarginCapacity=%d VolatilityCapacity=%d Volume=%.8f Distance=%.8f Reason=%s",
                  best.symbol,(best.plan.valid ? "true" : "false"),best.plan.safe_depth,best.plan.risk_capacity,best.plan.margin_capacity,best.plan.volatility_capacity,best.plan.volume,best.plan.grid_distance,best.plan.reason);
   ARE_RenderPanel(best,best.plan);
  }
```

Replace with:

```mql5
   if(InpDebugLog)
      PrintFormat("[ARE] GridPlan Symbol=%s Valid=%s Depth=%d RiskCapacity=%d MarginCapacity=%d VolatilityCapacity=%d Volume=%.8f Distance=%.8f Reason=%s",
                  best.symbol,(best.plan.valid ? "true" : "false"),best.plan.safe_depth,best.plan.risk_capacity,best.plan.margin_capacity,best.plan.volatility_capacity,best.plan.volume,best.plan.grid_distance,best.plan.reason);
   if(best.decision==ARE_EXPAND)
     {
      string exec_reason;
      const bool placed=ARE_PlaceNextGridLevel(best.spec,best.scores,best.basket,best.plan,exec_reason);
      if(InpDebugLog)
         PrintFormat("[ARE] Execution Symbol=%s Placed=%s Reason=%s",best.symbol,(placed?"true":"false"),exec_reason);
     }
   ARE_RenderPanel(best,best.plan);
  }
```

Find, inside `ARE_RenderPanel`:

```mql5
           "Execution: ",(InpEnableExecution ? "NOT IMPLEMENTED - BLOCKED" : "OBSERVATION ONLY"));
```

Replace with:

```mql5
           "Execution: ",(InpEnableExecution && MQLInfoInteger(MQL_TESTER) ? "ENABLED (TESTER)" : (InpEnableExecution ? "BLOCKED (NOT IN TESTER)" : "DISABLED BY INPUT")));
```

- [ ] **Step 7: Deploy and compile the full EA**

```bash
TERM="/c/Users/Peter/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075"
cp "/c/SAMBU/bot-are/mql5/Experts/ARE_TRADER/ARE_TRADER.mq5" "$TERM/MQL5/Experts/ARE_TRADER/"
```

```powershell
$term = "C:\Users\Peter\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075"
& 'C:\Program Files\MetaTrader 5\MetaEditor64.exe' /compile:"$term\MQL5\Experts\ARE_TRADER\ARE_TRADER.mq5" /log:"$term\MQL5\Logs\are_trader_compile_task3.log"
Get-Content -Encoding Unicode "$term\MQL5\Logs\are_trader_compile_task3.log" | Select-String "error|Result"
```

Expected: `Result: 0 errors, 0 warnings`.

- [ ] **Step 8: Copy test scripts and sources back into the project, commit**

```bash
cp "/c/Users/Peter/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075/MQL5/Scripts/Test_GridPricing.mq5" "/c/SAMBU/bot-are/mql5/Scripts/"
cd "C:\SAMBU\bot-are"
git add mql5/Experts/ARE_TRADER/Include/ARE_Common.mqh mql5/Experts/ARE_TRADER/ARE_TRADER.mq5 mql5/Scripts/Test_GridPricing.mq5
git commit -m "feat(mt5): place the initial Grid ladder via CTrade, Tester-only

ARE_NextLadderLevel (pure, unit-tested with 4 cases) computes the next
level's direction and price from the current ladder state. Wired into
ARE_Evaluate as ARE_PlaceNextGridLevel, gated on InpEnableExecution AND
MQLInfoInteger(MQL_TESTER) so attaching the EA to any live/demo chart
still never sends an order. One order per evaluation cycle, capped at
the Grid Plan's safe_depth."
```

---

## Task 4: Real backtest validation and report

**Files:**
- Create: `mql5/Experts/ARE_TRADER/backtests/xauusd_jan2026_execution_REPORT.md`
- Create: `mql5/Experts/ARE_TRADER/backtests/xauusd_jan2026_execution_minute_log.csv`

**Interfaces:**
- Consumes: the compiled `ARE_TRADER.ex5` from Task 3 (execution-capable, Tester-only).

- [ ] **Step 1: Run the XAUUSD/January 2026 backtest with execution enabled**

Create `MQL5\config\are-trader-xauusd-jan2026-execution.ini` in the terminal — same as Task 2's `[TesterInputs]` block, but with `InpEnableExecution=true||true||0||true||N` and `Report=MQL5\backtest\reports\are_trader_xauusd_jan2026_execution`:

```ini
[Tester]
Expert=ARE_TRADER\ARE_TRADER.ex5
Symbol=XAUUSD
Period=M1
Model=4
Optimization=0
Dates=1
FromDate=2026.01.01
ToDate=2026.01.31
ForwardMode=0
Deposit=100000
Currency=USD
Leverage=1:100
ExecutionMode=0
Visual=0
Report=MQL5\backtest\reports\are_trader_xauusd_jan2026_execution
ReplaceReport=1
ShutdownTerminal=1
UseLocal=1
UseRemote=0
UseCloud=0

[TesterInputs]
InpOperatingMode=0||0||0||2||N
InpSingleSymbol=XAUUSD
InpPoolSymbol1=XAUUSD
InpPoolSymbol2=GBPJPY
InpPoolSymbol3=USDJPY
InpFeatureWindow=20||20||1||200||N
InpBaselineWindow=120||120||1||1200||N
InpDailyRiskPercent=1.0||1.0||0.100000||10.000000||N
InpExpansionPercent=50.0||50.0||5.000000||500.000000||N
InpResolutionPercent=25.0||25.0||2.500000||250.000000||N
InpEmergencyPercent=25.0||25.0||2.500000||250.000000||N
InpMRSThreshold=55.0||55.0||5.500000||550.000000||N
InpWDSFreezeThreshold=70.0||70.0||7.000000||700.000000||N
InpWDSUnfreezeThreshold=45.0||45.0||4.500000||450.000000||N
InpREEThreshold=55.0||55.0||5.500000||550.000000||N
InpMaxSpreadPoints=0||0||1||10||N
InpMaxGridDepth=30||30||1||300||N
InpMinGridDistanceTicks=10||10||1||100||N
InpMaxGridDistanceTicks=2000||2000||1||20000||N
InpATRMultiplier=1.5||1.5||0.150000||15.000000||N
InpSpreadMultiplier=3.0||3.0||0.300000||30.000000||N
InpStressDistanceATR=2.0||2.0||0.200000||20.000000||N
InpMinFreeMarginReservePercent=70.0||70.0||7.000000||700.000000||N
InpInspectExistingBaskets=false||false||0||true||N
InpEnableExecution=true||true||0||true||N
InpDebugLog=true||true||0||true||N
```

```powershell
Get-Process terminal64 -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
$term = "C:\Users\Peter\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075"
Start-Process -FilePath 'C:\Program Files\MetaTrader 5\terminal64.exe' -ArgumentList "/config:$term\MQL5\config\are-trader-xauusd-jan2026-execution.ini" -Wait
```

- [ ] **Step 2: Confirm the tester report is no longer pinned at zero**

```bash
TERM="/c/Users/Peter/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075"
iconv -f UTF-16LE -t UTF-8 "$TERM/MQL5/backtest/reports/are_trader_xauusd_jan2026_execution.htm" 2>/dev/null | sed 's/<[^>]*>/ /g' | tr -s ' \n' ' \n' | grep -A1 -E "Beneficio Neto|Operaciones totales|Reducción máxima del balance"
```

Expected: at least one non-zero trade count. If it is still all zeros, check `$TERM/Tester/logs/` for `[ARE] Execution` lines and their `Reason=` values before concluding the feature is broken — `SAFE_DEPTH_REACHED` or `NO_SAFE_GRID_DEPTH` this early in the month would indicate a calibration issue, not a code bug (see the spec's "Observations for later calibration" section).

- [ ] **Step 3: Extract decision/execution tallies and the per-minute CSV, same method as the Freeze/Unfreeze validation**

```bash
TERM="/c/Users/Peter/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075"
iconv -f UTF-16LE -t UTF-8 "$TERM/Tester/logs/"*.log 2>/dev/null > /tmp/task4_tester_full.log
grep "\[ARE\] Symbol=" /tmp/task4_tester_full.log > /tmp/task4_are_symbol_lines.log
grep "\[ARE\] Execution" /tmp/task4_tester_full.log > /tmp/task4_are_execution_lines.log
echo "=== Decision tally ==="
grep -oP 'Decision=\K\S+' /tmp/task4_are_symbol_lines.log | sort | uniq -c
echo "=== Execution outcome tally ==="
grep -oP 'Placed=\K\S+' /tmp/task4_are_execution_lines.log | sort | uniq -c
echo "=== Execution reason tally ==="
grep -oP 'Reason=\K\S+' /tmp/task4_are_execution_lines.log | sort | uniq -c | sort -rn
```

Convert the per-minute assessment lines to CSV. Native Windows Python cannot read `/tmp` paths, so copy the log into the scratchpad directory first (substitute the current session's actual scratchpad path if different from below):

```bash
SCRATCH="/c/Users/Peter/AppData/Local/Temp/claude/C--SAMBU-bot-are/ac889909-645b-40f0-a516-52caa1395eba/scratchpad"
mkdir -p "$SCRATCH"
cp /tmp/task4_are_symbol_lines.log "$SCRATCH/task4_are_symbol_lines.log"
```

```bash
PY="/c/Users/Peter/AppData/Local/Programs/Python/Python312/python.exe"
SCRATCH_WIN="C:\Users\Peter\AppData\Local\Temp\claude\C--SAMBU-bot-are\ac889909-645b-40f0-a516-52caa1395eba\scratchpad"
"$PY" - "$SCRATCH_WIN" <<'PYEOF'
import re, csv, sys
from pathlib import Path

scratch = Path(sys.argv[1])
pattern = re.compile(
    r"(?P<ts>\d{4}\.\d{2}\.\d{2} \d{2}:\d{2}:\d{2})\s+\[ARE\] Symbol=(?P<symbol>\S+) State=(?P<state>\S+) "
    r"MRS=(?P<mrs>\S+) WDS=(?P<wds>\S+) Frozen=(?P<frozen>\S+) REE=(?P<ree>\S+) AssetScore=(?P<asset_score>\S+) "
    r"BasketPositions=\S+ BasketPnL=\S+ BasketREE=\S+ Equity=(?P<equity>\S+) DailyPnL=(?P<daily_pnl>\S+) "
    r"DailyBudget=\S+ Decision=(?P<decision>\S+) Reason=(?P<reason>\S+)"
)

rows = []
with open(scratch / "task4_are_symbol_lines.log", encoding="utf-8", errors="replace") as f:
    for line in f:
        m = pattern.search(line)
        if m:
            rows.append(m.groupdict())

out_path = r"C:\SAMBU\bot-are\mql5\Experts\ARE_TRADER\backtests\xauusd_jan2026_execution_minute_log.csv"
fields = ["ts","symbol","state","mrs","wds","frozen","ree","asset_score","equity","daily_pnl","decision","reason"]
with open(out_path, "w", newline="", encoding="utf-8") as f:
    w = csv.DictWriter(f, fieldnames=fields)
    w.writeheader()
    w.writerows(rows)

print("rows parsed:", len(rows))
PYEOF
```

This produces `C:\SAMBU\bot-are\mql5\Experts\ARE_TRADER\backtests\xauusd_jan2026_execution_minute_log.csv` with the same column set as the earlier Freeze/Unfreeze validation's `xauusd_jan2026_single_asset_minute_log.csv`, so the two runs stay directly comparable.

- [ ] **Step 4: Write the report**

Create `C:\SAMBU\bot-are\mql5\Experts\ARE_TRADER\backtests\xauusd_jan2026_execution_REPORT.md`, following the structure of `xauusd_jan2026_single_asset_minute_log`'s sibling `REPORT.md` (Scope / Results / Consistency checks / Observations for later calibration / Explicit limits). Include:
- The decision and execution-outcome tallies from Step 3.
- Whatever real trade count, net profit, and max drawdown the `.htm` report now shows (Step 2) — report the actual numbers, do not round them into a qualitative claim ("profitable" / "unprofitable") since this is one uncalibrated parameter set, not a validated strategy (spec section 58, master spec section 58).
- An explicit note that RESOLVE/PROTECT decisions still do not execute anything yet (out of scope, per the design's Non-goals) — if the backtest hits a drawdown, the basket is simply left open with no code acting on it further, which itself needs to be called out plainly, not glossed over.

- [ ] **Step 5: Commit**

```bash
cd "C:\SAMBU\bot-are"
git add mql5/Experts/ARE_TRADER/backtests/xauusd_jan2026_execution_REPORT.md mql5/Experts/ARE_TRADER/backtests/xauusd_jan2026_execution_minute_log.csv
git commit -m "docs(mt5): validate initial Grid execution on XAUUSD Jan 2026

Real Strategy Tester run with InpEnableExecution=true confirms the EA
now places real (Tester-only) orders and the report is no longer pinned
at zero. Numbers reported as-is, not framed as a profitability result -
this is one uncalibrated parameter set on one month of data."
```

- [ ] **Step 6: Push**

```bash
cd "C:\SAMBU\bot-are" && git push origin main
```
