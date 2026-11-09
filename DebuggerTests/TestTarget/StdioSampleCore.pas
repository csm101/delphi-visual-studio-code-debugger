unit StdioSampleCore;

// The scenario StdioConsoleSample.exe and StdioGuiSample.exe both run: a debuggee
// that uses its standard handles the way a console test runner does. It goes
// through the raw handles (WriteFile / ReadFile) rather than Write / Readln, so
// the console and the GUI build behave alike and neither depends on the RTL
// having opened Output.
//
// The order is the one that lost a reply in the field: a line on stderr, then a
// stdout fragment WITHOUT a line break, then a first-chance Delphi exception
// (EStdioSampleMarker) -- the stop a debugger reports while that fragment is the
// last thing written. After the stop the program reads its standard input and
// reports how many bytes it got: the NUL device gives 0, while a debugger's own
// protocol input would block the read or hand it a client request.

interface

procedure RunStdioScenario;

implementation

uses
  Winapi.Windows, System.SysUtils;

type
  EStdioSampleMarker = class(Exception);

function UsableStdHandle(StdHandle: DWORD; out Handle: THandle): Boolean;
begin
  Handle := GetStdHandle(StdHandle);
  if Handle = 0 then
    Exit(False);
  Result := Handle <> INVALID_HANDLE_VALUE;
end;

procedure WriteToStdHandle(StdHandle: DWORD; const Text: AnsiString);
begin
  var Handle: THandle;
  if not UsableStdHandle(StdHandle, Handle) then
    Exit;
  var Written: DWORD := 0;
  WriteFile(Handle, PAnsiChar(Text)^, Length(Text), Written, nil);
end;

// -1 when there is no usable standard input or the read fails.
function BytesReadFromStdIn: Integer;
begin
  var Handle: THandle;
  if not UsableStdHandle(STD_INPUT_HANDLE, Handle) then
    Exit(-1);
  var Buffer: array[0..63] of Byte;
  var BytesRead: DWORD := 0;
  if not ReadFile(Handle, Buffer, SizeOf(Buffer), BytesRead, nil) then
    Exit(-1);
  Result := BytesRead;
end;

procedure RunStdioScenario;
begin
  WriteToStdHandle(STD_ERROR_HANDLE, 'STDIO_SAMPLE_STDERR' + #13#10);
  WriteToStdHandle(STD_OUTPUT_HANDLE, 'STDIO_SAMPLE_PARTIAL');
  try
    raise EStdioSampleMarker.Create('stdio sample marker');
  except
    on EStdioSampleMarker do
      WriteToStdHandle(STD_OUTPUT_HANDLE, ' CAUGHT');
  end;
  WriteToStdHandle(STD_OUTPUT_HANDLE, AnsiString(Format(' STDIN_BYTES=%d', [BytesReadFromStdIn])) + #13#10);
  WriteToStdHandle(STD_OUTPUT_HANDLE, 'STDIO_SAMPLE_DONE' + #13#10);
end;

end.
