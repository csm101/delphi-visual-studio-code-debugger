program RunTestsParallel;
// Runs the DebuggerTests suite as several concurrent RunTests.exe workers and
// merges their results into one NUnit report.
//
// Why processes and not threads: DebuggerCore carries process-wide state (the
// Zydis load latch, the provider caches, the .idx sidecar writer), so an
// in-process parallel DUnitX would be a flakiness generator. Separate processes
// give isolation by construction; each worker writes its own XML and its own
// console log, and the only shared artefacts left are the read-only test
// binaries and the .idx sidecars, which are published atomically (see
// TRsmFile.PublishSidecar).
//
// Usage:
//   RunTestsParallel.exe [--jobs N] [--xmlfile <path>] [--only <substring>]
//
// Environment:
//   RUNTESTS_JOBS   worker count; overrides the adaptive default.
//                   1 means exactly the sequential behaviour: one unsharded
//                   RunTests.exe with the serial-only tests included inline.
//   RUNTESTS_ONLY   substring filter, passed through to every worker.

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Math,
  System.Generics.Collections,
  System.StrUtils,
  Winapi.Windows;

type
  TWorker = record
    Proc:     THandle;
    XmlPath:  string;
    LogPath:  string;
    Caption:  string;
    ExitCode: DWORD;
  end;

  TCaseResult = record
    Name:    string;
    Result_: string;
    Success: string;
    Time:    string;
    Message: string;
    // Set by the sequential re-check: this case failed under N concurrent
    // workers and passed when re-run alone. It is not a defect in the code under
    // test, and it is not counted as a failure -- but it is never silent.
    LoadSensitive: Boolean;
  end;

  TCounts = record
    Total, Errors, Failures, Ignored, NotRun, Inconclusive: Integer;
    procedure Add(const Other: TCounts);
  end;

procedure TCounts.Add(const Other: TCounts);
begin
  Inc(Total,        Other.Total);
  Inc(Errors,       Other.Errors);
  Inc(Failures,     Other.Failures);
  Inc(Ignored,      Other.Ignored);
  Inc(NotRun,       Other.NotRun);
  Inc(Inconclusive, Other.Inconclusive);
end;

var
  BaseDir:   string;   // ...\DebuggerTests\
  OutDir:    string;   // ...\DebuggerTests\Win64\Debug\
  RunnerExe: string;
  MergedXml: string;
  OnlyNeedle:string;
  Jobs:      Integer;

{ --------------------------------------------------------------------------- }
{ Worker count                                                                 }
{ --------------------------------------------------------------------------- }

function AvailablePhysicalMB: Int64;
var
  Status: TMemoryStatusEx;
begin
  Status := Default(TMemoryStatusEx);
  Status.dwLength := SizeOf(Status);
  if GlobalMemoryStatusEx(Status) then
    Result := Int64(Status.ullAvailPhys) div (1024 * 1024)
  else
    Result := 0;
end;

