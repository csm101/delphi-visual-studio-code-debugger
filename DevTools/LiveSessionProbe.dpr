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

// True when the current stop is in one of the files we set breakpoints in.
function StopIsInBpFile(Session: TDebugSession; const Bps: TArray<TBpRequest>): Boolean;
begin
  Result := False;
  var FnName, SrcFile: string;
  var Line: Integer;
  if not Session.GetCurrentLocation(FnName, SrcFile, Line) then
    Exit;
  var Base := ExtractFileName(SrcFile);
  for var B in Bps do
    if SameText(ExtractFileName(B.SourceFile), Base) then
      Exit(True);
end;

// Runs a scripted debugging session at a stop: the commands a developer would
// actually issue, in order, with every answer recorded. This is the difference
// between "the breakpoint fired" and "the debugger is usable" -- the second only
// shows up when you step, expand, evaluate a property and call a function.
//
//   stack                  call stack
//   locals                 frame 0 locals
//   expand <name>          expand a local (or an expression) two levels deep
//   eval <expr>            evaluate an expression
//   setvar <name> <value>  write a local, then read it back
//   stepin / stepover / stepout
//   frame <n>              evaluate the next `eval`s in frame n
//
// Anything unrecognised is reported rather than skipped silently, so a typo in
// a script cannot look like a debugger result.
procedure RunScript(Session: TDebugSession; const Script: TArray<string>);

  procedure ShowVar(const Prefix: string; const V: TSessionVariable);
  begin
    Writeln(Format('%s%-22s = %-46s [%s]%s',
      [Prefix, V.Name, V.Value, V.TypeName,
       IfThen(V.Expandable, ' (expandable)', '')]));
  end;

  procedure ExpandHandle(H: TVarHandle; Depth: Integer; const Indent: string);
  begin
    if (H = 0) or (Depth <= 0) then
      Exit;
    for var C in Session.GetChildren(H) do begin
      ShowVar(Indent, C);
      if C.Expandable then
        ExpandHandle(C.Handle, Depth - 1, Indent + '    ');
    end;
  end;

  procedure DoStep(const Kind: string);
  begin
    var Before := Session.StopGeneration;
    if Kind = 'stepin' then
      Session.StepInto
    else if Kind = 'stepout' then
      Session.StepOut
    else
      Session.StepOver;
    var Deadline := GetTickCount64 + 15000;
    while (Session.StopGeneration = Before) and (not Session.HasExited) and
          (GetTickCount64 < Deadline) do
      Session.Pump;
    if Session.StopGeneration = Before then begin
      Writeln('    !! ' + Kind + ' DID NOT COMPLETE within 15 s');
      Exit;
    end;
    var FnName, SrcFile: string;
    var Line: Integer;
    if Session.GetCurrentLocation(FnName, SrcFile, Line) then
      Writeln(Format('    -> %s at %s:%d', [FnName, ExtractFileName(SrcFile), Line]))
    else
      Writeln('    -> <no location>');
  end;

begin
  var FrameIdx := 0;
  for var Raw in Script do begin
    var Line := Raw.Trim;
    if (Line = '') or Line.StartsWith('#') then
      Continue;
    Writeln('  $ ' + Line);
    var SpacePos := Line.IndexOf(' ');
    var Cmd  := Line;
    var Arg  := '';
    if SpacePos > 0 then begin
      Cmd := Line.Substring(0, SpacePos);
      Arg := Line.Substring(SpacePos + 1).Trim;
    end;

    if SameText(Cmd, 'stack') then begin
      for var F in Session.GetCallStack do
        Writeln(Format('    #%-2d %-44s %s:%d  [%s]',
          [F.Index, IfThen(F.FunctionName <> '', F.FunctionName, '<no name>'),
           IfThen(F.SourceFile <> '', ExtractFileName(F.SourceFile), '-'),
           F.SourceLine, F.ModuleName]));
    end
    else if SameText(Cmd, 'locals') then begin
      var L := Session.GetLocals;
      for var V in L do
        ShowVar('    ', V);
      if Length(L) = 0 then
        Writeln('    (none)');
    end
    else if SameText(Cmd, 'expand') then begin
      var Found := False;
      for var V in Session.GetLocals do
        if SameText(V.Name, Arg) then begin
          Found := True;
          ShowVar('    ', V);
          ExpandHandle(V.Handle, 2, '        ');
        end;
      if not Found then begin
        var R := Session.Evaluate(Arg);
        Writeln(Format('    %s => %s [%s]', [Arg, R.Value, R.TypeName]));
        ExpandHandle(R.Handle, 2, '        ');
      end;
    end
    else if SameText(Cmd, 'eval') then begin
      var R := Session.EvaluateForFrame(Arg, FrameIdx);
      if R.Success then
        Writeln(Format('    => %-48s [%s]', [R.Value, R.TypeName]))
      else
        Writeln(Format('    => FAILED: %s', [R.ErrorText]));
    end
    else if SameText(Cmd, 'frame') then begin
      FrameIdx := StrToIntDef(Arg, 0);
      Writeln(Format('    (evaluating in frame %d)', [FrameIdx]));
    end
    else if SameText(Cmd, 'threads') then begin
      var T := Session.GetThreads;
      Writeln(Format('    %d thread(s), stopped tid=%d',
        [Length(T), Session.GetStoppedThreadId]));
    end
    else if SameText(Cmd, 'stepin') or SameText(Cmd, 'stepover') or
            SameText(Cmd, 'stepout') then
      DoStep(LowerCase(Cmd))
    else
      Writeln('    !! unknown command');
    Flush(Output);
  end;
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
  const Evals, Script: TArray<string>; Seconds: Integer);
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
        // The script runs only at a stop in one of OUR breakpoint files: the
        // startup of a host application produces dozens of unrelated exception
        // stops, and driving a scripted session through those would say nothing.
        if (Length(Script) > 0) and StopIsInBpFile(Session, Bps) then begin
          Writeln('  --- scripted session ---');
          RunScript(Session, Script);
          Writeln('  --- end of script ---');
        end;
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

    var Evals:  TArray<string>;
    var Script: TArray<string>;
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
      else if SameText(ParamStr(I), '-script') and (I < ParamCount) then begin
        var SL := TStringList.Create;
        try
          SL.LoadFromFile(ParamStr(I + 1));
          Script := SL.ToStringArray;
        finally
          SL.Free;
        end;
        Inc(I, 2);
      end
      else
        Inc(I);
    end;

    Run(ParamStr(1), ParamStr(2), Bps, Evals, Script, Seconds);
  except
    on E: Exception do begin
      Writeln(E.ClassName + ': ' + E.Message);
      Halt(9);
    end;
  end;
end.
