unit FixtureQuietNoSysUtils;

// FixtureQuiet for the fixtures that deliberately do not link System.SysUtils
// (a MAP-only target, a binary without debug info, an external .tds): the same
// mechanism, minus the one part that needs System.SysUtils. Using FixtureQuiet
// there would link System.SysUtils into a binary that exists to be without it.
//
// Without System.SysUtils no ExceptProc is installed at all, so an unhandled
// exception ends in the RTL's run-time error 217 and a fault in run-time error
// 216 (Win32) or in the unhandled-exception filter (Win64, where the RTL does
// not map a fault to a Delphi exception without System.SysUtils). The ExceptProc
// below only WRITES the exception and returns, so the RTL still ends the process
// with run-time error 217 -- the exit code is the one the fixture always had.
//
// Effective merely by being in the program's `uses`, in any position: nothing in
// such a program installs an ExceptProc of its own.

{$I FixtureQuietSwitches.inc}

interface

implementation

uses
  Winapi.Windows;

{$I FixtureQuiet.inc}

procedure ReportUnhandledException(ExceptObject: TObject; ExceptAddr: Pointer);
begin
  var Line: TQuietLine;
  Line.Clear;
  Line.Add(@GQuietExeName[0]);
  Line.Add(': unhandled exception ');
  if ExceptObject <> nil then
    Line.AddText(ExceptObject.ClassName);
  Line.Add(' at ');
  Line.AddAddress(ExceptAddr);
  Line.Add('; the RTL ends the process with run-time error 217');
  Line.Emit;
end;

initialization
  InstallQuietFailureHandling;
  ExceptProc := @ReportUnhandledException;

end.
