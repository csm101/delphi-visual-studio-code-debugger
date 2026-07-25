program Win32SessionProbe;

// Drives a real TDebugSession against a target and reports what happened:
// whether the breakpoint bound, whether it fired, where the session stopped and
// what the call stack looks like.
//
// Written for the Win32 work, but nothing here is 32-bit specific -- point it at
// a 64-bit target and it exercises exactly the same path, which is the point:
// the two runs are directly comparable, so a difference is a real difference and
// not an artefact of testing them differently.
//
// The adapter picks TWinDebugger or TWin32Debugger from the target's PE header,
// so this probe needs no switch of its own.
//
//   Win32SessionProbe <exe> <map> <rsm> <sourceRoot> <sourceBaseName> <marker>
//
// <marker> is the text inside a `{BP:...}` tag in the source file.

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.StrUtils, Winapi.Windows,
  DebugSessionTypes, DebugSession;

function MarkerLine(const SourcePath, Marker: string): Integer;
var
  Lines: TStringList;
begin
  Result := 0;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(SourcePath);
    var Tag := '{BP:' + Marker + '}';
    for var I := 0 to Lines.Count - 1 do
      if Lines[I].Contains(Tag) then
        Exit(I + 1);  // 1-based
  finally
    Lines.Free;
  end;
end;

procedure Run(const ExePath, MapPath, RsmPath, SourceRoot, SourceBaseName,
  Marker: string);
begin
  var SourcePath := IncludeTrailingPathDelimiter(SourceRoot) + SourceBaseName;
  var Line := MarkerLine(SourcePath, Marker);
  if Line <= 0 then begin
    Writeln(Format('marker {BP:%s} not found in %s', [Marker, SourcePath]));
    Halt(2);
  end;
  Writeln(Format('marker {BP:%s} -> %s:%d', [Marker, SourceBaseName, Line]));

  var Session := TDebugSession.Create;
  try
    var Opts: TLaunchOptions;
    Opts             := Default(TLaunchOptions);
    Opts.ExePath     := ExePath;
    Opts.MapPath     := MapPath;
    Opts.RsmPath     := RsmPath;
    Opts.SourceRoot  := SourceRoot;
    Opts.StopAtEntry := False;

    if not Session.Launch(Opts) then begin
      Writeln('LAUNCH FAILED');
      Halt(3);
    end;
    Writeln('launched ' + ExePath);

    var LineSpec: TBpLineSpec;
    LineSpec      := Default(TBpLineSpec);
    LineSpec.Line := Line;
    var Bound := Session.SetBreakpoints(SourceBaseName, [LineSpec]);
    for var B in Bound do
      Writeln(Format('  breakpoint line %d verified=%s',
        [B.Line, BoolToStr(B.Verified, True)]));

    var Deadline := GetTickCount64 + 60000;
    while (Session.State <> dsStopped) and (not Session.HasExited) and
          (GetTickCount64 < Deadline) do
      Session.Pump;

    if Session.HasExited then begin
      Writeln('RESULT: target exited without hitting the breakpoint');
      Halt(4);
    end;
    if Session.State <> dsStopped then begin
      Writeln('RESULT: timed out waiting for a stop');
      Halt(5);
    end;

    var FnName, SrcFile: string;
    var StopLine: Integer;
    if Session.GetCurrentLocation(FnName, SrcFile, StopLine) then
      Writeln(Format('STOPPED in %s at %s:%d',
        [FnName, ExtractFileName(SrcFile), StopLine]))
    else
      Writeln('STOPPED but no current location resolved');

    Writeln('call stack:');
    var Frames := Session.GetCallStack;
    for var F in Frames do
      Writeln(Format('  #%d  %-40s %s:%d  [%s]  ip=%s',
        [F.Index,
         IfThen(F.FunctionName <> '', F.FunctionName, '<no name>'),
         ExtractFileName(F.SourceFile), F.SourceLine,
         F.ModuleName, IntToHex(F.IP, 16)]));
    Writeln(Format('frame count: %d', [Length(Frames)]));
  finally
    Session.Free;
  end;
end;

begin
  try
    if ParamCount < 6 then begin
      Writeln('usage: Win32SessionProbe <exe> <map> <rsm> <sourceRoot> ' +
              '<sourceBaseName> <marker>');
      Halt(1);
    end;
    Run(ParamStr(1), ParamStr(2), ParamStr(3), ParamStr(4), ParamStr(5),
        ParamStr(6));
  except
    on E: Exception do begin
      Writeln(E.ClassName + ': ' + E.Message);
      Halt(9);
    end;
  end;
end.
