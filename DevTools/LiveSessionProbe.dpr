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
  DebugTarget,                       // FrameOriginName for the stack print
  DapProtocol,                       // SetDapLogEnabled: engine-side diagnostics
  DebugSessionTypes, DebugSession;

type
  TBpRequest = record
    SourceFile: string;   // basename as the user typed it
    Line:       Integer;
  end;

  // Captures the debuggee's exit code. `OnSessionExited` is `of object`, so it
  // needs an instance to hang off; this is that instance and nothing more.
  TExitWatch = class
    Code: Integer;
    procedure Note(ExitCode: Integer);
  end;

var
  GExitWatch: TExitWatch;

procedure TExitWatch.Note(ExitCode: Integer);
begin
  Code := ExitCode;
end;

function GExitCode: Integer;
begin
  Result := GExitWatch.Code;
end;

// A plain-language reading, because the number alone invites the wrong
// conclusion. 0 means the program decided to stop; anything else means it was
// stopped, and under a debugger that is worth investigating rather than
// assuming the user clicked the X.
function ExitCodeMeaning(Code: Integer): string;
begin
  if Code = 0 then
    Exit('normal termination -- e.g. the window was closed');
  if Cardinal(Code) >= $C0000000 then
    Exit('NTSTATUS exception -- the process was killed by a fault');
  Result := 'non-zero: the program terminated itself deliberately';
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
    else if SameText(Cmd, 'rtti') then begin
      // Runtime RTTI view of a local's class, independent of the static member
      // tables -- the measurement that says whether RTTI carries INSTANTIATED
      // generic types where dcc32's debug info carries only `%TList__1`.
      var Target := Session.Evaluate(Arg);
      if not Target.Success then
        Writeln('    rtti ' + Arg + ' => ' + Target.ErrorText)
      else begin
        var Obj := Target.RawValue;
        Writeln(Format('    rtti %s: runtimeClass="%s" obj=$%x',
          [Arg, Session.Rtti.GetInstanceClassName(Obj), Obj]));
        for var P in Session.Rtti.GetClassProperties(Obj) do
          Writeln(Format('        prop  %-14s kind=%-3d type="%s"',
            [P.Name, P.PropTypeKind, P.PropTypeName]));
        for var F in Session.Rtti.ExpandClass(Obj) do
          Writeln(Format('        field %-14s kind=%-3d type="%s" off=%d',
            [F.Name, F.TypeKind, F.TypeName, F.FieldOffset]));
      end;
    end
    else if SameText(Cmd, 'imt') then begin
      // `imt <expr>` -- walks the exact chain the adapter walks to recover the
      // object behind an interface reference:
      //   IfacePtr -> [IfacePtr] = IMT -> [IMT] = first method = adjustor thunk
      // and dumps the thunk's leading bytes. Every link is printed, so a broken
      // assumption shows at the step where it breaks instead of as a silent
      // "no label".
      var Target := Session.Evaluate(Arg);
      if not Target.Success then
        Writeln('    imt ' + Arg + ' => ' + Target.ErrorText)
      else begin
        var IfacePtr := Target.RawValue;
        // IsClassInstance is printed because the display path GATES the whole
        // recovery on it being False: an interface reference points INTO an
        // object, so a True here silently disables the label.
        Writeln(Format('    imt %s: iface=$%x type="%s" isClassInstance=%s',
          [Arg, IfacePtr, Target.TypeName,
           BoolToStr(Session.Rtti.IsClassInstance(IfacePtr), True)]));
        var Imt: UInt64 := 0;
        if not Session.Rtti.ReadTargetPointer(IfacePtr, Imt) then
          Writeln('        [IfacePtr] unreadable')
        else begin
          Writeln(Format('        IMT       = $%x', [Imt]));
          var M0: UInt64 := 0;
          if not Session.Rtti.ReadTargetPointer(Imt, M0) then
            Writeln('        [IMT] unreadable')
          else begin
            Writeln(Format('        method[0] = $%x', [M0]));
            var Dump := '';
            var Step := UInt64(Session.Rtti.PointerSize);
            for var K := 0 to 3 do begin
              var W: UInt64 := 0;
              if not Session.Rtti.ReadTargetPointer(M0 + UInt64(K) * Step, W) then
                Break;
              for var B := 0 to Integer(Step) - 1 do
                Dump := Dump + IntToHex((W shr (B * 8)) and $FF, 2) + ' ';
            end;
            Writeln('        thunk     = ', Trim(Dump));
          end;
        end;
      end;
    end
    else if SameText(Cmd, 'set') then begin
      // `set <Name> <Value>` -- write a local, then show what the debugger
      // reads back, which is what catches a write at the wrong width.
      var NameEnd := Arg.IndexOf(' ');
      if NameEnd <= 0 then
        Writeln('    set needs: set <name> <value>')
      else begin
        var VarName  := Arg.Substring(0, NameEnd).Trim;
        var NewText  := Arg.Substring(NameEnd + 1).Trim;
        var NewValue, NewType: string;
        if Session.SetLocalVariable(VarName, NewText, NewValue, NewType) then
          Writeln(Format('    set %s := %s -> %s [%s]',
            [VarName, NewText, NewValue, NewType]))
        else
          Writeln(Format('    set %s := %s FAILED: %s',
            [VarName, NewText, NewValue]));
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
    // entry= is printed because a NAME and a LINE can both be present for an
    // address the debugger has no FUNCTION for -- the name comes from the
    // nearest preceding symbol and the line from the nearest preceding line
    // record, so a bogus frame reads exactly like a real one. entry=0 says the
    // resolver could not place the address in any routine, which is the tell.
    //
    // origin= names the mechanism that emitted the frame. A stack is assembled
    // by several independent ones (EBP chain, prologue probe, frameless
    // recovery, dbghelp tail) and they produce identical-looking records, so
    // without it a frame that turns out to be bogus gives no clue as to which
    // one to go and read.
    Writeln(Format('    #%-2d %-44s %s:%d  [%s]  ip=%s entry=%s origin=%s',
      [F.Index,
       IfThen(F.FunctionName <> '', F.FunctionName, '<no name>'),
       IfThen(F.SourceFile <> '', ExtractFileName(F.SourceFile), '-'),
       F.SourceLine, F.ModuleName, IntToHex(F.IP, 8),
       IntToHex(F.FuncEntryVA, 8), FrameOriginName(F.Origin)]));
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
  const Evals, Script: TArray<string>; Seconds: Integer; const TargetArgs: string);
