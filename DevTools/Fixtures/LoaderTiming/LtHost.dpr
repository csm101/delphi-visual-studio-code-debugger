program LtHost;

{
  Host fixture of DevTools\LoaderTimingProbe. Built with runtime packages
  (rtl + LtPkgStatic), so it needs rtl290.bpl on the PATH: pass the probe
  `-path <BDS>\bin64` or `-path <BDS>\bin`.

  What is in it, for the question "what has run when":

    a statically required package of its own     LtPkgStatic.bpl
    a statically imported plain DLL              LtDllStatic.dll
    a unit of its own with an initialization     LtHostUnit
    packages loaded later with LoadPackage       -pkg <file>
    plain DLLs loaded later with LoadLibrary     -dll <file>

  Every initialization section, DLL begin..end block and DllProc notification
  announces itself with OutputDebugString; the results of the calls go to stdout,
  so that a run under a probe can be compared with a plain run.

  Usage: LtHost [-wait] [-pkg <bpl>]... [-dll <dll>]...

    -wait   before the -pkg / -dll loads, print `counter=<hex> release=<hex>`
            (the addresses of two 32-bit variables) and spin, incrementing the
            counter, until somebody writes a non-zero value to the release
            variable or 30 seconds pass. It is where a debugger attaches.
    -pkg    LoadPackage the file and call its exported LtPkgDynamicValue.
    -dll    LoadLibrary the file and call its exported LtTouch twice.
            Both in command-line order, relative paths against the executable.
}

{$APPTYPE CONSOLE}

uses
  Winapi.Windows,
  System.SysUtils,
  LtHostUnit in 'LtHostUnit.pas',
  LtPkgStaticUnit;

type
  TTouchFunction = function(Value: Integer): Integer; stdcall;
  TValueFunction = function(Value: Integer): Integer;

function LtStaticTouch(Value: Integer): Integer; stdcall; external 'LtDllStatic.dll' name 'LtTouch';

var
  GAttachCounter: Cardinal = 0;
  GRelease:       Integer  = 0;

function BesideExecutable(const Name: string): string;
begin
  if ExtractFilePath(Name) <> '' then
    Exit(Name);
  Result := ExtractFilePath(ParamStr(0)) + Name;
end;

procedure WaitForRelease;
begin
  Writeln(Format('counter=%x release=%x', [NativeUInt(@GAttachCounter), NativeUInt(@GRelease)]));
  Flush(Output);
  var Deadline := GetTickCount64 + 30000;
  while GRelease = 0 do begin
    Inc(GAttachCounter);
    // GetTickCount64 reads shared memory: the loop makes no system call.
    if ((GAttachCounter and $FFFFF) = 0) and (GetTickCount64 > Deadline) then
      Break;
  end;
  Writeln('released: ', GRelease <> 0);
  Flush(Output);
end;

procedure LoadDynamicPackage(const FileName: string);
begin
  var Handle := LoadPackage(BesideExecutable(FileName));
  var Value: TValueFunction;
  @Value := GetProcAddress(Handle, 'LtPkgDynamicValue');
  if Assigned(Value) then
    Writeln('package ', ExtractFileName(FileName), ': ', Value(5))
  else
    Writeln('package ', ExtractFileName(FileName), ': loaded, no LtPkgDynamicValue');
  Flush(Output);
end;

procedure LoadDynamicLibrary(const FileName: string);
begin
  var Handle := LoadLibrary(PChar(BesideExecutable(FileName)));
  if Handle = 0 then begin
    Writeln('dll ', ExtractFileName(FileName), ': LoadLibrary failed, error ', GetLastError);
    Exit;
  end;
  var Touch: TTouchFunction;
  @Touch := GetProcAddress(Handle, 'LtTouch');
  if Assigned(Touch) then begin
    // Two statements: the order in which Writeln evaluates its arguments differs
    // between dcc32 and dcc64.
    var First := Touch(5);
    var Second := Touch(7);
    Writeln('dll ', ExtractFileName(FileName), ': ', First, ' ', Second);
  end
  else
    Writeln('dll ', ExtractFileName(FileName), ': loaded, no LtTouch');
  Flush(Output);
end;

begin
  LtAnnounce('main block begins');
  Writeln('host unit initialised: ', LtHostUnitInitialised);
  Writeln('static package: ', LtPkgStaticValue(3));
  Writeln('static dll: ', LtStaticTouch(3));
  Flush(Output);

  var Index := 1;
  if SameText(ParamStr(Index), '-wait') then begin
    WaitForRelease;
    Inc(Index);
  end;
  while Index < ParamCount do begin
    if SameText(ParamStr(Index), '-pkg') then
      LoadDynamicPackage(ParamStr(Index + 1))
    else if SameText(ParamStr(Index), '-dll') then
      LoadDynamicLibrary(ParamStr(Index + 1))
    else
      Writeln('unknown argument: ', ParamStr(Index));
    Inc(Index, 2);
  end;
  LtAnnounce('main block ends');
end.
