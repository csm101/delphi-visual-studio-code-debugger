program LineProbeCost;

{$APPTYPE CONSOLE}

// What the one-shot line probes cost (docs/PROFILER_COVERAGE_PLAN.md,
// increment 5; DebuggerCore\CodePatchMap.pas, DebuggerCore\LineProbes.pas):
// how many line records of a binary would carry one, what deciding that costs,
// what arming them costs, and what one first hit costs a running program.
//
//   LineProbeCost -file <exe-or-bpl> [-map <file.map>] [-zydis <Zydis.dll>]
//     Nothing is launched. Reads the binary's TD32 (and the MAP, which on a
//     32-bit image names the bodies of anonymous methods), runs the routine
//     analysis the session runs over every line record -- the same call,
//     TLiveCodeAnalysis.ConfirmedLineRecords, over the file -- and arms the
//     confirmed records in a TCodePatchMap whose "target" is the file: the
//     reads are real, the writes are counted and dropped. Reports the records
//     that would be armed, the verdict time, the runs and write calls arming
//     would make, the bytes and pages they would cover, and the map's lookup
//     cost per hit.
//
//   LineProbeCost -live [-n <reps>] [-timeout <s>] <exe> [args...]
//     Runs the program to its end under a TDebugSession, alternately without
//     probes and with every confirmed line record of the executable armed at
//     the entry stop. The difference of the median run times divided by the
//     number of hits is the cost of one first hit. Also reports what arming
//     took (analysis, writes).
//
//   LineProbeCost -synthetic <stride> <exe> [args...]
//     Measures the WRITES alone at a scale no fixture has: stops the program
//     at its entry point, arms a probe every <stride> bytes of every
//     executable section of the executable through ICodePatchTarget (the
//     addresses are not instruction boundaries -- the program never runs
//     again), takes them all away, and kills the program.
//
// Every target-starting mode sets the error mode first, so a target that
// crashes produces no window (CLAUDE.md, "A test never opens a dialog").
// Set DAP_LOG=0 before measuring: the engine's log costs more than a hit.

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.Diagnostics,
  System.Math,
  System.Generics.Collections,
  System.Generics.Defaults,
  DebugInfoTypes,
  DebugTarget,
  DebugSessionTypes,
  DebugSession,
  TD32FileReader,
  MapFileReader,
  CodeMap,
  ZydisDisassembler,
  PeImageFile,
  LiveCodeAnalysis,
  CodePatchMap,
  LineProbes;

const
  IMAGE_SCN_MEM_EXECUTE = $20000000;
  PAGE_BYTES = $1000;

type
  TMode = (tmNone, tmFile, tmLive, tmSynthetic);

  TOptions = record
    Mode:       TMode;
    BinaryPath: string;
    MapPath:    string;
    ZydisDll:   string;
    Reps:       Integer;
    TimeoutSec: Integer;
    Stride:     Integer;
    Args:       string;
  end;

procedure PrintUsage;
begin
  Writeln('Usage: LineProbeCost -file <exe-or-bpl> [-map <file.map>] [-zydis <Zydis.dll>]');
  Writeln('       LineProbeCost -live [-n <reps>] [-timeout <s>] <exe> [args...]');
  Writeln('       LineProbeCost -synthetic <stride> <exe> [args...]');
end;

function QuoteArg(const Arg: string): string;
begin
  Result := Arg;
  if Arg.Contains(' ') then
    Result := '"' + Arg + '"';
end;

function ParseOptions(out Options: TOptions): Boolean;
begin
  Options := Default(TOptions);
  Options.Reps       := 5;
  Options.TimeoutSec := 60;
  var I := 1;
  while I <= ParamCount do begin
    var Arg := ParamStr(I);
    var HasValue := I < ParamCount;
    if (Options.BinaryPath <> '') and (Options.Mode in [tmLive, tmSynthetic]) then begin
      // Everything after a program that is started is the program's.
      Options.Args := (Options.Args + ' ' + QuoteArg(Arg)).Trim;
      Inc(I);
      Continue;
    end;
    if SameText(Arg, '-file') then
      Options.Mode := tmFile
    else if SameText(Arg, '-live') then
      Options.Mode := tmLive
    else if SameText(Arg, '-synthetic') and HasValue then begin
      Options.Mode := tmSynthetic;
      if not TryStrToInt(ParamStr(I + 1), Options.Stride) or (Options.Stride < 1) then
        Exit(False);
      Inc(I);
    end else if SameText(Arg, '-map') and HasValue then begin
      Options.MapPath := ExpandFileName(ParamStr(I + 1));
      Inc(I);
    end else if SameText(Arg, '-zydis') and HasValue then begin
      Options.ZydisDll := ExpandFileName(ParamStr(I + 1));
      Inc(I);
    end else if SameText(Arg, '-n') and HasValue then begin
      if not TryStrToInt(ParamStr(I + 1), Options.Reps) or (Options.Reps < 1) then
        Exit(False);
      Inc(I);
    end else if SameText(Arg, '-timeout') and HasValue then begin
      if not TryStrToInt(ParamStr(I + 1), Options.TimeoutSec) or (Options.TimeoutSec < 1) then
        Exit(False);
      Inc(I);
    end else if Arg.StartsWith('-') then
      Exit(False)
    else
      Options.BinaryPath := ExpandFileName(Arg);
    Inc(I);
  end;
  if Options.ZydisDll = '' then
    Options.ZydisDll := ResolveZydisDllPathForThisExe;
  Result := (Options.Mode <> tmNone) and (Options.BinaryPath <> '');