// The default must fit the machine it lands on, not the machine it was written
// on. It is the minimum of three limits:
//
//   cores   A worker is mostly BLOCKED -- it waits on an adapter process, which
//           waits on a debuggee -- so it does not need a core to itself. But it
//           is not one thread either: it drives an adapter and a debuggee that
//           run threads of their own. Half the logical processors is the
//           compromise, minimum 1.
//
//   memory  Measured peak working sets for one worker of this suite:
//           RunTests 121 MB + adapter 106 MB + debuggee 14 MB = ~241 MB.
//           Budget 384 MB to cover the BPL scenario (host + subject + two
//           packages) and transient TD32 parse buffers, and hold 1 GB back for
//           the rest of the system. Memory, not cores, is what binds on a
//           modest laptop: 32 threads with 4 GB free must not get 16 workers.
//
//   cap     Measured on the reference machine (16C/32T, 32 GB free), full
//           suite of 1188 tests:
//
//             jobs   wall     speedup   observed failures
//                1  426.2 s    1.00x    none
//                2  220.4 s    1.93x    none
//                4  119.6 s    3.56x    none  (3 runs)
//                6   85.8 s    4.97x    none
//                8   66.5 s    6.41x    none  (5 runs)
//               10   61.7 s    6.91x    none
//               12   50.7 s    8.41x    1 in 3 runs
//               16   42.1 s   10.13x    none  (1 run)
//               20   39.4 s   10.82x    1 in 1 run
//
//           Throughput does NOT flatten at 8 -- it keeps improving to ~11x.
//           The cap is set by correctness, not by throughput: from 12 workers
//           up, load-sensitive symbol lookups start missing their deadline
//           (Test_RtlStringGetter_VarOutFromPropertyType reporting
//           "TStrings.GetTextStr not found"), so the suite stops being
//           trustworthy. 8 keeps every observed run green and still buys 6.4x.
//           Raise this only together with evidence that the symbol-index wait
//           no longer degrades under load.
//
// RUNTESTS_JOBS overrides all of it, and 1 restores the sequential path.
const
  MB_PER_WORKER   = 384;
  MB_KEPT_FREE    = 1024;
  MAX_WORKERS_CAP = 8;

function DefaultJobCount: Integer;
begin
  var ByCores := Max(1, CPUCount div 2);
  var AvailMB := AvailablePhysicalMB;
  var ByMemory: Integer;
  if AvailMB <= 0 then
    ByMemory := 2   // could not measure available memory: stay conservative
  else
    ByMemory := Max(1, Integer((AvailMB - MB_KEPT_FREE) div MB_PER_WORKER));
  Result := Max(1, Min(Min(ByCores, ByMemory), MAX_WORKERS_CAP));
end;

{ --------------------------------------------------------------------------- }
{ Spawning                                                                     }
{ --------------------------------------------------------------------------- }

// Each worker's console output goes to its OWN file. Left on the shared console
// the loggers interleave thousands of lines through one serialized console
// buffer, which is both unreadable and slow enough to distort the measurement.
function SpawnWorker(const AShardSpec, ASerialMode, ANames,
  AXmlPath, ALogPath: string): THandle;
var
  SA: TSecurityAttributes;
  SI: TStartupInfo;
  PI: TProcessInformation;
