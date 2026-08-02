program TestHost;

// Thin BPL host for the debugger's BPL scenario. It LoadPackages TestSubject.bpl
// (which contains the same subject code as the monolithic TestTarget.exe) and
// calls its exported RunAllScenarios. The host deliberately does NOT statically
// reference any subject unit, so the subject classes/procs exist ONLY inside the
// runtime package -- this is the "application split into BPLs" / "BPL loaded by a
// third-party host" shape the debugger must support.
//
// GUI subsystem (no {$APPTYPE CONSOLE}) so launching it opens no console window,
// matching TestTarget.exe.

uses
  // FIRST: silences the RTL and Windows error dialogs before the package is
  // loaded, so a deliberate fault inside TestSubject.bpl cannot block an
  // unattended run. The exception is still raised and still reaches the
  // debugger; only the modal box is gone.
  TestTargetQuiet in '..\TestTarget\TestTargetQuiet.pas',
  System.SysUtils,
  Winapi.Windows;

type
  TRunAll = procedure;

var
  H:  HMODULE;
  Fn: TRunAll;

begin
  H := LoadPackage('TestSubject.bpl');
  if H <> 0 then begin
    @Fn := GetProcAddress(H, 'RunAllScenarios');
    if Assigned(Fn) then
      Fn;
  end;
end.
