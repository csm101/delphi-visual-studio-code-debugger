program TestTarget;
// Dedicated test target for Win64Debugger integration tests (MONOLITHIC scenario).
//
// Built as a GUI-subsystem program (NO {$APPTYPE CONSOLE}) so the OS does not
// allocate a console window when the debugger launches it. The debugger must not
// have to set any flag on CreateProcess to suppress windows -- the test target
// itself is responsible for never opening a window of its own.
//
// The subject code (types, ~50 Run*/probe procs, globals) lives in the shared
// unit TestTargetCore, compiled BOTH into this exe AND into TestSubject.bpl (BPL
// scenario). This .dpr is just the thin monolithic driver: it runs the shared
// RunAllScenarios driver, then the irreducibly exe-only program-main-block
// scenario whose inline vars (TheWidget/TheStuff) exist ONLY in the RSM
// main-block table and have no BPL/TD32 equivalent.

uses
  // FIRST: installs the silent-failure handlers before any fixture can fault.
  // Deliberate exceptions must not pop a modal dialog in an unattended run.
  TestTargetQuiet in 'TestTargetQuiet.pas',
  TestTargetCore in 'TestTargetCore.pas';

begin
  RunAllScenarios;          // {BP:MAIN_FIRST_LINE}

  // Exe-only RSM main-block scenario: program inline-var locals (TheWidget /
  // TheStuff) are emitted ONLY in the RSM main-block table -- a BPL/package has
  // no program begin..end. block, so this block cannot be reproduced there.
  GCounter := 0;
  var TheWidget := TWidget.Create('hello', 42);
  var TheStuff  := TStuff.Create(7, 'tag');
  try
    GCounter := 1;           // {BP:MAIN_GCOUNTER}
    var Res := 0;
    TheWidget.Compute(Res);
    GSink.Use(['Compute: ', Res]);
    // Keep Sum5 in the binary for the stacked-argument eval test (guard never
    // true at runtime).
    if GCounter < 0 then
      GSink.Use([TheWidget.Sum5(1, 2, 3, 4, 5)]);
    var X := 10;
    ComputeNested(X);
    GSink.Use(['X after: ', X]); // {BP:MAIN_AFTER_NESTED}
    GSink.Use([TheStuff.PubCount]);
    GSink.Use([TheStuff.PubBump]);  // triggers BP:STUFF_PUBBUMP
    // Keep BumpCount / RaiseBoom in the binary for the watch tests without
    // running them on the normal path (guard is never true at runtime).
    if GCounter < 0 then begin
      GSink.Use([TheStuff.BumpCount]);
      GSink.Use([TheStuff.RaiseBoom]);
    end;
  finally
    TheStuff.Free;
    TheWidget.Free;
  end;
end.
