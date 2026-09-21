unit MapOnlyBigTextTarget;

// The unit a breakpoint is placed in (see MapOnlyBigText.dpr). Linked after
// MapOnlyBigTextFiller, so its code lies past the first 4 MB of .text.

interface

procedure RunTarget(Seed: Integer);

implementation

uses
  Winapi.Windows;

var
  GTargetSink: Integer = 0;

procedure RunTarget(Seed: Integer);
begin
  GTargetSink := Seed + 1;   // {BP:MAPBIG_ENTRY}
  if GTargetSink = 0 then    // {BP:MAPBIG_TARGET}
    ExitProcess(3);
end;

end.
