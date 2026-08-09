program ExceptionStopProbe;

// Drives a TDebugSession to the FIRST exception stop of a target and reports,
// side by side, the three answers that a stop has to keep apart:
//
//   * the RAW stack the engine walked (every frame, plumbing and fault included)
//   * the stack the session REPORTS after the raise-plumbing trim
//   * the locals the session serves with no frame explicitly selected, and the
//     locals of each of the first few frames when one IS selected
//
// Written because "the exception stopped on the wrong frame" and "the locals
// came from the wrong frame" look identical from a test assertion, and they have
// different causes. Distinct from ExcHandlerProbe, which measures where an
// exception is DISPATCHED to (scope tables, handler funclets, trap-flag
// survival); this one measures what the session REPORTS at the stop.
//
//   ExceptionStopProbe <exe> <sourceRoot> [-args "<debuggee args>"]
//                      [-filters delphi,av,all,unhandled] [-frames N]
//
// Defaults: no -args, filters `delphi,av,unhandled`, 6 frames probed for locals.

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.StrUtils,
  Winapi.Windows,
  DebugTarget,
  ExceptionRules,
  DebugSessionTypes, DebugSession;

function FrameLine(const F: TSessionFrame): string;
begin
  Result := Format('%-46s %-22s %s:%d  ip=%s entry=%s',
    [IfThen(F.FunctionName <> '', F.FunctionName, '<no name>'),
     IfThen(F.ModuleName <> '', F.ModuleName, '<no module>'),
     IfThen(F.SourceFile <> '', ExtractFileName(F.SourceFile), '-'),
     F.SourceLine, IntToHex(F.IP, 8), IntToHex(F.FuncEntryVA, 8)]);
end;

function RawFrameLine(const F: TStackFrame): string;
begin
  Result := Format('%-46s %s:%d  ip=%s entry=%s rbp=%s origin=%s',
    [IfThen(F.FunctionName <> '', F.FunctionName, '<no name>'),
     IfThen(F.SourceFile <> '', ExtractFileName(F.SourceFile), '-'),
     F.SourceLine, IntToHex(F.IP, 8), IntToHex(F.FuncEntryVA, 8),
     IntToHex(F.FrameRBP, 8), FrameOriginName(F.Origin)]);
end;

procedure ListLocals(Session: TDebugSession; const Indent: string);
begin
  var L := Session.GetLocals;
  if Length(L) = 0 then begin
    Writeln(Indent + '(none)');
    Exit;
  end;
  for var V in L do
    Writeln(Format('%s%-24s = %-40s [%s]', [Indent, V.Name, V.Value, V.TypeName]));
end;

procedure Run(const ExePath, SourceRoot, TargetArgs: string;
  const Filters: TExceptionFilters; FrameProbeCount: Integer);
begin
  var Session := TDebugSession.Create;
  try
    var Opts := Default(TLaunchOptions);
    Opts.ExePath             := ExePath;
    Opts.SourceRoot          := SourceRoot;
    Opts.Args                := TargetArgs;
    Opts.StopAtEntry         := True;
    Opts.ExceptionFilters    := Filters;
    Opts.ExceptionFiltersSet := True;
    if not Session.Launch(Opts) then begin
      Writeln('LAUNCH FAILED: ' + ExePath);
      Halt(3);
    end;

    var Entry := GetTickCount64 + 30000;
    while (Session.State <> dsStopped) and (not Session.HasExited) and
          (GetTickCount64 < Entry) do
      Session.Pump;
    if Session.State <> dsStopped then begin
      Writeln('never reached the entry stop');
      Halt(4);
    end;
    Session.ContinueExecution;

    var Deadline := GetTickCount64 + 30000;
    while (Session.State <> dsStopped) and (not Session.HasExited) and
          (GetTickCount64 < Deadline) do
      Session.Pump;
    if Session.State <> dsStopped then begin
      Writeln('never reached an exception stop (exited=' +
        BoolToStr(Session.HasExited, True) + ')');
      Halt(5);
    end;

    var Exc := Session.GetExceptionDetails;
    Writeln('exception : ', Exc.ExceptionClass, ': ', Exc.Message);
    var Fn, Src: string;
    var Ln: Integer;
    if Session.GetCurrentLocation(Fn, Src, Ln) then
      Writeln(Format('location  : %s at %s:%d', [Fn, ExtractFileName(Src), Ln]))
    else
      Writeln('location  : <not resolved>');

    Writeln;
    Writeln('RAW frames (engine walk, nothing trimmed):');
    var Raw := Session.Debugger.GetStackFrames;
    for var I := 0 to High(Raw) do
      Writeln(Format('  #%-2d %s', [I, RawFrameLine(Raw[I])]));
    Writeln(Format('  (%d raw frames)', [Length(Raw)]));

    Writeln;
    Writeln('REPORTED frames (TDebugSession.GetCallStack):');
    var Frames := Session.GetCallStack;
    for var F in Frames do
      Writeln(Format('  #%-2d %s', [F.Index, FrameLine(F)]));
    Writeln(Format('  (%d reported frames)', [Length(Frames)]));

    Writeln;
    Writeln(Format('LOCALS with no frame selected (DefaultFrameIndex = %d):',
      [Session.DefaultFrameIndex]));
    ListLocals(Session, '  ');

    var Probe := FrameProbeCount;
    if Probe > Length(Frames) then
      Probe := Length(Frames);
    for var I := 0 to Probe - 1 do begin
      Writeln;
      Writeln(Format('LOCALS after SelectFrame(%d)  [%s]',
        [I, IfThen(Frames[I].FunctionName <> '', Frames[I].FunctionName, '<no name>')]));
      Session.SelectFrame(I);
      ListLocals(Session, '  ');
      Session.ClearFrame;
    end;
  finally
    Session.Terminate;
    Session.Free;
  end;
end;

begin
  try
    if ParamCount < 2 then begin
      Writeln('usage: ExceptionStopProbe <exe> <sourceRoot> [-args "<debuggee args>"]');
      Writeln('                          [-filters delphi,av,all,unhandled] [-frames N]');
      Halt(1);
    end;
    var TargetArgs := '';
    var FilterNames: TArray<string> := ['delphi', 'av', 'unhandled'];
    var FrameProbeCount := 6;
    var I := 3;
    while I <= ParamCount do begin
      if SameText(ParamStr(I), '-args') and (I < ParamCount) then begin
        TargetArgs := ParamStr(I + 1);
        Inc(I, 2);
      end
      else if SameText(ParamStr(I), '-filters') and (I < ParamCount) then begin
        FilterNames := ParamStr(I + 1).Split([',']);
        Inc(I, 2);
      end
      else if SameText(ParamStr(I), '-frames') and (I < ParamCount) then begin
        FrameProbeCount := StrToIntDef(ParamStr(I + 1), FrameProbeCount);
        Inc(I, 2);
      end
      else
        Inc(I);
    end;
    Run(ParamStr(1), ParamStr(2), TargetArgs,
      TDebugSession.ParseExceptionFilters(FilterNames), FrameProbeCount);
  except
    on E: Exception do begin
      Writeln(E.ClassName + ': ' + E.Message);
      Halt(9);
    end;
  end;
end.