end;

function Median(Values: TArray<Double>): Double;
begin
  if Length(Values) = 0 then
    Exit(0);
  TArray.Sort<Double>(Values);
  var Mid := Length(Values) div 2;
  if Odd(Length(Values)) then
    Result := Values[Mid]
  else
    Result := (Values[Mid - 1] + Values[Mid]) / 2;
end;

{ ------------------------------------------------------------------ -file -- }

// The "target" of a patch map over a FILE: reads come from the image, writes
// are counted and dropped, a region is the section that holds the address
// (VirtualQueryEx would merge adjacent sections of equal protection, so this
// can only count more runs than a live process, never fewer).
type
  TFileTarget = class
  public
    Image:        TPeImageFile;
    WriteCalls:   Integer;
    BytesWritten: UInt64;
    Pages:        TDictionary<UInt64, Boolean>;
    constructor Create(AImage: TPeImageFile);
    destructor Destroy; override;
    function Access: TCodePatchMemory;
  end;

constructor TFileTarget.Create(AImage: TPeImageFile);
begin
  inherited Create;
  Image := AImage;
  Pages := TDictionary<UInt64, Boolean>.Create;
end;

destructor TFileTarget.Destroy;
begin
  Pages.Free;
  inherited;
end;

function TFileTarget.Access: TCodePatchMemory;
begin
  Result.Read :=
    function(VA: UInt64; Buf: Pointer; Size: NativeUInt): Boolean
    begin
      Result := Image.Read(VA, Buf, Integer(Size)) = Integer(Size);
    end;
  Result.Write :=
    function(VA: UInt64; Buf: Pointer; Size: NativeUInt): Boolean
    begin
      Inc(WriteCalls);
      Inc(BytesWritten, Size);
      var Page := VA and not UInt64(PAGE_BYTES - 1);
      while Page < VA + Size do begin
        Pages.AddOrSetValue(Page, True);
        Inc(Page, PAGE_BYTES);
      end;
      Result := True;
    end;
  Result.Query :=
    function(VA: UInt64; out Region: TCodePatchRegion): Boolean
    begin
      Region := Default(TCodePatchRegion);
      for var Section in Image.Sections do begin
        var SectionVA := Image.ImageBase + Section.Rva;
        var SectionSize := (UInt64(Section.VirtualSize) + PAGE_BYTES - 1) and not UInt64(PAGE_BYTES - 1);
        if (VA >= SectionVA) and (VA - SectionVA < SectionSize) then begin
          Region.Base       := SectionVA;
          Region.Size       := SectionSize;
          Region.Accessible := True;
          Exit(True);
        end;
      end;
      Result := False;
    end;
end;

