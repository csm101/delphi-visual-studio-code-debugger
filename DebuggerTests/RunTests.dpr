program RunTests;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  DUnitX.TestFramework,
  DUnitX.Filters,
  DUnitX.Extensibility,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.XML.NUnit,
  DebuggerTests   in 'DebuggerTests.pas',
  BugRegressionTests in 'BugRegressionTests.pas',
  DapClient       in 'DapClient.pas',
  RsmReaderTests  in 'RsmReaderTests.pas',
  TD32ReaderTests in 'TD32ReaderTests.pas',
  JclDebugReaderTests in 'JclDebugReaderTests.pas',
  MapReaderTests  in 'MapReaderTests.pas',
  X86DecodeTests  in 'X86DecodeTests.pas',
  RttiRobustnessTests in 'RttiRobustnessTests.pas',
  ExceptionRulesTests in 'ExceptionRulesTests.pas',
  ProcessListJsonTests in 'ProcessListJsonTests.pas',
  ProcessEnum     in '..\DebuggerCore\ProcessEnum.pas',
  ProcessListJson in '..\DebuggerCore\ProcessListJson.pas',
  DapProtocol     in '..\DebuggerCore\DapProtocol.pas',
  ExceptionRules  in '..\DebuggerCore\ExceptionRules.pas',
  RsmTags         in '..\DebuggerCore\RsmTags.pas',
  RsmDecoders     in '..\DebuggerCore\RsmDecoders.pas',
  RsmFileReader   in '..\DebuggerCore\RsmFileReader.pas',
  MapFileReader   in '..\DebuggerCore\MapFileReader.pas',
  TD32FileReader  in '..\DebuggerCore\TD32FileReader.pas',
  DebugInfoTypes  in '..\DebuggerCore\DebugInfoTypes.pas',
  DebugInfoSet    in '..\DebuggerCore\DebugInfoSet.pas',
  DebugTarget     in '..\DebuggerCore\DebugTarget.pas',
  DelphiRtti      in '..\DebuggerCore\DelphiRtti.pas',
  DelphiValueReaders in '..\DebuggerCore\DelphiValueReaders.pas',
  ExprEval        in '..\DebuggerCore\ExprEval.pas',
  X86Decode       in '..\DebuggerCore\X86Decode.pas',
  WinDebuggerBase in '..\DebuggerCore\WinDebuggerBase.pas',
  DebugSessionTypes in '..\DebuggerCore\DebugSessionTypes.pas',
  SourceResolver  in '..\DebuggerCore\SourceResolver.pas',
  DebugSession    in '..\DebuggerCore\DebugSession.pas',
  LaunchConfig    in '..\MCPDebugger\LaunchConfig.pas',
  DebugSessionTests in 'DebugSessionTests.pas',
  McpE2ETests     in 'McpE2ETests.pas',
  ValueReaderTests in 'ValueReaderTests.pas',
  Disassembler    in '..\DebuggerCore\Disassembler.pas',
  ZydisApi        in '..\DebuggerCore\ZydisApi.pas',
  ZydisDisassembler in '..\DebuggerCore\ZydisDisassembler.pas',
  DisassemblerTests in 'DisassemblerTests.pas';

type
  // Dev-iteration filter: when the RUNTESTS_ONLY env var is set, only tests
  // whose full name contains that (case-insensitive) substring run. Inert when
  // the var is empty -- the committed full-suite behavior is unchanged. Lets a
  // STEP-9-style edit be validated on a handful of tests in seconds instead of
  // the whole doubled suite. Set e.g. RUNTESTS_ONLY=Test_BP_Conditional, or
  // RUNTESTS_ONLY=Bpl to run every BPL-fixture test.
  TSubstringFilter = class(TInterfacedObject, ITestFilter)
  private
    FNeedle: string;
  public
    constructor Create(const ANeedle: string);
    function IsEmpty: Boolean;
    function Match(const Test: ITest): Boolean;
  end;

constructor TSubstringFilter.Create(const ANeedle: string);
begin
  inherited Create;
  FNeedle := LowerCase(ANeedle);
end;

function TSubstringFilter.IsEmpty: Boolean;
begin
  Result := FNeedle = '';
end;

function TSubstringFilter.Match(const Test: ITest): Boolean;
begin
  Result := (FNeedle = '') or (Pos(FNeedle, LowerCase(Test.FullName)) > 0);
end;

var
  Runner:  ITestRunner;
  Results: IRunResults;
  Logger:  ITestLogger;
  XmlLog:  ITestLogger;
  OnlyNeedle: string;
begin
  try
    TDUnitX.CheckCommandLine;
    Runner  := TDUnitX.CreateRunner;
    Runner.UseRTTI := True;

    Logger := TDUnitXConsoleLogger.Create(True);
    Runner.AddLogger(Logger);

    XmlLog := TDUnitXXMLNUnitFileLogger.Create(
      TDUnitX.Options.XMLOutputFile);
    Runner.AddLogger(XmlLog);

    OnlyNeedle := GetEnvironmentVariable('RUNTESTS_ONLY');
    if OnlyNeedle <> '' then begin
      TDUnitX.Filter := TSubstringFilter.Create(OnlyNeedle);
      Writeln('FILTER: only tests matching "', OnlyNeedle, '"');
    end;

    Results := Runner.Execute;

    if not Results.AllPassed then
      System.ExitCode := EXIT_ERRORS;
  except
    on E: Exception do begin
      Writeln('FATAL: ', E.Message);
      System.ExitCode := EXIT_ERRORS;
    end;
  end;
end.
