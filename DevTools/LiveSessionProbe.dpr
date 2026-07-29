program LiveSessionProbe;

// Drives a REAL TDebugSession against a long-lived host application and keeps
// it running, so a human can trigger the breakpoints from the target's own UI
// while this reports what the debugger saw at each stop.
//
// Written for the bds.exe / design-time-package case, where the interesting
// stops cannot be provoked from a test fixture: they need somebody to open a
// form in the IDE. The probe launches, plants the breakpoints, then loops --
// on every stop it dumps the call stack, the locals and any expressions asked
// for on the command line, then CONTINUES so the next trigger works too.
//
//   LiveSessionProbe <exe> <sourceRoot> <file:line>[,<file:line>...]
//                    [-seconds N] [-eval <expr>] [-eval <expr>] ...
//
// <sourceRoot> is searched (one level deep) for the source files, exactly as a
// launch config's sourceRoot is.
//
// Everything printed is what the ADAPTER resolved, not what the source says --
// the point is to compare the two.

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.StrUtils, System.Generics.Collections,
  Winapi.Windows,
  DebugSessionTypes, DebugSession;

type
  TBpRequest = record
    SourceFile: string;   // basename as the user typed it
    Line:       Integer;
  end;

function ParseBpSpec(const S: string; out Req: TBpRequest): Boolean;
begin
  Result := False;
  Req := Default(TBpRequest);
  var ColonPos := S.LastIndexOf(':');
  if ColonPos <= 0 then
    Exit;
  Req.SourceFile := S.Substring(0, ColonPos);
  Req.Line := StrToIntDef(S.Substring(ColonPos + 1), 0);
  Result := Req.Line > 0;
end;

procedure DumpStop(Session: TDebugSession; const Evals: TArray<string>;
  StopIndex: Integer);
begin
  Writeln;
  Writeln(StringOfChar('=', 78));
  Writeln(Format('STOP #%d', [StopIndex]));

  var FnName, SrcFile: string;
  var StopLine: Integer;
  if Session.GetCurrentLocation(FnName, SrcFile, StopLine) then
    Writeln(Format('  location : %s at %s:%d',
      [FnName, ExtractFileName(SrcFile), StopLine]))
  else
    Writeln('  location : <not resolved>');

  var Exc := Session.GetExceptionDetails;
  if Exc.ExceptionClass <> '' then
    Writeln(Format('  exception: %s: %s', [Exc.ExceptionClass, Exc.Message]));

  Writeln('  call stack:');
  var Frames := Session.GetCallStack;
  for var F in Frames do
    Writeln(Format('    #%-2d %-44s %s:%d  [%s]  ip=%s',
      [F.Index,
       IfThen(F.FunctionName <> '', F.FunctionName, '<no name>'),
       IfThen(F.SourceFile <> '', ExtractFileName(F.SourceFile), '-'),
       F.SourceLine, F.ModuleName, IntToHex(F.IP, 8)]));
  Writeln(Format('    (%d frames)', [Length(Frames)]));

  Writeln('  locals:');
  var Locals := Session.GetLocals;
  for var L in Locals do
    Writeln(Format('    %-22s = %-44s [%s]', [L.Name, L.Value, L.TypeName]));
  if Length(Locals) = 0 then
    Writeln('    (none)');

  if Length(Evals) > 0 then begin
    Writeln('  evaluate:');
    for var E in Evals do begin
      var R := Session.Evaluate(E);
      Writeln(Format('    %-22s => %-44s [%s]', [E, R.Value, R.TypeName]));
    end;
  end;
  Writeln(StringOfChar('=', 78));
  Flush(Output);
end;

procedure Run(const ExePath, SourceRoot: string; const Bps: TArray<TBpRequest>;
  const Evals: TArray<string>; Seconds: Integer);
