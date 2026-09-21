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

begin
  KeepFillerLinked;
  GMainReached := GetCurrentProcessId;   // {BP:MAPBIG_MAIN}
  RunTarget(GMainReached);
end.
