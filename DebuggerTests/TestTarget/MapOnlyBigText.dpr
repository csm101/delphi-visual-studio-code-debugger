program MapOnlyBigText;

// GitHub issue #12 fixture: a MAP-only target (-GD, no -V / -VR / -VN) whose
// .text is larger than 4 MB, so the MAP's "Detailed map of segments" lists unit
// offsets above the $400000 preferred base. The MAP reader took such an offset
// for segment 1's base: every breakpoint was reported verified and none was
// ever hit.
//
// MapOnlyBigTextFiller only supplies the bulk; MapOnlyBigTextTarget is linked
// after it, so its code sits past the 4 MB mark. The program also has a routine
// of its own, which gives this file a .text section besides the .itext one
// that holds the main block below on Win32 -- the second "Line numbers for"
// section of a file, which the reader used to ignore.

// GUI subsystem deliberately (no {$APPTYPE CONSOLE}): launching it must not open
// a console window, the same rule the other test targets follow.

uses
  Winapi.Windows,
  MapOnlyBigTextFiller in 'MapOnlyBigTextFiller.pas',
  MapOnlyBigTextTarget in 'MapOnlyBigTextTarget.pas';

var
  GMainReached: Integer = 0;

procedure KeepFillerLinked;
begin
  // Never true at run time. Referencing RunFiller is what makes the linker keep
  // the filler, and with it the 4 MB in front of the target unit.
  if ParamCount = 12345 then
    RunFiller;
end;

// The tests step INTO the first RunTarget call: on Win32 the filler's `end.`
// record lies 4 bytes inside RunTarget, and a step-into used to stop there
// showing the filler. The two calls reach any breakpoint in RunTarget with the
// same thread, RIP and RSP -- only the return address differs -- which is what
// the engine's frames cache got wrong.
begin
  KeepFillerLinked;
  GMainReached := GetCurrentProcessId;   // {BP:MAPBIG_MAIN}
  RunTarget(GMainReached);               // {BP:MAPBIG_CALL}
  RunTarget(GMainReached + 1);           // {BP:MAPBIG_CALL2}
end.
