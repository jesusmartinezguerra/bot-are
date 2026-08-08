#property strict
#property version   "1.000"
#property description "Adaptive Regime Engine - safety-gated MT5 observation foundation"

#include "Include/ARE_Common.mqh"

input ARE_OperatingMode InpOperatingMode       = ARE_ASSET_POOL;
input string             InpSingleSymbol        = "XAUUSD";
input string             InpPoolSymbol1         = "XAUUSD";
input string             InpPoolSymbol2         = "GBPJPY";
input string             InpPoolSymbol3         = "USDJPY";
input int                InpFeatureWindow       = 20;
input int                InpBaselineWindow      = 120;
input double             InpDailyRiskPercent    = 1.0;
input double             InpExpansionPercent    = 50.0;
input double             InpResolutionPercent   = 25.0;
input double             InpEmergencyPercent    = 25.0;
input double             InpMRSThreshold        = 55.0;
input double             InpWDSFreezeThreshold  = 70.0;
input double             InpWDSUnfreezeThreshold= 45.0;
input double             InpREEThreshold        = 55.0;
input int                InpMaxSpreadPoints     = 0;       // 0 means dynamic baseline only
input int                InpMaxGridDepth        = 30;
input int                InpMinGridDistanceTicks= 10;
input int                InpMaxGridDistanceTicks= 2000;
input double             InpATRMultiplier       = 1.50;
input double             InpSpreadMultiplier    = 3.00;
input double             InpStressDistanceATR   = 2.00;
input double             InpMinFreeMarginReservePercent = 70.0; // percent of equity retained as free margin
input bool               InpInspectExistingBaskets = false;
input long               InpMagicNumber           = 2600101;
input bool               InpEnableExecution     = false;   // deliberately false by default
input bool               InpDebugLog             = true;

ARE_State g_state=ARE_IDLE;

class CARE_RiskEngine
  {
private:
   double m_daily_budget;
   double m_expansion_budget;
   double m_resolution_budget;
   double m_emergency_budget;

public:
   bool Configure(void)
     {
      if(InpDailyRiskPercent<=0.0 || InpExpansionPercent<0.0 || InpResolutionPercent<0.0 || InpEmergencyPercent<0.0)
         return false;
      const double total=InpExpansionPercent+InpResolutionPercent+InpEmergencyPercent;
      if(MathAbs(total-100.0)>0.0001)
         return false;
      const double equity=AccountInfoDouble(ACCOUNT_EQUITY);
      m_daily_budget=equity*InpDailyRiskPercent/100.0;
      m_expansion_budget=m_daily_budget*InpExpansionPercent/100.0;
      m_resolution_budget=m_daily_budget*InpResolutionPercent/100.0;
      m_emergency_budget=m_daily_budget*InpEmergencyPercent/100.0;
      return (m_daily_budget>0.0);
     }

   datetime DayStart(void) const
     {
      MqlDateTime day;
      TimeToStruct(TimeCurrent(),day);
      day.hour=0; day.min=0; day.sec=0;
      return StructToTime(day);
     }

   double ClosedDailyPnL(void) const
     {
      if(!HistorySelect(DayStart(),TimeCurrent()))
         return 0.0;
      double pnl=0.0;
      const int count=HistoryDealsTotal();
      for(int i=0;i<count;i++)
        {
         const ulong ticket=HistoryDealGetTicket(i);
         if(ticket==0)
            continue;
         const long entry=HistoryDealGetInteger(ticket,DEAL_ENTRY);
         if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_OUT_BY)
            continue;
         pnl+=HistoryDealGetDouble(ticket,DEAL_PROFIT);
         pnl+=HistoryDealGetDouble(ticket,DEAL_SWAP);
         pnl+=HistoryDealGetDouble(ticket,DEAL_COMMISSION);
        }
      return pnl;
     }

   bool HardDailyStop(void) const { return ClosedDailyPnL()<=-m_daily_budget; }
   double DailyBudget(void) const { return m_daily_budget; }
   double ExpansionBudget(void) const { return m_expansion_budget; }
   double ResolutionBudget(void) const { return m_resolution_budget; }
   double EmergencyBudget(void) const { return m_emergency_budget; }
  };

CARE_RiskEngine g_risk;

