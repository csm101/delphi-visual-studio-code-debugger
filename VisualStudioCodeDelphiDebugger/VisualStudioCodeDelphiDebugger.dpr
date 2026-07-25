// JCL_DEBUG_EXPERT_GENERATEJDBG ON
program VisualStudioCodeDelphiDebugger;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Winapi.Windows,
  DapProtocol in '..\DebuggerCore\DapProtocol.pas',
  DebugInfoTypes in '..\DebuggerCore\DebugInfoTypes.pas',
  DebugInfoSet in '..\DebuggerCore\DebugInfoSet.pas',
  MapFileReader in '..\DebuggerCore\MapFileReader.pas',
  TD32FileReader in '..\DebuggerCore\TD32FileReader.pas',
  DebugSourceIndex in '..\DebuggerCore\DebugSourceIndex.pas',
  RsmFileReader in '..\DebuggerCore\RsmFileReader.pas',
  WinDebuggerBase in '..\DebuggerCore\WinDebuggerBase.pas',
  DelphiRtti in '..\DebuggerCore\DelphiRtti.pas',
  ProcessEnum in '..\DebuggerCore\ProcessEnum.pas',
  ProcessListJson in '..\DebuggerCore\ProcessListJson.pas',
  DapServer in 'DapServer.pas';

begin
  try
    // `--list-processes [name]` is a one-shot query used by the VS Code
    // extension's attach picker: print the process list as JSON, exit, and
    // never start the DAP loop (which would sit there waiting on stdin).
    // An unknown switch must not reach the DAP loop: that loop reads stdin and
    // waits, so a caller expecting a one-shot answer would hang rather than be
    // told it asked for something this build does not support.
    var UnknownSwitch: string;
    var ProcessNameFilter: string;
    if CommandLineHasUnrecognizedSwitch(UnknownSwitch) then begin
      raise Exception.CreateFmt(
        'unknown option "%s". Supported: %s [executable-name]; ' +
        'with no arguments the debug adapter serves DAP on stdin/stdout.',
        [UnknownSwitch, ProcessListSwitch]);
    end;
    if ProcessListRequested(ProcessNameFilter) then
      WriteProcessList(ProcessNameFilter)
    else
      RunDapServer;
  except
    on E: Exception do
    begin
      var ErrH := GetStdHandle(STD_ERROR_HANDLE);
      var Msg: AnsiString := AnsiString('Fatal: ' + E.Message + #13#10);
      var W: DWORD;
      WriteFile(ErrH, Msg[1], Length(Msg), W, nil);
      ExitCode := 1;
    end;
  end;
end.
