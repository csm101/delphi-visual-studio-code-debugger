unit ProcessListJson;

// Machine-readable process listing for the VS Code extension's attach picker.
//
// The picker used to shell out to `tasklist /FO CSV`. That was the wrong source
// on three counts:
//
//   * its output is localized - the "N/A" placeholder is "N/D" on an Italian
//     Windows, and parsing fixed column positions out of a translated table is
//     a latent bug on every non-English machine;
//   * it cannot report a process's architecture, so the picker could offer a
//     32-bit process that attaching is guaranteed to fail on;
//   * it does not expose the command line, which is what actually tells two
//     instances of the same application apart.
//
// The adapter already links ProcessEnum, which answers all three from the Win32
// APIs. `--list-processes [name]` prints that answer as a single line of JSON on
// stdout and exits, without starting the DAP loop.
//
// Output: one line, one JSON array, one object per process:
//   [{"pid":7788,"parentPid":16692,"sessionId":1,"name":"SampleApp.exe",
//     "path":"C:\\...\\SampleApp.exe","commandLine":"...",
//     "windowTitle":"SampleApp - Customers","arch":"x64",
//     "canDebug":true,"reason":""}]
//
// `windowTitle` is the caption of the process's front-most visible top-level
// window, '' when it has none. Two instances of one application share a name, an
// image path and often a command line; the caption is usually what tells them
// apart on screen.
//
// Strictly line-oriented so a reader can pick the JSON out by itself even if
// something else ever writes to this stdout, and UTF-8 regardless of the
// console code page, so non-ASCII paths survive.

interface

uses
  ProcessEnum;

const
  ProcessListSwitch = '--list-processes';
  // Withdraws `supportsReadMemoryRequest` / `supportsWriteMemoryRequest` from
  // the `initialize` response, which is what removes the EDITOR's built-in
  // memory pane; the requests themselves keep being served. Passed by the VS
  // Code extension, which ships its own memory view. A command-line switch
  // because `initialize` is answered before any launch configuration exists.
  // Declared here, beside the other one, because this is the unit that decides
  // which switches this program understands -- a switch known to the DAP layer
  // but not to that check is rejected as unknown before the DAP layer ever runs.
  NoStockMemoryViewSwitch = '--no-stock-memory-view';

// True when these arguments ask for the listing. NameFilter is the optional
// value that follows the switch; '' means every process.
function ParseProcessListArgs(const Args: TArray<string>; out NameFilter: string): Boolean;

// The same, against this process's own command line.
function ProcessListRequested(out NameFilter: string): Boolean;

// True when the arguments carry a switch this program does not understand.
//
// Worth a check of its own because of how it fails otherwise: an unrecognized
// switch used to fall straight through to the DAP loop, which reads stdin and
// waits. A caller that expected a one-shot answer gets no output and no error,
// just a process that never returns. That is precisely what an adapter built
// before `--list-processes` existed did to the extension's attach picker - it
// hung until the picker's own timeout, and the diagnosis pointed everywhere but
// at a stale binary.
function UnrecognizedSwitch(const Args: TArray<string>; out Switch: string): Boolean;

// The same, against this process's own command line.
function CommandLineHasUnrecognizedSwitch(out Switch: string): Boolean;

function BuildProcessListJson(const Processes: TArray<TProcessInfo>): string;

// Enumerates, then writes the JSON line to stdout as UTF-8.
procedure WriteProcessList(const NameFilter: string);

implementation

uses
  System.SysUtils, System.JSON, Winapi.Windows;

function ParseProcessListArgs(const Args: TArray<string>; out NameFilter: string): Boolean;
begin
  NameFilter := '';
  for var Index := 0 to High(Args) do begin
    if not SameText(Args[Index], ProcessListSwitch) then
      Continue;
    // The filter is the next argument, unless that is another switch.
    if (Index < High(Args)) and not Args[Index + 1].StartsWith('-') then
      NameFilter := Args[Index + 1];
    Exit(True);
  end;
  Result := False;
end;

function OwnCommandLineArgs: TArray<string>;
begin
  SetLength(Result, ParamCount);
  for var Index := 1 to ParamCount do
    Result[Index - 1] := ParamStr(Index);
end;

function ProcessListRequested(out NameFilter: string): Boolean;
begin
  Result := ParseProcessListArgs(OwnCommandLineArgs, NameFilter);
end;

function UnrecognizedSwitch(const Args: TArray<string>; out Switch: string): Boolean;
begin
  Switch := '';
  for var Index := 0 to High(Args) do begin
    if not Args[Index].StartsWith('-') then
      Continue;
    if SameText(Args[Index], ProcessListSwitch) or
       SameText(Args[Index], NoStockMemoryViewSwitch) then
      Continue;
    // A negative number is a value, not a switch; the only operand this program
    // takes is the listing's name filter, and that never starts with '-'.
    Switch := Args[Index];
    Exit(True);
  end;
  Result := False;
end;

function CommandLineHasUnrecognizedSwitch(out Switch: string): Boolean;
begin
  Result := UnrecognizedSwitch(OwnCommandLineArgs, Switch);
end;

function ProcessToJson(const Info: TProcessInfo): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('pid', TJSONNumber.Create(Info.Pid));
  Result.AddPair('parentPid', TJSONNumber.Create(Info.ParentPid));
  Result.AddPair('sessionId', TJSONNumber.Create(Info.SessionId));
  Result.AddPair('name', Info.ExeName);
  Result.AddPair('path', Info.ExePath);
  Result.AddPair('commandLine', Info.CommandLine);
  Result.AddPair('windowTitle', Info.MainWindowTitle);
  // Local time, and the last resort for telling instances apart: two copies of
  // one application can share a name, a path, a command line AND a window
  // caption - "the one I started first" is then the only distinction left.
  // Invariant settings on purpose: ':' in a format picture is replaced by the
  // locale's time separator, so the reader would see a different shape on a
  // machine configured differently. The picker prints this verbatim.
  if Info.StartTime > 0 then
    Result.AddPair('startTime',
      FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Info.StartTime, TFormatSettings.Invariant))
  else
    Result.AddPair('startTime', '');
  Result.AddPair('arch', ArchToStr(Info.Arch));

  var Reason: string;
  var Debuggable := CanDebug(Info, Reason);
  Result.AddPair('canDebug', TJSONBool.Create(Debuggable));
  Result.AddPair('reason', Reason);
end;

function BuildProcessListJson(const Processes: TArray<TProcessInfo>): string;
begin
  var Items := TJSONArray.Create;
  try
    for var Info in Processes do
      Items.Add(ProcessToJson(Info));
    // ToJSON escapes control characters, so no value can break the single line.
    Result := Items.ToJSON;
  finally
    Items.Free;
  end;
end;

procedure WriteStdOutLine(const Line: string);
begin
  var Bytes := TEncoding.UTF8.GetBytes(Line + #10);
  if Length(Bytes) = 0 then
    Exit;
  var Written: DWORD := 0;
  WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), Bytes[0], Length(Bytes), Written, nil);
end;

procedure WriteProcessList(const NameFilter: string);
begin
  var Processes := EnumerateProcesses(NameFilter);
  AttachMainWindowTitles(Processes);
  WriteStdOutLine(BuildProcessListJson(Processes));
end;

end.