bool ARE_LoadSymbolSpec(const string symbol,ARE_SymbolSpec &spec)
  {
   spec.name=symbol;
   if(!SymbolSelect(symbol,true))
     {
      spec.valid=false;
      return false;
     }
   spec.point=SymbolInfoDouble(symbol,SYMBOL_POINT);
   spec.tick_size=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE);
   spec.tick_value=SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE);
   spec.contract_size=SymbolInfoDouble(symbol,SYMBOL_TRADE_CONTRACT_SIZE);
   spec.volume_min=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
   spec.volume_max=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
   spec.volume_step=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
   spec.margin_initial=SymbolInfoDouble(symbol,SYMBOL_MARGIN_INITIAL);
   spec.stops_level=(int)SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL);
   spec.freeze_level=(int)SymbolInfoInteger(symbol,SYMBOL_TRADE_FREEZE_LEVEL);
   spec.valid=(spec.point>0.0 && spec.tick_size>0.0 && spec.tick_value>0.0 &&
               spec.volume_min>0.0 && spec.volume_step>0.0);
   return spec.valid;
  }

double ARE_NormalizeVolume(const ARE_SymbolSpec &spec,const double requested)
  {
   if(!spec.valid || requested<spec.volume_min)
      return 0.0;
   const double bounded=MathMin(requested,spec.volume_max);
   const double steps=MathFloor((bounded-spec.volume_min)/spec.volume_step+0.0000001);
   const double volume=spec.volume_min+steps*spec.volume_step;
   return NormalizeDouble(volume,8);
  }

