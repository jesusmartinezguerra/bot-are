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
