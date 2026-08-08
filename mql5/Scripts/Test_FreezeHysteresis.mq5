#property strict

#include "..\Experts\ARE_TRADER\Include\ARE_Common.mqh"

struct Step
  {
   double wds;
   bool   expected;
   string label;
  };

void OnStart(void)
  {
   const string sym="TESTSYM";
   const double freeze=70.0, unfreeze=45.0;
   Step steps[] =
     {
      {50.0, false, "below freeze, starts unfrozen"},
      {72.0, true,  "crosses freeze threshold"},
      {60.0, true,  "dips below freeze but above unfreeze -> must STAY frozen"},
      {46.0, true,  "still above unfreeze -> must STAY frozen"},
      {45.0, false, "at unfreeze threshold -> releases"},
      {50.0, false, "back below freeze, stays unfrozen"},
      {71.0, true,  "crosses freeze threshold again"},
     };

   bool all_passed=true;
   for(int i=0;i<ArraySize(steps);i++)
     {
      const bool actual=ARE_UpdateFreezeState(sym,steps[i].wds,freeze,unfreeze);
      const bool ok=(actual==steps[i].expected);
      all_passed=all_passed && ok;
      PrintFormat("[TEST] step=%d wds=%.1f expected=%s actual=%s %s -- %s",
                  i,steps[i].wds,(steps[i].expected?"true":"false"),(actual?"true":"false"),
                  (ok?"PASS":"FAIL"),steps[i].label);
     }
   PrintFormat("[TEST] RESULT=%s",(all_passed?"ALL_PASSED":"FAILURES_PRESENT"));
  }