bool ARE_CalculateScores(const string symbol,const ARE_SymbolSpec &spec,ARE_Scores &scores)
  {
   ZeroMemory(scores);
   const int need=MathMax(InpBaselineWindow,InpFeatureWindow)+1;
   MqlRates bars[];
   ArraySetAsSeries(bars,false);
   // Shift 1 excludes the unclosed bar, preventing look-ahead from the active minute.
   const int copied=CopyRates(symbol,PERIOD_M1,1,need,bars);
   if(copied<need)
      return false;

   const int start=copied-InpFeatureWindow;
   double abs_path=0.0,range_recent=0.0,range_baseline=0.0,atr_sum=0.0;
   double spread_recent=0.0,spread_baseline=0.0,activity_recent=0.0,activity_baseline=0.0;
   int reversals=0,previous_sign=0,nonzero=0;
   for(int i=1;i<copied;i++)
     {
      const double change=bars[i].close-bars[i-1].close;
      if(i>=start)
        {
         abs_path+=MathAbs(change);
         const int sign=(change>0.0 ? 1 : (change<0.0 ? -1 : 0));
         if(sign!=0)
           {
            if(previous_sign!=0 && sign!=previous_sign)
               reversals++;
            previous_sign=sign;
            nonzero++;
           }
        }
      const double normalized_range=(bars[i].high-bars[i].low)/MathMax(bars[i].close,spec.tick_size);
      const double normalized_spread=((double)bars[i].spread*spec.point)/MathMax(bars[i].close,spec.tick_size);
      range_baseline+=normalized_range;
      spread_baseline+=normalized_spread;
      activity_baseline+=(double)bars[i].tick_volume;
      if(i>=start)
        {
         range_recent+=normalized_range;
         spread_recent+=normalized_spread;
         activity_recent+=(double)bars[i].tick_volume;
         const double true_range=MathMax(bars[i].high-bars[i].low,
                                         MathMax(MathAbs(bars[i].high-bars[i-1].close),MathAbs(bars[i].low-bars[i-1].close)));
         atr_sum+=true_range;
        }
     }
   const double direction=bars[copied-1].close-bars[start-1].close;
   const double efficiency=(abs_path>0.0 ? MathAbs(direction)/abs_path : 0.0);
   const double average_move=abs_path/InpFeatureWindow;
   const double structure=ARE_Clamp(100.0*MathAbs(direction)/(average_move*InpFeatureWindow+DBL_EPSILON));
   const double momentum=(bars[copied-1].close-bars[copied-6].close)/(average_move*5.0+DBL_EPSILON);
   const double volatility_ratio=(range_recent/InpFeatureWindow)/(range_baseline/(copied-1)+DBL_EPSILON);
   const double spread_ratio=(spread_recent/InpFeatureWindow)/(spread_baseline/(copied-1)+DBL_EPSILON);
   const double activity_ratio=(activity_recent/InpFeatureWindow)/(activity_baseline/(copied-1)+DBL_EPSILON);
   double high=bars[start].high,low=bars[start].low;
   for(int i=start+1;i<copied;i++) { high=MathMax(high,bars[i].high); low=MathMin(low,bars[i].low); }
   const double false_break=1.0-MathMin(1.0,MathAbs(direction)/(high-low+DBL_EPSILON));
   const double trend=ARE_Clamp(100.0*efficiency);
   const double momentum_score=ARE_Clamp(50.0+25.0*MathMax(-2.0,MathMin(2.0,momentum)));
   const double volatility_score=ARE_Clamp(50.0*MathMin(volatility_ratio,2.0));
   const double activity_score=ARE_Clamp(50.0*MathMin(activity_ratio,2.0));
   const double spread_damage=ARE_Clamp(100.0*(spread_ratio-0.8)/1.2);
   scores.mrs=ARE_Clamp(0.30*trend+0.22*momentum_score+0.18*structure+0.15*volatility_score*efficiency+0.15*activity_score);
   scores.wds=ARE_Clamp(0.38*100.0*reversals/MathMax(1,nonzero-1)+0.28*100.0*false_break+
                        0.20*spread_damage+0.14*ARE_Clamp(100.0*(volatility_ratio-1.0)));
   scores.ree_proxy=ARE_Clamp(0.46*scores.mrs+0.34*(100.0-scores.wds)+0.20*(100.0-spread_damage));
   scores.asset_score=ARE_Clamp(0.55*scores.mrs+0.30*scores.ree_proxy+0.15*(100.0-scores.wds));
   scores.directional_efficiency=efficiency;
   scores.volatility_ratio=volatility_ratio;
   scores.spread_ratio=spread_ratio;
   scores.direction=direction;
   scores.atr_price=atr_sum/InpFeatureWindow;
   scores.last_close=bars[copied-1].close;
   MqlTick current_tick;
   scores.current_spread_price=(SymbolInfoTick(symbol,current_tick) ? current_tick.ask-current_tick.bid : (double)bars[copied-1].spread*spec.point);
   scores.bars_used=copied;
   return true;
  }

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
   basket.net_volume=basket.buy_volume-basket.sell_volume;
   MqlTick tick;
   if(!SymbolInfoTick(symbol,tick))
     { basket.status="BASKET_WITHOUT_CURRENT_TICK"; return false; }
   if(basket.net_volume>0.0)
     {
      basket.weighted_entry=buy_value/basket.buy_volume;
      basket.current_price=tick.bid;
     }
   else if(basket.net_volume<0.0)
     {
      basket.weighted_entry=sell_value/basket.sell_volume;
      basket.current_price=tick.ask;
     }
   else
     {
      basket.weighted_entry=0.0;
      basket.current_price=(tick.bid+tick.ask)/2.0;
     }
   basket.distance_to_weighted_entry=MathAbs(basket.current_price-basket.weighted_entry);
   const double drawdown_penalty=ARE_Clamp(100.0*MathMax(0.0,-basket.floating_pnl)/(g_risk.DailyBudget()+DBL_EPSILON));
   const double distance_penalty=ARE_Clamp(100.0*basket.distance_to_weighted_entry/(scores.atr_price+DBL_EPSILON));
   const double hedge_penalty=(basket.net_volume==0.0 ? 50.0 : 0.0);
   basket.ree=ARE_Clamp(0.35*scores.mrs+0.25*(100.0-scores.wds)+0.20*(100.0-drawdown_penalty)+0.20*(100.0-distance_penalty)-hedge_penalty);
   basket.status=(basket.floating_pnl<0.0 ? "DRAWDOWN" : "NONNEGATIVE");
   return true;
  }

