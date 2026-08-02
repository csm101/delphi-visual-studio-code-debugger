unit TestTargetQuiet;

// Makes the test targets fail SILENTLY.
//
// Several fixtures raise deliberately (access violations, unhandled Delphi
// exceptions) so the debugger can be observed reacting to them. When such an
// exception is not handled, two things would otherwise pop a MODAL dialog and
// block the machine until someone clicks OK:
//
//   * the Delphi RTL's own "Application Error" box, from the default ExceptProc;
//   * the Windows error box for a hard fault, from the default error mode.
//
// A test run is unattended, so either one turns a deliberate fixture into a
// hung suite. Both are switched off here.
//
// What is deliberately NOT changed: the exception is still RAISED and still
// delivered to the debugger as a first-chance exception. Suppressing the DIALOG
// is not the same as swallowing the exception, and the exception tests depend
// on the difference.
//
// Effective merely by being in a program's `uses` -- list it FIRST so the
// initialization runs before any fixture can fault.

interface

implementation

uses
  Winapi.Windows;

procedure QuietExceptProc(ExceptObject: TObject; ExceptAddr: Pointer);
begin
  // Terminate with a failure code, as an unhandled exception did before -- just
  // without the dialog. No output: the target is a GUI-subsystem binary with no
  // console to write to.
  Halt(1);
end;

const
  // SEH filter return: handle it here rather than let Windows show its box.
  // Spelled out because Winapi.Windows does not export the constant.
  FILTER_EXECUTE_HANDLER = LongInt(1);

function QuietUnhandledFilter(ExceptionInfo: PExceptionPointers): LongInt; stdcall;
begin
  // Reached only for faults the RTL does not turn into a Delphi exception.
  // Terminating the process is what would have happened anyway once the box was
  // dismissed.
  Result := FILTER_EXECUTE_HANDLER;
end;

initialization
  // No "abort/retry/ignore" for missing media, and no hard-fault box.
  SetErrorMode(SetErrorMode(0) or SEM_FAILCRITICALERRORS or SEM_NOGPFAULTERRORBOX
    or SEM_NOOPENFILEERRORBOX);
  SetUnhandledExceptionFilter(@QuietUnhandledFilter);
  ExceptProc := @QuietExceptProc;

end.
