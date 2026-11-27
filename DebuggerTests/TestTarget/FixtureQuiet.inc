// Shared body of FixtureQuiet.pas and FixtureQuietNoSysUtils.pas: everything of
// the quiet mechanism that needs nothing beyond System and Winapi.Windows.
// Included rather than used: a unit that another unit uses must be on the
// PROGRAM's search path, and the fixtures live in three directories, while an
// include file is found beside the unit that includes it.
//
// What a fixture would otherwise show, and what replaces it:
//
//   * the RTL's run-time error box ("Runtime error 204 at ..."): NoErrMsg, and
//     IsConsole. The RTL reads IsConsole in exactly four places, each one a
//     choice between writing to a standard handle and showing a message box
//     (run-time error, SysUtils.ShowException, memory-leak report, trial
//     expiry), so setting it makes every RTL report a line of text. The
//     run-time error line goes to STANDARD OUTPUT, where the RTL writes it for
//     a console program: no code of ours can run between the moment the RTL
//     sets ErrorAddr and the moment it clears it again, which happens before
//     the ExitProc chain and before any finalization;
//   * the Windows error box and the Windows Error Reporting dialog for a fault
//     nothing handles: the error mode, and an unhandled-exception filter that
//     writes the fault and lets the process end with the exception code.
//
// The failure text goes to the standard error handle when the process has one,
// and through OutputDebugString, which a debugging session shows as debugger
// output. docs/TRAPS.md, "Fixture design", has the whole picture.

const
  // SEH filter return: handle it here rather than let Windows show its box.
  // Spelled out because Winapi.Windows does not export the constant.
  FILTER_EXECUTE_HANDLER = LongInt(1);
  {$IFDEF CPUX86}
  // Exception code of a Delphi `raise`. The RTL reports those itself, through
  // ExceptProc; on Win32 it consults the unhandled-exception filter first.
  DELPHI_EXCEPTION_CODE = DWORD($0EEDFADE);
  {$ENDIF}
  QUIET_ERROR_MODE = SEM_FAILCRITICALERRORS or SEM_NOGPFAULTERRORBOX or SEM_NOOPENFILEERRORBOX;

type
  // One line of failure text, composed in a fixed buffer: the filter below may
  // run on a thread whose stack is nearly exhausted, so nothing here allocates.
  TQuietLine = record
  private const
    CAPACITY = 1024;
  private
    FText:   array[0..CAPACITY - 1] of AnsiChar;
    FLength: Integer;
    procedure AddChar(C: AnsiChar);
  public
    procedure Clear;
    procedure Add(Text: PAnsiChar);
    procedure AddText(const Text: string);
    procedure AddHex(Value: UInt64; Digits: Integer);
    procedure AddAddress(Address: Pointer);
    procedure Emit;
  end;

var
  // File name of the executable, read once at start-up so the filter needs no
  // call that could allocate.
  GQuietExeName: array[0..MAX_PATH] of AnsiChar;

procedure WriteFailureText(Text: PAnsiChar; TextLength: Integer);
begin
  var StdErr := GetStdHandle(STD_ERROR_HANDLE);
  if (StdErr <> 0) and (StdErr <> INVALID_HANDLE_VALUE) then begin
    var Written: DWORD := 0;
    WriteFile(StdErr, Text^, TextLength, Written, nil);
  end;
  OutputDebugStringA(Text);
end;

procedure TQuietLine.AddChar(C: AnsiChar);
begin
  // Room is kept for the line break and the terminating zero Emit appends.
  if FLength >= CAPACITY - 3 then
    Exit;
  FText[FLength] := C;
  Inc(FLength);
end;

procedure TQuietLine.Clear;
begin
  FLength := 0;
end;

procedure TQuietLine.Add(Text: PAnsiChar);
begin
  if Text = nil then
    Exit;
  while Text^ <> #0 do begin
    AddChar(Text^);
    Inc(Text);
  end;
end;

procedure TQuietLine.AddText(const Text: string);
begin
  for var C in Text do
    if Ord(C) < 128 then
      AddChar(AnsiChar(C))
    else
      AddChar('?');
end;

procedure TQuietLine.AddHex(Value: UInt64; Digits: Integer);
const
  HEX_DIGITS: array[0..15] of AnsiChar = '0123456789ABCDEF';
begin
  for var Shift := Digits - 1 downto 0 do
    AddChar(HEX_DIGITS[Integer((Value shr (Shift * 4)) and $F)]);
end;

procedure TQuietLine.AddAddress(Address: Pointer);
begin
  Add('$');
  AddHex(UInt64(NativeUInt(Address)), SizeOf(Pointer) * 2);
end;

procedure TQuietLine.Emit;
begin
  FText[FLength] := #13;
  FText[FLength + 1] := #10;
  FText[FLength + 2] := #0;
  WriteFailureText(@FText[0], FLength + 2);
end;

// Reached by a fault nothing in the program handles, and -- on Win32 only, and
// only without a debugger -- by every exception that reaches the RTL's own
// outermost frame, which consults this filter before it reports the exception
// itself (so a Win32 fault on the main thread is written twice: here, then by
// ExceptProc or as a run-time error).
function QuietUnhandledFilter(ExceptionInfo: PExceptionPointers): LongInt; stdcall;
begin
  // Terminating the process is what would have happened anyway once the box was
  // dismissed; EXECUTE_HANDLER does it without the box, with the exception code
  // as the exit code -- or hands the exception back to the RTL's frame on Win32.
  Result := FILTER_EXECUTE_HANDLER;
  var Rec := ExceptionInfo^.ExceptionRecord;
  {$IFDEF CPUX86}
  // The RTL's frame is asking, and reports the Delphi exception right after.
  if Rec^.ExceptionCode = DELPHI_EXCEPTION_CODE then
    Exit;
  {$ENDIF}
  var Line: TQuietLine;
  Line.Clear;
  Line.Add(@GQuietExeName[0]);
  Line.Add(': unhandled OS exception $');
  Line.AddHex(Rec^.ExceptionCode, 8);
  Line.Add(' at ');
  Line.AddAddress(Rec^.ExceptionAddress);
  Line.Add(' (unhandled-exception filter)');
  Line.Emit;
end;

procedure RememberExeName;
begin
  var Path: array[0..MAX_PATH] of AnsiChar;
  var PathLength := Integer(GetModuleFileNameA(0, Path, Length(Path)));
  var NameStart := 0;
  for var I := 0 to PathLength - 1 do
    if Path[I] = '\' then
      NameStart := I + 1;
  var NameLength := PathLength - NameStart;
  if NameLength > 0 then
    Move(Path[NameStart], GQuietExeName[0], NameLength);
  GQuietExeName[NameLength] := #0;
end;

procedure InstallQuietFailureHandling;
begin
  RememberExeName;
  // No "abort, retry, ignore" for missing media, no hard-fault box, no Windows
  // Error Reporting dialog. Children of the fixture inherit it.
  SetErrorMode(GetErrorMode or QUIET_ERROR_MODE);
  SetUnhandledExceptionFilter(@QuietUnhandledFilter);
  {$WARN SYMBOL_PLATFORM OFF}
  NoErrMsg := True;
  {$WARN SYMBOL_PLATFORM ON}
  IsConsole := True;
end;
