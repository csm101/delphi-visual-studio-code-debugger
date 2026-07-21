program NoDebugExe;

// A minimal Win64 console program built WITHOUT any Delphi debug info (no
// -V/-VN/-VR, debug switches off) so it emits no embedded TD32 / .map / .rsm /
// .jdbg. Used by DebugSessionTests to verify the "no debug info in any format"
// diagnostic fires for a blind main module. It is launched with stopAtEntry, so
// the body never actually runs before the test terminates it.

{$APPTYPE CONSOLE}

uses
  Winapi.Windows;

begin
  Sleep(60000);
end.