procedure RunFile(const Options: TOptions);
begin
  var Image := TPeImageFile.Create(Options.BinaryPath);
  try
    var Bits := 32;
    if Image.Is64 then
      Bits := 64;
    Writeln(Format('%s  (%d-bit, image size %.1f MB)',
      [Options.BinaryPath, Bits, Image.SizeOfImage / (1024 * 1024)]));

    var Reader := TTD32FileReader.Create;
    var ReaderRef: IInterface := Reader;
    var Clock := TStopwatch.StartNew;
    Reader.LoadFromFile(Options.BinaryPath);
    Writeln(Format('  TD32 load                         %10.0f ms', [Clock.Elapsed.TotalMilliseconds]));
    var Providers: TArray<IInterface> := [ReaderRef];
    if Options.MapPath <> '' then begin
      if not FileExists(Options.MapPath) then
        raise Exception.Create('-map: no such file: ' + Options.MapPath);
      var MapReader := TMapFile.Create;
      var MapRef: IInterface := MapReader;
      Clock := TStopwatch.StartNew;
      MapReader.LoadFromFile(Options.MapPath, ReadPEPreferredBase(Options.BinaryPath));
      while MapReader.BackgroundIndexingPending and (Clock.Elapsed.TotalSeconds < 300) do
        Sleep(5);
      Writeln(Format('  MAP load and index                %10.0f ms', [Clock.Elapsed.TotalMilliseconds]));
      Providers := Providers + [MapRef];
    end;

    var Base := Image.ImageBase;
    var Size: UInt64 := Image.SizeOfImage;
    var ModuleName := ExtractFileName(Options.BinaryPath);
    var Analysis := TLiveCodeAnalysis.Create(Image.Read,
      function(VA: UInt64; out Info: TLiveModuleInfo): Boolean
      begin
        Info := Default(TLiveModuleInfo);
        Result := (VA >= Base) and (VA - Base < Size);
        if not Result then
          Exit;
        Info.Name      := ModuleName;
        Info.Base      := Base;
        Info.Size      := Size;
        Info.Providers := Providers;
      end);
    try
      Analysis.ZydisDllPath := Options.ZydisDll;
      var Confirmed: TArray<Cardinal>;
      var Tally: TConfirmedLineTally;
      var WhyNot: string;
      if not Analysis.ConfirmedLineRecords(Base, nil, True, Confirmed, Tally, WhyNot) then
        raise Exception.Create('the module cannot be analysed: ' + WhyNot);
      var FirstMs := Tally.Milliseconds;
      // The same question again: the code map is built, only the verdicts are
      // worked out (nothing is remembered per record).
      Analysis.ConfirmedLineRecords(Base, nil, True, Confirmed, Tally, WhyNot);
      Writeln('verdicts for every line record (TLiveCodeAnalysis.ConfirmedLineRecords)');
      Writeln(Format('  line records                      %10d', [Tally.Asked]));
      Writeln(Format('  confirmed (would carry a probe)   %10d  (%.2f %%)',
        [Tally.Confirmed, 100 * Tally.Confirmed / Max(1, Tally.Asked)]));
      Writeln(Format('  not code                          %10d', [Tally.NotCode]));
      Writeln(Format('  unconfirmed                       %10d', [Tally.Unconfirmed]));
      Writeln(Format('  zero byte, MAP-named routine      %10d', [Tally.ZeroByteInMapNamedRoutine]));
      Writeln(Format('  routines analysed / incomplete    %10d / %d', [Tally.RoutinesAnalysed, Tally.RoutinesIncomplete]));
      Writeln(Format('  first call (code map included)    %10.0f ms', [FirstMs]));
      Writeln(Format('  again (verdicts only)             %10.0f ms', [Tally.Milliseconds]));

      var Target := TFileTarget.Create(Image);
      var Map := TCodePatchMap.Create(Target.Access);
      try
        var Outcome: TCodePatchArmOutcome;
        Map.Arm(LowerCase(ModuleName), Base, Size, Confirmed, nil, Outcome);
        Writeln('arming them (TCodePatchMap.Arm; reads real, writes counted)');
        Writeln(Format('  armed                             %10d', [Outcome.Armed]));
        Writeln(Format('  refused: the program''s own int 3  %10d', [Outcome.OwnBreakpointInstruction]));
        Writeln(Format('  unreadable                        %10d', [Outcome.Unreadable]));
        Writeln(Format('  runs (one read each)              %10d', [Outcome.Runs]));
        Writeln(Format('  write calls                       %10d', [Target.WriteCalls]));
        Writeln(Format('  bytes covered by the writes       %10.1f MB', [Target.BytesWritten / (1024 * 1024)]));
        Writeln(Format('  pages made private                %10d  (%.1f MB)',
          [Target.Pages.Count, Target.Pages.Count * PAGE_BYTES / (1024 * 1024)]));
        Writeln(Format('  time in the map                   %10.0f ms', [Outcome.Milliseconds]));
        // What a hit pays the map: the lookup of its address.
        Clock := TStopwatch.StartNew;
        var Found := 0;
        for var Rva in Confirmed do
          if Map.TrapAt(Base + Rva) = cptArmed then
            Inc(Found);
        var LookupNs := 1E6 * Clock.Elapsed.TotalMilliseconds / Max(1, Length(Confirmed));
        Writeln(Format('  lookup of a hit address           %10.0f ns  (%d found)', [LookupNs, Found]));
      finally
        Map.Free;
        Target.Free;
      end;
    finally
      Analysis.Free;
    end;
  finally
    Image.Free;
  end;
end;

{ ---------------------------------------------------------- -live / -synthetic -- }

