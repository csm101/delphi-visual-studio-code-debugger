unit FixtureQuiet;

// Makes a fixture program fail in WRITING, never in a dialog. Every fixture
// program that links System.SysUtils uses this unit; one that deliberately does
// not link it uses FixtureQuietNoSysUtils instead. FixtureQuietTests fails for a
// fixture that uses neither.
//
// Fixtures crash on purpose -- access violations, unhandled exceptions, negative
// controls -- and the suite runs on the machine somebody is working on. A modal
// box takes that person's keyboard focus and, in an unattended run, blocks the
// fixture until someone clicks it.
//
// Effective merely by being in the program's `uses`, in any position: it uses
// System.SysUtils, so it is initialized AFTER System.SysUtils, whose
// initialization installs the RTL's own ExceptProc (the "Application Error"
// box). The unit this one replaces was listed first precisely to run early --
// and was therefore overwritten by System.SysUtils every time.
//
// What is deliberately NOT changed: an exception is still raised and still
// delivered to a debugger as a first-chance exception, and the exit codes are
// the RTL's own (1 after an unhandled exception, the run-time error number
// after a run-time error, the exception code after a fault nothing handles).

{$I FixtureQuietSwitches.inc}

interface

implementation

uses
  System.SysUtils, Winapi.Windows;

{$I FixtureQuiet.inc}

// What System.SysUtils.ExceptHandler does, without the message box: report the
// exception, then end the process with exit code 1.
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
  if ExceptObject is Exception then begin
    Line.Add(': ');
    Line.AddText(Exception(ExceptObject).Message);
  end;
  Line.Add('; the process ends with exit code 1');
  Line.Emit;
  Halt(1);
end;

initialization
  InstallQuietFailureHandling;
  ExceptProc := @ReportUnhandledException;

end.