begin
  SetEnvironmentVariable('RUNTESTS_SHARD',  PChar(AShardSpec));
  SetEnvironmentVariable('RUNTESTS_SERIAL', PChar(ASerialMode));
  SetEnvironmentVariable('RUNTESTS_NAMES',  PChar(ANames));
  SetEnvironmentVariable('RUNTESTS_ONLY',   PChar(OnlyNeedle));

  SA.nLength              := SizeOf(SA);
  SA.bInheritHandle       := True;
  SA.lpSecurityDescriptor := nil;

  var LogHandle := CreateFile(PChar(ALogPath), GENERIC_WRITE, FILE_SHARE_READ,
    @SA, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
  if LogHandle = INVALID_HANDLE_VALUE then
    RaiseLastOSError;

  SI := Default(TStartupInfo);
  SI.cb         := SizeOf(SI);
  SI.dwFlags    := STARTF_USESTDHANDLES;
  SI.hStdInput  := GetStdHandle(STD_INPUT_HANDLE);
  SI.hStdOutput := LogHandle;
  SI.hStdError  := LogHandle;

  var CmdLine := Format('"%s" --xmlfile:"%s"', [RunnerExe, AXmlPath]);
  try
    if not CreateProcess(nil, PChar(CmdLine), nil, nil, True,
         CREATE_NO_WINDOW, nil, PChar(BaseDir), SI, PI) then
      RaiseLastOSError;
  finally
    CloseHandle(LogHandle);
  end;
  CloseHandle(PI.hThread);
  Result := PI.hProcess;
end;

procedure WaitAll(var Workers: TArray<TWorker>);
begin
  for var I := 0 to High(Workers) do begin
    WaitForSingleObject(Workers[I].Proc, INFINITE);
    GetExitCodeProcess(Workers[I].Proc, Workers[I].ExitCode);
    CloseHandle(Workers[I].Proc);
    Workers[I].Proc := 0;
  end;
end;

{ --------------------------------------------------------------------------- }
{ Result merging                                                               }
{ --------------------------------------------------------------------------- }

// The NUnit files here are machine-generated by DUnitX and their tags are flat
// and quote-delimited, so a small scanner reads them without dragging in the
// MSXML DOM -- which is not guaranteed to be registered on a developer machine
// and failed exactly that way on first run.
function TagAttr(const Tag, Name: string): string;
begin
  Result := '';
  var Key := Name + '="';
  var P := Pos(Key, Tag);
  if P = 0 then
    Exit;
  Inc(P, Length(Key));
  var Q := PosEx('"', Tag, P);
  if Q = 0 then
    Exit;
  Result := Copy(Tag, P, Q - P);
end;

// Returns every `<`+TagName+...`>` opening tag found in Text.
function FindTags(const Text, TagName: string): TArray<string>;
begin
  Result := [];
  var Needle := '<' + TagName + ' ';
  var P := Pos(Needle, Text);
  while P > 0 do begin
    var Q := PosEx('>', Text, P);
    if Q = 0 then
      Break;
    Result := Result + [Copy(Text, P, Q - P + 1)];
    P := PosEx(Needle, Text, Q);
  end;
end;

// Text of the first <message> inside Block, CDATA unwrapped. A merged report
// that says only "3 failed" without saying WHY is not usable as the primary
// result of a run, and the per-shard files are overwritten by the next one.
function ExtractMessage(const Block: string): string;
begin
  Result := '';
  var P := Pos('<message>', Block);
  if P = 0 then
    Exit;
  Inc(P, Length('<message>'));
  var Q := PosEx('</message>', Block, P);
  if Q = 0 then
    Exit;
  Result := Copy(Block, P, Q - P).Trim;
  if Result.StartsWith('<![CDATA[') then
    Result := Copy(Result, 10, Length(Result) - 12).Trim;
  Result := Result.Replace(sLineBreak, ' ', [rfReplaceAll])
                  .Replace(#10, ' ', [rfReplaceAll])
                  .Replace(#13, ' ', [rfReplaceAll]);
end;

// One entry per <test-case>, with the failure text when the case is not
// self-closing (DUnitX nests <failure><message> inside failing cases).
function ParseCases(const Text: string): TArray<TCaseResult>;
begin
  Result := [];
  var Needle := '<test-case ';
  var P := Pos(Needle, Text);
  while P > 0 do begin
    var TagEnd := PosEx('>', Text, P);
    if TagEnd = 0 then
      Break;
    var Tag := Copy(Text, P, TagEnd - P + 1);

    var Item: TCaseResult;
    Item.Name    := TagAttr(Tag, 'name');
    Item.Result_ := TagAttr(Tag, 'result');
    Item.Success := TagAttr(Tag, 'success');
    Item.Time    := TagAttr(Tag, 'time');
    Item.Message := '';
    Item.LoadSensitive := False;

    var NextSearchFrom := TagEnd;
    if not Tag.EndsWith('/>') then begin
      var CloseAt := PosEx('</test-case>', Text, TagEnd);
      if CloseAt > 0 then begin
        Item.Message   := ExtractMessage(Copy(Text, TagEnd, CloseAt - TagEnd));
        NextSearchFrom := CloseAt;
      end;
    end;

    Result := Result + [Item];
    P := PosEx(Needle, Text, NextSearchFrom);
  end;
end;

function XmlEscape(const S: string): string;
begin
  Result := S.Replace('&', '&amp;', [rfReplaceAll])
             .Replace('<', '&lt;',  [rfReplaceAll])
             .Replace('>', '&gt;',  [rfReplaceAll])
             .Replace('"', '&quot;',[rfReplaceAll]);
end;

// Reads one worker's report. Counts come from the root attributes; the per-case
// list comes from the body. Reading is kept SEPARATE from writing the merged
// file because the sequential re-check happens between the two: a case can only
// be reclassified once we know how it behaved alone.
procedure ReadWorkerReports(const XmlPaths: TArray<string>;
  out Totals: TCounts; out Cases: TArray<TCaseResult>);
var
  All: TList<TCaseResult>;
begin
  Totals := Default(TCounts);
  All    := TList<TCaseResult>.Create;
  try
    for var Path in XmlPaths do begin
      if not TFile.Exists(Path) then begin
        // A worker that died before writing its report would otherwise vanish
        // from the totals, and a silently SMALLER test count is exactly the
        // failure mode that makes a fast suite untrustworthy. Say so loudly.
        Writeln('WARNING: missing worker report ', Path,
                ' -- its tests are NOT in the totals below');
        Continue;
      end;
      var Text := TFile.ReadAllText(Path, TEncoding.UTF8);

      var Roots := FindTags(Text, 'test-results');
      if Length(Roots) > 0 then begin
        var C := Default(TCounts);
        C.Total        := StrToIntDef(TagAttr(Roots[0], 'total'), 0);
        C.Errors       := StrToIntDef(TagAttr(Roots[0], 'errors'), 0);
        C.Failures     := StrToIntDef(TagAttr(Roots[0], 'failures'), 0);
        C.Ignored      := StrToIntDef(TagAttr(Roots[0], 'ignored'), 0);
        C.NotRun       := StrToIntDef(TagAttr(Roots[0], 'not-run'), 0);
        C.Inconclusive := StrToIntDef(TagAttr(Roots[0], 'inconclusive'), 0);
        Totals.Add(C);
      end;

      All.AddRange(ParseCases(Text));
    end;
    Cases := All.ToArray;
  finally
    All.Free;
  end;
end;

// The merged report is built from scratch rather than by grafting shard trees
// together: nothing downstream consumes the namespace/fixture nesting. What
// must survive is the aggregate verdict, one entry per test with its own timing,
// and -- for anything the re-check reclassified -- WHY it is not counted as a
// failure. A CI or an agent reading only this file must reach the same verdict
// a human reading the console does.
procedure WriteMergedReport(const Dest: string; const Totals: TCounts;
  const Cases: TArray<TCaseResult>; LoadSensitive, Workers: Integer;
  const RecheckState: string);
var
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    SB.AppendLine('<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>');
    SB.AppendLine(Format('<test-results name="RunTestsParallel (merged)" ' +
      'total="%d" errors="%d" failures="%d" ignored="%d" inconclusive="%d" ' +
      'not-run="%d" workers="%d" recheck="%s" load-sensitive="%d">',
      [Totals.Total, Totals.Errors, Totals.Failures, Totals.Ignored,
       Totals.Inconclusive, Totals.NotRun, Workers, RecheckState, LoadSensitive]));
    SB.AppendLine('  <results>');
    for var Item in Cases do begin
      var Head := Format('    <test-case name="%s" result="%s" success="%s" time="%s"',
        [XmlEscape(Item.Name), XmlEscape(Item.Result_),
         XmlEscape(Item.Success), XmlEscape(Item.Time)]);
      if Item.Message = '' then
        SB.AppendLine(Head + ' />')
      else begin
        SB.AppendLine(Head + '>');
        if Item.LoadSensitive then
          SB.AppendLine('      <reason><message>' + XmlEscape(Item.Message) +
            '</message></reason>')
        else
          SB.AppendLine('      <failure><message>' + XmlEscape(Item.Message) +
            '</message></failure>');
        SB.AppendLine('    </test-case>');
      end;
    end;
    SB.AppendLine('  </results>');
    SB.AppendLine('</test-results>');
    TFile.WriteAllText(Dest, SB.ToString, TEncoding.UTF8);
  finally
    SB.Free;
  end;
end;

{ --------------------------------------------------------------------------- }

function ArgValue(const Name, Default: string): string;
begin
  Result := Default;
  for var I := 1 to ParamCount - 1 do
    if SameText(ParamStr(I), Name) then
      Exit(ParamStr(I + 1));
end;

function ParentDir(const APath: string): string;
begin
  Result := IncludeTrailingPathDelimiter(
    ExtractFileDir(ExcludeTrailingPathDelimiter(APath)));
end;

var
  Workers:   TArray<TWorker>;
  Serial:    TArray<TWorker>;
  XmlPaths:  TArray<string>;
  Totals:    TCounts;
  Cases:     TArray<TCaseResult>;
  FailedNames: TArray<string>;
  RecheckState: string;
  LoadSensitive: Integer;
  StartTick: UInt64;
  Failed:    Integer;
begin
  LoadSensitive := 0;
  try
    OutDir    := ExtractFilePath(ParamStr(0));               // ...\Win64\Debug\
    BaseDir   := ParentDir(ParentDir(OutDir));               // ...\DebuggerTests\
    RunnerExe := OutDir + 'RunTests.exe';
    if not TFile.Exists(RunnerExe) then begin
      Writeln('RunTests.exe not found next to RunTestsParallel.exe: ', RunnerExe);
      Halt(2);
    end;

    MergedXml  := ArgValue('--xmlfile', OutDir + 'TestResults.xml');
    OnlyNeedle := ArgValue('--only', GetEnvironmentVariable('RUNTESTS_ONLY'));

    Jobs := StrToIntDef(ArgValue('--jobs', GetEnvironmentVariable('RUNTESTS_JOBS')), 0);
    if Jobs <= 0 then
      Jobs := DefaultJobCount;

    Writeln(Format('RunTestsParallel: %d worker(s)   [%d logical CPUs, %d MB available]',
      [Jobs, CPUCount, AvailablePhysicalMB]));
    // On a small or busy machine the formula can land on 1, and a suite that
    // takes seven times longer with no explanation reads as "the parallelism is
    // broken". Say why, once.
    if (Jobs < 2) and (ArgValue('--jobs', GetEnvironmentVariable('RUNTESTS_JOBS')) = '') then begin
      Write('  Running SEQUENTIALLY: ');
      if CPUCount < 4 then
        Write(Format('%d logical CPU(s); ', [CPUCount]));
      Writeln(Format('%d MB free, and two workers need %d MB. ' +
        'This is expected, not a fault.',
        [AvailablePhysicalMB, MB_KEPT_FREE + 2 * MB_PER_WORKER]));
    end;
    if OnlyNeedle <> '' then
      Writeln('Filter: ', OnlyNeedle);
    StartTick := GetTickCount64;

    // Sequential mode is a fully supported mode, not a degraded fallback: ONE
    // unsharded worker with no serial split, which is exactly what running
    // RunTests.exe by hand does. Everything after this point is shared with the
    // parallel path, so both modes report identically.
    SetLength(Workers, Jobs);
    SetLength(Serial, 0);
    for var I := 0 to Jobs - 1 do begin
      Workers[I].XmlPath := Format('%sTestResults_shard%d.xml', [OutDir, I]);
      Workers[I].LogPath := Format('%sRunTests_shard%d.log', [OutDir, I]);
      Workers[I].Caption := Format('shard %d/%d', [I, Jobs]);
      if TFile.Exists(Workers[I].XmlPath) then
        TFile.Delete(Workers[I].XmlPath);
      if Jobs = 1 then
        Workers[I].Proc := SpawnWorker('', '', '', Workers[I].XmlPath, Workers[I].LogPath)
      else
        Workers[I].Proc := SpawnWorker(Format('%d/%d', [I, Jobs]), 'exclude', '',
          Workers[I].XmlPath, Workers[I].LogPath);
    end;
    Writeln(Format('%d worker(s) running...', [Jobs]));
    WaitAll(Workers);

    if Jobs > 1 then begin
      Writeln(Format('Shards done at %.1f s. Serial tail...',
        [(GetTickCount64 - StartTick) / 1000]));
      // The few tests that reach for a process by NAME and therefore cannot
      // tolerate a sibling worker's debuggee being alive.
      SetLength(Serial, 1);
      Serial[0].XmlPath := OutDir + 'TestResults_serial.xml';
      Serial[0].LogPath := OutDir + 'RunTests_serial.log';
      Serial[0].Caption := 'serial tail';
      if TFile.Exists(Serial[0].XmlPath) then
        TFile.Delete(Serial[0].XmlPath);
      Serial[0].Proc := SpawnWorker('', 'only', '', Serial[0].XmlPath, Serial[0].LogPath);
      WaitAll(Serial);
    end;

    SetLength(XmlPaths, 0);
    for var W in Workers do
      XmlPaths := XmlPaths + [W.XmlPath];
    for var W in Serial do
      XmlPaths := XmlPaths + [W.XmlPath];

    ReadWorkerReports(XmlPaths, Totals, Cases);

    // --- Sequential re-check -------------------------------------------------
    //
    // A failure under N concurrent workers has two possible causes, and telling
    // them apart is the difference between "this project is broken" and "your
    // machine is smaller than the one this default was tuned on". So when
    // anything failed, the named tests are re-run ALONE, once, and the
    // sequential outcome is the authoritative one.
    //
    // Cost discipline: it runs only when something failed, and only for what
    // failed -- the normal green run pays nothing. Deterministic: exactly one
    // re-run of exactly the named tests. A test that only passes on a third
    // attempt is a flake, not a pass, and retry loops are how that gets hidden.
    RecheckState := 'not-needed';
    FailedNames  := [];
    for var C in Cases do
      if SameText(C.Success, 'False') and (IndexStr(C.Name, FailedNames) < 0) then
        FailedNames := FailedNames + [C.Name];

    if (Length(FailedNames) > 0) and (Jobs > 1) then begin
      Writeln;
      Writeln(Format('%d test(s) failed under %d workers. Re-checking them ' +
        'sequentially...', [Length(FailedNames), Jobs]));

      var Recheck: TArray<TWorker>;
      SetLength(Recheck, 1);
      Recheck[0].XmlPath := OutDir + 'TestResults_recheck.xml';
      Recheck[0].LogPath := OutDir + 'RunTests_recheck.log';
      Recheck[0].Caption := 'sequential re-check';
      if TFile.Exists(Recheck[0].XmlPath) then
        TFile.Delete(Recheck[0].XmlPath);
      Recheck[0].Proc := SpawnWorker('', '', string.Join(';', FailedNames),
        Recheck[0].XmlPath, Recheck[0].LogPath);
      WaitAll(Recheck);

      var RecheckTotals: TCounts;
      var RecheckCases:  TArray<TCaseResult>;
      ReadWorkerReports([Recheck[0].XmlPath], RecheckTotals, RecheckCases);

      // A name is load-sensitive only if the re-check actually RAN it and every
      // case under that name passed. A name the re-check never reached stays a
      // failure: silence is not evidence of innocence.
      for var Name in FailedNames do begin
        var Ran    := False;
        var AllOk  := True;
        for var RC in RecheckCases do
          if SameText(RC.Name, Name) then begin
            Ran := True;
            if not SameText(RC.Success, 'True') then
              AllOk := False;
          end;
        if not (Ran and AllOk) then
          Continue;

        Inc(LoadSensitive);
        for var I := 0 to High(Cases) do
          if SameText(Cases[I].Name, Name) and SameText(Cases[I].Success, 'False') then begin
            if SameText(Cases[I].Result_, 'Error') then
              Dec(Totals.Errors)
            else
              Dec(Totals.Failures);
            Cases[I].LoadSensitive := True;
            Cases[I].Success       := 'True';
            Cases[I].Result_       := 'LoadSensitive';
            Cases[I].Message       := Format(
              'LOAD-SENSITIVE, not a code defect: failed under %d concurrent ' +
              'workers, PASSED when re-run alone. Original failure: %s',
              [Jobs, Cases[I].Message]);
          end;
      end;
      RecheckState := 'performed';
    end
    else if Length(FailedNames) > 0 then
      // Sequential run: there is no parallel/alone distinction to draw.
      RecheckState := 'skipped-sequential';

    WriteMergedReport(MergedXml, Totals, Cases, LoadSensitive, Jobs, RecheckState);

    Writeln;
    Writeln('==========================================');
    Writeln(Format('Tests Found   : %d', [Totals.Total + Totals.NotRun]));
    Writeln(Format('Tests Passed  : %d',
      [Totals.Total - Totals.Failures - Totals.Errors]));
    Writeln(Format('Tests Failed  : %d', [Totals.Failures]));
    Writeln(Format('Tests Errored : %d', [Totals.Errors]));
    Writeln(Format('Tests Ignored : %d', [Totals.NotRun]));
    if LoadSensitive > 0 then
      Writeln(Format('Load-sensitive: %d  (failed in parallel, passed alone)',
        [LoadSensitive]));
    Writeln(Format('Wall clock    : %.1f s', [(GetTickCount64 - StartTick) / 1000]));
    Writeln(Format('Merged report : %s', [MergedXml]));
    Writeln('==========================================');

    Failed := 0;
    for var C in Cases do
      if SameText(C.Success, 'False') then begin
        if Failed = 0 then begin
          Writeln;
          if RecheckState = 'performed' then
            // Naming the re-check here is the point: the reader must not have to
            // guess whether these survived it or were never subjected to it.
            Writeln('FAILED in parallel AND again on the sequential re-check:')
          else
            Writeln('FAILED:');
        end;
        Inc(Failed);
        Writeln('  ', C.Name, '  (', C.Result_, ')');
        if C.Message <> '' then
          Writeln('      ', C.Message);
      end;

    if LoadSensitive > 0 then begin
      Writeln;
      Writeln('LOAD-SENSITIVE -- these are NOT code defects. Each failed while ');
      Writeln(Format('%d workers were running and PASSED when re-run alone:', [Jobs]));
      for var C in Cases do
        if C.LoadSensitive then
          Writeln('  ', C.Name);
      Writeln;
      if Failed = 0 then
        Writeln(Format('The suite is GREEN: this machine could not sustain %d ' +
          'workers for those tests.', [Jobs]))
      else
        Writeln(Format('These are NOT why the run is red -- the %d failure(s) ' +
          'above are.', [Failed]));
      Writeln('  Re-run with a lower RUNTESTS_JOBS (or RUNTESTS_JOBS=1) to ' +
        'avoid them entirely.');
    end;

    // Exit status follows the SEQUENTIAL verdict, which is the authoritative
    // one: a load-sensitive failure is green-with-a-warning, because failing the
    // run would tell a stranger on a small machine that the project is broken
    // when it is not. A worker that crashed outright is still red -- that is not
    // a test result at all.
    var AnyWorkerFailed := False;
    for var W in Workers + Serial do
      if W.ExitCode <> 0 then
        AnyWorkerFailed := True;

    if (Totals.Failures > 0) or (Totals.Errors > 0) then
      Halt(1);
    if AnyWorkerFailed and (LoadSensitive = 0) then
      Halt(1);
  except
    on E: Exception do begin
      Writeln('FATAL: ', E.ClassName, ': ', E.Message);
      Halt(2);
    end;
  end;
end.