function LaunchStopped(const Options: TOptions): TDebugSession;
begin
  Result := TDebugSession.Create;
  try
    var Opts := Default(TLaunchOptions);
    Opts.ExePath             := Options.BinaryPath;
    Opts.Args                := Options.Args;
    Opts.StopAtEntry         := True;
    Opts.ExceptionFilters    := Default(TExceptionFilters);
    Opts.ExceptionFiltersSet := True;
    if not Result.Launch(Opts) then
      raise Exception.Create('Launch returned False');
    var Deadline := GetTickCount64 + UInt64(Options.TimeoutSec) * 1000;
    while (Result.State <> dsStopped) and (not Result.HasExited) and (GetTickCount64 < Deadline) do
      Result.Pump;
    if Result.State <> dsStopped then
      raise Exception.Create('the program did not stop at its entry point');
  except
    Result.Free;
    raise;
  end;
end;

type
  TLiveRun = record
    RunMs:     Double;
    Hits:      Integer;
    Tally:     TConfirmedLineTally;
    Armed:     Integer;
    AnalysisMs: Double;
    ArmMs:     Double;
    Writes:    Integer;
    LateTraps: Integer;
  end;

function OneLiveRun(const Options: TOptions; WithProbes: Boolean): TLiveRun;
begin
  Result := Default(TLiveRun);
  var ModuleName := ExtractFileName(Options.BinaryPath);
  var Session := LaunchStopped(Options);
  try
    if WithProbes then begin
      // On x86 the MAP names the bodies of anonymous methods: wait for its
      // index, as a collection armed at launch would not (it arms the rest and
      // those bodies later).
      var Deadline := GetTickCount64 + 30000;
      while Session.DebugInfo.AnyBackgroundIndexingPending and (GetTickCount64 < Deadline) do
        Sleep(5);
      var Request := Default(TLineProbeRequest);
      Request.ModuleName  := ModuleName;
      Request.WholeModule := True;
      var Report: TLineProbeReport;
      if not Session.LineProbes.Arm(Request, Report) then
        raise Exception.Create('the request was refused: ' + Report.Note);
      Result.Tally      := Report.Tally;
      Result.Armed      := Report.Outcome.Armed;
      Result.AnalysisMs := Report.Tally.Milliseconds;
      Result.ArmMs      := Report.Outcome.Milliseconds;
      Result.Writes     := Report.Outcome.WriteCalls;
    end;
    var Clock := TStopwatch.StartNew;
    Session.ContinueExecution;
    var Deadline := GetTickCount64 + UInt64(Options.TimeoutSec) * 1000;
    while (not Session.HasExited) and (GetTickCount64 < Deadline) do begin
      Session.Pump;
      if Session.State = dsStopped then
        Session.ContinueExecution;
    end;
    Result.RunMs := Clock.Elapsed.TotalMilliseconds;
    if not Session.HasExited then
      raise Exception.Create('the program did not end within the timeout');
    if WithProbes then begin
      Result.Hits      := Length(Session.LineProbes.Hits(ModuleName));
      Result.LateTraps := Session.LineProbes.Stats.LateTraps;
    end;
  finally
    if not Session.HasExited then
      Session.Terminate;
    Session.Free;
  end;
end;

procedure RunLive(const Options: TOptions);
begin
  Writeln(Format('%s %s  (%d repetitions)', [Options.BinaryPath, Options.Args, Options.Reps]));
  if GetEnvironmentVariable('DAP_LOG') = '1' then
    Writeln('  warning: DAP_LOG=1, the engine logs every event; set DAP_LOG=0 to measure');
  var Plain: TArray<Double>;
  var Probed: TArray<Double>;
  var Last := Default(TLiveRun);
  for var Rep := 1 to Options.Reps do begin
    Plain  := Plain + [OneLiveRun(Options, False).RunMs];
    Last   := OneLiveRun(Options, True);
    Probed := Probed + [Last.RunMs];
  end;
  var PlainMs  := Median(Plain);
  var ProbedMs := Median(Probed);
  Writeln(Format('  line records / confirmed          %10d / %d  (not code %d, unconfirmed %d)',
    [Last.Tally.Asked, Last.Tally.Confirmed, Last.Tally.NotCode, Last.Tally.Unconfirmed]));
  Writeln(Format('  probes armed at the entry stop    %10d', [Last.Armed]));
  Writeln(Format('    analysis                        %10.1f ms', [Last.AnalysisMs]));
  Writeln(Format('    writes                          %10.1f ms in %d write call(s)', [Last.ArmMs, Last.Writes]));
  Writeln(Format('  first hits recorded               %10d  (late traps: %d)', [Last.Hits, Last.LateTraps]));
  Writeln(Format('  run to the end, no probes         %10.1f ms  (median)', [PlainMs]));
  Writeln(Format('  run to the end, every line armed  %10.1f ms  (median)', [ProbedMs]));
  if Last.Hits > 0 then
    Writeln(Format('  one first hit                     %10.1f us', [1000 * (ProbedMs - PlainMs) / Last.Hits]));