begin
  var Session := TDebugSession.Create;
  try
    var Opts := Default(TLaunchOptions);
    Opts.ExePath     := ExePath;
    Opts.SourceRoot  := SourceRoot;
    Opts.StopAtEntry := False;

    if not Session.Launch(Opts) then begin
      Writeln('LAUNCH FAILED: ' + ExePath);
      Halt(3);
    end;
    Writeln('launched ' + ExePath);
    Writeln('pid ' + IntToStr(Session.DebuggeeProcessId));

    // Group the requested lines per source file: SetBreakpoints replaces the
    // whole set for a file, so one call per file with ALL its lines.
    var ByFile := TDictionary<string, TArray<TBpLineSpec>>.Create;
    try
      for var B in Bps do begin
        var Spec := Default(TBpLineSpec);
        Spec.Line := B.Line;
        var Existing: TArray<TBpLineSpec>;
        if not ByFile.TryGetValue(B.SourceFile, Existing) then
          Existing := nil;
        ByFile.AddOrSetValue(B.SourceFile, Existing + [Spec]);
      end;
      for var Pair in ByFile do begin
        Writeln('breakpoints in ' + Pair.Key + ':');
        for var Bound in Session.SetBreakpoints(Pair.Key, Pair.Value) do
          Writeln(Format('  line %-5d verified=%s',
            [Bound.Line, BoolToStr(Bound.Verified, True)]));
      end;
    finally
      ByFile.Free;
    end;

    Writeln;
    Writeln(Format('Now trigger the breakpoints from the application. ' +
                   'Running for %d seconds.', [Seconds]));
    Writeln('The target is CONTINUED after every stop, so it stays usable.');
    Flush(Output);

    // A breakpoint in a package that is not loaded yet binds LATER, when its
    // module arrives. Reporting only the state at set time therefore says
    // nothing about whether the breakpoint will ever fire, which is exactly the
    // question when the target is a host application loading design packages.
    // Poll the set and report every transition.
    var StopIndex := 0;
    var Verified := TDictionary<string, Boolean>.Create;
    try
      var Deadline := GetTickCount64 + UInt64(Seconds) * 1000;
      var NextBpCheck: UInt64 := 0;
      while (not Session.HasExited) and (GetTickCount64 < Deadline) do begin
        Session.Pump;

        if GetTickCount64 >= NextBpCheck then begin
          NextBpCheck := GetTickCount64 + 1000;
          for var B in Session.ListBreakpoints do begin
            var Key := B.SourceFile + ':' + IntToStr(B.Line);
            var Was: Boolean;
            if (not Verified.TryGetValue(Key, Was)) or (Was <> B.Verified) then begin
              Verified.AddOrSetValue(Key, B.Verified);
              Writeln(Format('[bp] %-40s verified=%s',
                [Key, BoolToStr(B.Verified, True)]));
              Flush(Output);
            end;
          end;
        end;

        if Session.State <> dsStopped then
          Continue;
        Inc(StopIndex);
        DumpStop(Session, Evals, StopIndex);
        Session.ContinueExecution;
      end;
    finally
      Verified.Free;
    end;

    if Session.HasExited then
      Writeln('target exited')
    else begin
      Writeln(Format('time is up after %d stop(s); detaching and leaving the ' +
                     'target running', [StopIndex]));
      Session.Detach;
    end;
  finally
    Session.Free;
  end;
end;

begin
  try
    if ParamCount < 3 then begin
      Writeln('usage: LiveSessionProbe <exe> <sourceRoot> <file:line>[,<file:line>...]');
      Writeln('                        [-seconds N] [-eval <expr>] ...');
      Halt(1);
    end;
    var Bps: TArray<TBpRequest>;
    for var Part in ParamStr(3).Split([',']) do begin
      var Req: TBpRequest;
      if not ParseBpSpec(Part.Trim, Req) then begin
        Writeln('bad breakpoint spec: ' + Part);
        Halt(2);
      end;
      Bps := Bps + [Req];
    end;

    var Evals: TArray<string>;
    var Seconds := 300;
    var I := 4;
    while I <= ParamCount do begin
      if SameText(ParamStr(I), '-seconds') and (I < ParamCount) then begin
        Seconds := StrToIntDef(ParamStr(I + 1), Seconds);
        Inc(I, 2);
      end
      else if SameText(ParamStr(I), '-eval') and (I < ParamCount) then begin
        Evals := Evals + [ParamStr(I + 1)];
        Inc(I, 2);
      end
      else
        Inc(I);
    end;

    Run(ParamStr(1), ParamStr(2), Bps, Evals, Seconds);
  except
    on E: Exception do begin
      Writeln(E.ClassName + ': ' + E.Message);
      Halt(9);
    end;
  end;
end.
