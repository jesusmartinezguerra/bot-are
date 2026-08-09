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
