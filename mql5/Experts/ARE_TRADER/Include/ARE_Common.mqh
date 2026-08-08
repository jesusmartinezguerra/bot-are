#ifndef ARE_COMMON_MQH
#define ARE_COMMON_MQH

enum ARE_OperatingMode
  {
   ARE_SINGLE_ASSET = 0,
   ARE_ASSET_POOL  = 1,
   ARE_PORTFOLIO   = 2
  };

enum ARE_State
  {
   ARE_IDLE, ARE_SCANNING, ARE_ASSET_SELECTION, ARE_WATCH,
   ARE_EXPANSION, ARE_FREEZE, ARE_RECOVERY_ANALYSIS, ARE_RESOLVE,
   ARE_PROTECT, ARE_EMERGENCY_STOP
  };

enum ARE_Decision
  {
   ARE_NO_TRADE, ARE_WATCH_ONLY, ARE_EXPAND, ARE_REDUCED_EXPANSION,
   ARE_FREEZE_DECISION, ARE_RESOLVE_DECISION, ARE_PROTECT_DECISION,
   ARE_EMERGENCY_STOP_DECISION
  };

struct ARE_SymbolSpec
  {
   string name;
   double point;
   double tick_size;
   double tick_value;
   double contract_size;
   double volume_min;
   double volume_max;
   double volume_step;
   double margin_initial;
   int    stops_level;
   int    freeze_level;
   bool   valid;
  };

struct ARE_Scores
  {
   double mrs;
   double wds;
   double ree_proxy;
   double asset_score;
   double directional_efficiency;
   double volatility_ratio;
   double spread_ratio;
   double direction;
   double atr_price;
   double last_close;
   double current_spread_price;
   int    bars_used;
   bool   frozen;
  };

// Per-symbol Freeze/Unfreeze hysteresis (spec section 22). WDS crossing the
// freeze threshold latches FREEZE; only WDS at or below the unfreeze
// threshold releases it. State lives only for the current EA run/backtest -
// it is not persisted across terminal restarts.
struct ARE_FreezeState
  {
   string symbol;
   bool   frozen;
  };

ARE_FreezeState g_are_freeze_states[];

int ARE_FindFreezeSlot(const string symbol)
  {
   for(int i=0;i<ArraySize(g_are_freeze_states);i++)
      if(g_are_freeze_states[i].symbol==symbol)
         return i;
   const int slot=ArraySize(g_are_freeze_states);
   ArrayResize(g_are_freeze_states,slot+1);
   g_are_freeze_states[slot].symbol=symbol;
   g_are_freeze_states[slot].frozen=false;
   return slot;
  }

bool ARE_UpdateFreezeState(const string symbol,const double wds,const double freeze_threshold,const double unfreeze_threshold)
  {
   const int slot=ARE_FindFreezeSlot(symbol);
   if(g_are_freeze_states[slot].frozen)
     {
      if(wds<=unfreeze_threshold)
         g_are_freeze_states[slot].frozen=false;
     }
   else if(wds>=freeze_threshold)
      g_are_freeze_states[slot].frozen=true;
   return g_are_freeze_states[slot].frozen;
  }

struct ARE_GridPlan
  {
   bool   valid;
   int    safe_depth;
   int    risk_capacity;
   int    margin_capacity;
   int    volatility_capacity;
   double grid_distance;
   double volume;
   double one_level_risk;
   double one_level_margin;
   string reason;
  };

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

struct ARE_Assessment
  {
   string       symbol;
   ARE_SymbolSpec spec;
   ARE_Scores   scores;
   ARE_BasketSnapshot basket;
   ARE_Decision decision;
   string       reason;
  };

double ARE_Clamp(const double value,const double low=0.0,const double high=100.0)
  {
   return MathMax(low,MathMin(high,value));
  }

string ARE_StateText(const ARE_State state)
  {
   switch(state)
     {
      case ARE_IDLE: return "IDLE";
      case ARE_SCANNING: return "SCANNING";
      case ARE_ASSET_SELECTION: return "ASSET_SELECTION";
      case ARE_WATCH: return "WATCH";
      case ARE_EXPANSION: return "EXPANSION";
      case ARE_FREEZE: return "FREEZE";
      case ARE_RECOVERY_ANALYSIS: return "RECOVERY_ANALYSIS";
      case ARE_RESOLVE: return "RESOLVE";
      case ARE_PROTECT: return "PROTECT";
      case ARE_EMERGENCY_STOP: return "EMERGENCY_STOP";
     }
   return "UNKNOWN";
  }

string ARE_DecisionText(const ARE_Decision decision)
  {
   switch(decision)
     {
      case ARE_NO_TRADE: return "NO_TRADE";
      case ARE_WATCH_ONLY: return "WATCH";
      case ARE_EXPAND: return "EXPAND";
      case ARE_REDUCED_EXPANSION: return "REDUCED_EXPANSION";
      case ARE_FREEZE_DECISION: return "FREEZE";
      case ARE_RESOLVE_DECISION: return "RESOLVE";
      case ARE_PROTECT_DECISION: return "PROTECT";
      case ARE_EMERGENCY_STOP_DECISION: return "EMERGENCY_STOP";
     }
   return "UNKNOWN";
  }

#endif // ARE_COMMON_MQH