end;

procedure RunSynthetic(const Options: TOptions);
begin
  var Image := TPeImageFile.Create(Options.BinaryPath);
  var Rvas: TArray<Cardinal>;
  try
    var Count := 0;
    for var Section in Image.Sections do
      if Section.Characteristics and IMAGE_SCN_MEM_EXECUTE <> 0 then
        Inc(Count, (Section.VirtualSize + Cardinal(Options.Stride) - 1) div Cardinal(Options.Stride));
    SetLength(Rvas, Count);
    var N := 0;
    for var Section in Image.Sections do begin
      if Section.Characteristics and IMAGE_SCN_MEM_EXECUTE = 0 then
        Continue;
      var Rva := Section.Rva;
      while Rva < Section.Rva + Section.VirtualSize do begin
        Rvas[N] := Rva;
        Inc(N);
        Inc(Rva, Cardinal(Options.Stride));
      end;
    end;
    SetLength(Rvas, N);
  finally
    Image.Free;
  end;
  Writeln(Format('%s  (a probe every %d bytes of code: %d addresses)', [Options.BinaryPath, Options.Stride, Length(Rvas)]));
  if GetEnvironmentVariable('DAP_LOG') = '1' then
    Writeln('  warning: DAP_LOG=1, set DAP_LOG=0 to measure');
  var Session := LaunchStopped(Options);
  try
    var Target: ICodePatchTarget;
    if not Supports(Session.Debugger, ICodePatchTarget, Target) then
      raise Exception.Create('the engine does not implement ICodePatchTarget');
    var Request := Default(TCodePatchArmRequest);
    Request.ModuleBase := Session.Debugger.ImageBase;
    Request.ResultKey  := LowerCase(ExtractFileName(Options.BinaryPath));
    Request.Rvas       := Rvas;
    var Outcome: TCodePatchArmOutcome;
    var Refusal: string;
    var Clock := TStopwatch.StartNew;
    if not Target.ArmOneShotProbes(Request, Outcome, Refusal) then
      raise Exception.Create('refused: ' + Refusal);
    var ArmWallMs := Clock.Elapsed.TotalMilliseconds;
    Clock := TStopwatch.StartNew;
    var Gone := Target.DisarmProbes(Session.Debugger.ImageBase);
    var DisarmMs := Clock.Elapsed.TotalMilliseconds;
    Writeln(Format('  armed                             %10d  (own int 3 refused: %d)',
      [Outcome.Armed, Outcome.OwnBreakpointInstruction]));
    Writeln(Format('  runs / write calls                %10d / %d', [Outcome.Runs, Outcome.WriteCalls]));
    Writeln(Format('  bytes covered by the writes       %10.1f MB', [Outcome.BytesWritten / (1024 * 1024)]));
    Writeln(Format('  arm, in the map                   %10.1f ms', [Outcome.Milliseconds]));
    Writeln(Format('  arm, wall (threads held)          %10.1f ms  (%.2f us per probe)',
      [ArmWallMs, 1000 * ArmWallMs / Max(1, Outcome.Armed)]));
    Writeln(Format('  disarm                            %10.1f ms  (%d restored in %d write call(s), %d lost)',
      [DisarmMs, Gone.Restored, Gone.WriteCalls, Gone.Lost]));
  finally
    // The program must not run with $CC bytes in the middle of instructions.
    Session.Terminate;
    Session.Free;
  end;
end;

begin
  // A target that crashes must not produce a window.
  SetErrorMode(GetErrorMode or SEM_FAILCRITICALERRORS or SEM_NOGPFAULTERRORBOX or SEM_NOOPENFILEERRORBOX);
  // Figures for the record read the same on every machine.
  FormatSettings := TFormatSettings.Invariant;
  try
    var Options: TOptions;
    if not ParseOptions(Options) then begin
      PrintUsage;
      Halt(2);
    end;
    if not FileExists(Options.BinaryPath) then begin
      Writeln('File not found: ', Options.BinaryPath);
      Halt(2);
    end;
    case Options.Mode of
      tmFile:      RunFile(Options);
      tmLive:      RunLive(Options);
      tmSynthetic: RunSynthetic(Options);
    end;
  except
    on E: Exception do begin
      Writeln(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