begin
  var Session := TDebugSession.Create;
  Session.OnSessionExited := GExitWatch.Note;
  try
    var Opts := Default(TLaunchOptions);
    Opts.ExePath     := ExePath;
    Opts.SourceRoot  := SourceRoot;
    Opts.StopAtEntry := False;
    // Several TestTarget scenarios only run behind a command-line switch, so a
    // breakpoint in them verifies and then never hits without this.
    Opts.Args        := TargetArgs;

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
      // The CODE matters, not just the fact. "The target exited" reads the same
      // whether a human closed the window or the process died under the
      // debugger, and those call for opposite conclusions. 0 is a normal close.
      Writeln(Format('target exited, exit code %d (%s)',
        [GExitCode, ExitCodeMeaning(GExitCode)]))
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
  // The engine's own log carries what the printed frames cannot: WHY a stack
  // stopped where it did. A probe exists to be diagnosed from, so this is on
  // unconditionally rather than behind a switch nobody remembers to pass.
  SetDapLogEnabled(True);
  GExitWatch := TExitWatch.Create;
  try
    if ParamCount < 3 then begin
      Writeln('usage: LiveSessionProbe <exe> <sourceRoot> <file:line>[,<file:line>...]');
      Writeln('                        [-seconds N] [-eval <expr>] [-script <file>]');
      Writeln('                        [-targetargs "<args passed to the debuggee>"]');
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
    var TargetArgs := '';
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
      else if SameText(ParamStr(I), '-targetargs') and (I < ParamCount) then begin
        TargetArgs := ParamStr(I + 1);
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

    Run(ParamStr(1), ParamStr(2), Bps, Evals, Script, Seconds, TargetArgs);
  except
    on E: Exception do begin
      Writeln(E.ClassName + ': ' + E.Message);
      Halt(9);
    end;
  end;
end.
