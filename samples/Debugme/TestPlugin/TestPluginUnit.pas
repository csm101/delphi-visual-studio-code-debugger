unit TestPluginUnit;

// Minimal library unit used as a breakpoint target when testing multi-module
// (BPL/DLL) debugging.  Set a BP on any line inside Compute and launch
// "Debug Debugme + TestPlugin (BPL test)" to verify the debugger stops in
// dynamically-loaded code.

interface

function Compute(X, Y: Integer): Integer; stdcall;

implementation

function Compute(X, Y: Integer): Integer; stdcall;
var
  A, B: Integer;
begin
  A      := X * 3;    // BP target — should be reachable from host EXE
  B      := Y * 5;
  Result := A + B;    // Compute(3,7) → 9 + 35 = 44
end;

end.