bool ARE_MakeGridPlan(const ARE_SymbolSpec &spec,const ARE_Scores &scores,const ARE_BasketSnapshot &basket,ARE_GridPlan &plan)
  {
   ZeroMemory(plan);
   if(!spec.valid || InpMaxGridDepth<1 || InpMinGridDistanceTicks<1 || InpMaxGridDistanceTicks<InpMinGridDistanceTicks)
     { plan.reason="INVALID_GRID_CONFIGURATION"; return false; }
   if(scores.wds>=InpWDSFreezeThreshold)
     { plan.reason="WDS_FREEZE"; return false; }
   if(basket.exists && basket.floating_pnl<0.0)
     { plan.reason="BASKET_DRAWDOWN_REQUIRES_RECOVERY_ANALYSIS"; return false; }
   const double min_broker_distance=MathMax((double)spec.stops_level,(double)spec.freeze_level)*spec.point;
   const double raw_distance=MathMax(min_broker_distance,MathMax(InpMinGridDistanceTicks*spec.tick_size,
                                         MathMax(InpATRMultiplier*scores.atr_price,InpSpreadMultiplier*scores.current_spread_price)));
   const double capped_distance=MathMin(raw_distance,InpMaxGridDistanceTicks*spec.tick_size);
   plan.grid_distance=MathCeil(capped_distance/spec.tick_size)*spec.tick_size;
   if(plan.grid_distance<min_broker_distance)
     { plan.reason="BROKER_DISTANCE_EXCEEDS_CONFIGURED_MAX"; return false; }

   const ENUM_ORDER_TYPE side=(scores.direction>=0.0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   const double stress_price=(side==ORDER_TYPE_BUY ? scores.last_close-InpStressDistanceATR*scores.atr_price : scores.last_close+InpStressDistanceATR*scores.atr_price);
   double loss_per_lot=0.0;
   if(!OrderCalcProfit(side,spec.name,1.0,scores.last_close,stress_price,loss_per_lot))
     { plan.reason="ORDERCALCPROFIT_FAILED"; return false; }
   loss_per_lot=MathAbs(loss_per_lot);
   if(loss_per_lot<=0.0)
     { plan.reason="NONPOSITIVE_STRESS_LOSS"; return false; }
   const double requested_volume=g_risk.ExpansionBudget()/loss_per_lot;
   plan.volume=ARE_NormalizeVolume(spec,requested_volume);
   if(plan.volume<=0.0)
     { plan.reason="RISK_BUDGET_BELOW_MINIMUM_VOLUME"; return false; }
   if(!OrderCalcProfit(side,spec.name,plan.volume,scores.last_close,(side==ORDER_TYPE_BUY ? scores.last_close-plan.grid_distance : scores.last_close+plan.grid_distance),plan.one_level_risk))
     { plan.reason="LEVEL_RISK_CALC_FAILED"; return false; }
   plan.one_level_risk=MathAbs(plan.one_level_risk);
   if(plan.one_level_risk<=0.0)
     { plan.reason="NONPOSITIVE_LEVEL_RISK"; return false; }
   if(!OrderCalcMargin(side,spec.name,plan.volume,scores.last_close,plan.one_level_margin))
     { plan.reason="ORDERCALCMARGIN_FAILED"; return false; }
   const double reserve=AccountInfoDouble(ACCOUNT_EQUITY)*InpMinFreeMarginReservePercent/100.0;
   const double available_margin=MathMax(0.0,AccountInfoDouble(ACCOUNT_MARGIN_FREE)-reserve);
   plan.risk_capacity=(int)MathFloor(g_risk.ExpansionBudget()/plan.one_level_risk);
   plan.margin_capacity=(plan.one_level_margin>0.0 ? (int)MathFloor(available_margin/plan.one_level_margin) : 0);
   plan.volatility_capacity=(int)MathFloor(InpMaxGridDepth*MathMax(0.0,1.0-scores.wds/100.0));
   plan.safe_depth=MathMin(InpMaxGridDepth,MathMin(plan.risk_capacity,MathMin(plan.margin_capacity,plan.volatility_capacity)));
   if(plan.safe_depth<1)
     { plan.reason="NO_SAFE_GRID_DEPTH"; return false; }
   plan.valid=true;
   plan.reason="OBSERVATION_ONLY_PLAN";
   return true;
  }

ARE_Decision ARE_MakeDecision(const ARE_SymbolSpec &spec,const ARE_Scores &scores,const ARE_BasketSnapshot &basket,string &reason)
  {
   if(g_risk.HardDailyStop())
     { reason="HARD_DAILY_RISK_LIMIT"; return ARE_EMERGENCY_STOP_DECISION; }
   if(InpMaxSpreadPoints>0 && (int)SymbolInfoInteger(spec.name,SYMBOL_SPREAD)>InpMaxSpreadPoints)
     { reason="MAX_SPREAD"; return ARE_FREEZE_DECISION; }
   if(scores.wds>=InpWDSFreezeThreshold)
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

bool ARE_Assess(const string symbol,ARE_Assessment &assessment)
  {
   assessment.symbol=symbol;
   if(!ARE_LoadSymbolSpec(symbol,assessment.spec))
     { assessment.reason="INVALID_OR_UNAVAILABLE_SYMBOL_SPEC"; assessment.decision=ARE_NO_TRADE; return false; }
   if(!ARE_CalculateScores(symbol,assessment.spec,assessment.scores))
     { assessment.reason="INSUFFICIENT_COMPLETED_M1_BARS"; assessment.decision=ARE_NO_TRADE; return false; }
   if(!ARE_ReadBasket(symbol,assessment.scores,assessment.basket))
     { assessment.reason="BASKET_READ_FAILED"; assessment.decision=ARE_PROTECT_DECISION; return false; }
   assessment.decision=ARE_MakeDecision(assessment.spec,assessment.scores,assessment.basket,assessment.reason);
   return true;
  }

void ARE_Log(const ARE_Assessment &a)
  {
   if(!InpDebugLog) return;
   PrintFormat("[ARE] Symbol=%s State=%s MRS=%.2f WDS=%.2f REE=%.2f AssetScore=%.2f BasketPositions=%d BasketPnL=%.2f BasketREE=%.2f Equity=%.2f DailyPnL=%.2f DailyBudget=%.2f Decision=%s Reason=%s",
               a.symbol,ARE_StateText(g_state),a.scores.mrs,a.scores.wds,a.scores.ree_proxy,a.scores.asset_score,
               a.basket.positions,a.basket.floating_pnl,a.basket.ree,AccountInfoDouble(ACCOUNT_EQUITY),g_risk.ClosedDailyPnL(),g_risk.DailyBudget(),ARE_DecisionText(a.decision),a.reason);
  }

void ARE_RenderPanel(const ARE_Assessment &a,const ARE_GridPlan &plan)
  {
   Comment("ARE STATUS: ",ARE_StateText(g_state),"\n",
           "Selected: ",a.symbol,"\n",
           "MRS / WDS / REE: ",DoubleToString(a.scores.mrs,1)," / ",DoubleToString(a.scores.wds,1)," / ",DoubleToString(a.scores.ree_proxy,1),"\n",
           "Asset score: ",DoubleToString(a.scores.asset_score,1),"\n",
           "Basket: ",a.basket.status," / positions ",IntegerToString(a.basket.positions)," / PnL ",DoubleToString(a.basket.floating_pnl,2)," / REE ",DoubleToString(a.basket.ree,1),"\n",
           "Grid plan: ",(plan.valid ? "depth "+IntegerToString(plan.safe_depth)+" / volume "+DoubleToString(plan.volume,2)+" / distance "+DoubleToString(plan.grid_distance,_Digits) : plan.reason),"\n",
           "Daily PnL / Budget: ",DoubleToString(g_risk.ClosedDailyPnL(),2)," / ",DoubleToString(g_risk.DailyBudget(),2),"\n",
           "Decision: ",ARE_DecisionText(a.decision),"\n",
           "Execution: ",(InpEnableExecution ? "NOT IMPLEMENTED - BLOCKED" : "OBSERVATION ONLY"));
  }

void ARE_Evaluate(void)
  {
   g_state=ARE_SCANNING;
   string symbols[3]={InpPoolSymbol1,InpPoolSymbol2,InpPoolSymbol3};
   int count=(InpOperatingMode==ARE_SINGLE_ASSET ? 1 : 3);
   if(InpOperatingMode==ARE_SINGLE_ASSET) symbols[0]=InpSingleSymbol;
   ARE_Assessment best;
   bool have_best=false;
   for(int i=0;i<count;i++)
     {
      ARE_Assessment current;
      if(!ARE_Assess(symbols[i],current)) { ARE_Log(current); continue; }
      ARE_Log(current);
      if(!have_best || current.scores.asset_score>best.scores.asset_score)
        { best=current; have_best=true; }
     }
   if(!have_best) { g_state=ARE_IDLE; Comment("ARE STATUS: insufficient symbol data/specification"); return; }
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

int OnInit(void)
  {
   if(InpFeatureWindow<6 || InpBaselineWindow<InpFeatureWindow || InpWDSUnfreezeThreshold>=InpWDSFreezeThreshold || InpMinFreeMarginReservePercent<0.0 || InpMinFreeMarginReservePercent>100.0)
      return INIT_PARAMETERS_INCORRECT;
   if(!g_risk.Configure()) return INIT_PARAMETERS_INCORRECT;
   EventSetTimer(60);
   ARE_Evaluate();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason) { EventKillTimer(); Comment(""); }
void OnTimer(void) { ARE_Evaluate(); }
void OnTick(void) { /* Evaluation is timer-driven; no trade requests exist in this release. */ }
