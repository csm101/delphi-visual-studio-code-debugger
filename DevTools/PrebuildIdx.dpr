program PrebuildIdx;

// Builds the `.idx` symbol-index sidecars for a whole directory of Delphi
// debug-symbol files up front, so a debug session never pays the cold build.
//
// Why this exists
// ---------------
// TRsmFile caches its parsed index in a `<file>.idx` sidecar next to the input
// and reloads it in 1-18 ms. Without the sidecar it has to scan the container:
// ~520 ms for a 45 MB .dcp on a fast machine. That cold cost is paid on the
// thread the debugger is waiting on, and when the interactive wait budget
// expires the lookup answers from a half-built index -- which is what makes
// variables and types show up late (or not at all) at the first breakpoint.
//
// The RTL/third-party corpus (Embarcadero's Dcp\Win64 is ~620 files / ~855 MB
// here) never changes between builds, so its sidecars can be built once,
// offline. Your OWN packages are recompiled constantly and their sidecars are
// invalidated by mtime on every build -- this tool does not help there.
//
// The sidecar contract is mtime-only (fresh when idx mtime >= source mtime)
// and reader-independent, so a sidecar built here is byte-for-byte the one the
// debugger would have built itself: it is the same index-build and sidecar
// publication code path, not a reimplementation. Running it while a debug
// session is live is safe -- publication is a temp file plus an atomic rename,
// and a writer that loses the race leaves the other one's sidecar alone.
//
// Usage:
//   PrebuildIdx <dir-or-file> [-r] [-j N] [-verify] [-force]
//     -r        recurse into subdirectories
//     -j N      N files in flight at once (default 2). Each build already fans
//               its scans out across cores, so a large N oversubscribes and
//               can be SLOWER than 2.
//     -verify   rebuild every sidecar and compare SHA-256 with the one that
//               was there. Reports mismatches; used to prove a parser change
//               kept the format byte-identical.
//     -force    rebuild even when the existing sidecar is fresh.

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.SyncObjs,
  System.Diagnostics,
  System.Hash,
  System.Generics.Collections,
  Winapi.Windows,
  DebugInfoTypes  in '..\DebuggerCore\DebugInfoTypes.pas',
  RsmFileReader   in '..\DebuggerCore\RsmFileReader.pas';

type
  TOptions = record
    Root:      string;
    Recurse:   Boolean;
    Workers:   Integer;
    Verify:    Boolean;
    Force:     Boolean;
  end;

  TTotals = record
    Built:     Integer;
    Skipped:   Integer;
    Verified:  Integer;
    Mismatch:  Integer;
    Failed:    Integer;
    Millis:    Double;
  end;

function ParseOptions(out Opt: TOptions): Boolean;
begin
  Opt := Default(TOptions);
  Opt.Workers := 2;
  var SkipNext := False;
  for var I := 1 to ParamCount do begin
    if SkipNext then begin
      SkipNext := False;
      Continue;
    end;
    var P := ParamStr(I);
    if SameText(P, '-r') then
      Opt.Recurse := True
    else if SameText(P, '-verify') then
      Opt.Verify := True
    else if SameText(P, '-force') then
      Opt.Force := True
    else if SameText(P, '-j') then begin
      Opt.Workers := StrToIntDef(ParamStr(I + 1), 2);
      if Opt.Workers < 1 then
        Opt.Workers := 1;
      SkipNext := True;
    end
    else if (Opt.Root = '') and not P.StartsWith('-') then
      Opt.Root := P;
  end;
  Result := Opt.Root <> '';
end;

function CollectInputs(const Opt: TOptions): TArray<string>;
begin
  if TFile.Exists(Opt.Root) then
    Exit(TArray<string>.Create(Opt.Root));
  if not TDirectory.Exists(Opt.Root) then begin
    Writeln('not found: ', Opt.Root);
    Exit(nil);
  end;
  var Mode := TSearchOption.soTopDirectoryOnly;
  if Opt.Recurse then
    Mode := TSearchOption.soAllDirectories;
  var Found := TList<string>.Create;
  try
    // .dcp and .rsm only. A .bpl is a PE image, not a symbol container, and
    // TRsmFile rejects it on the CSH7/PKX0 magic check.
    for var Ext in TArray<string>.Create('*.dcp', '*.rsm') do
      Found.AddRange(TDirectory.GetFiles(Opt.Root, Ext, Mode));
    Found.Sort;
    Result := Found.ToArray;
  finally
    Found.Free;
  end;
end;

function DirectoryIsWritable(const Dir: string): Boolean;
begin
  // PublishSidecar swallows every write failure, so a read-only
  // directory would make this tool silently accomplish nothing. Probe once.
  var Probe := TPath.Combine(Dir, '.idxprobe_' + IntToStr(GetCurrentProcessId));
  try
    TFile.WriteAllText(Probe, 'x');
    TFile.Delete(Probe);
    Result := True;
  except
    Result := False;
  end;
end;

// Delegates to the reader so this tool skips exactly the sidecars the debugger
// would actually load. Answering the question locally is how 144 sidecars came
// to be reported "already fresh" after a format bump while the debugger was
// rejecting every one of them.
function SidecarIsFresh(const Path: string): Boolean;
begin
  Result := TRsmFile.SidecarIsUsable(Path);
end;

// Builds (or rebuilds) one sidecar. Returns the elapsed milliseconds.
function BuildSidecar(const Path: string): Double;
begin
  var SW := TStopwatch.StartNew;
  var Rsm := TRsmFile.Create;
  try
    Rsm.LoadFromFile(Path);
    Rsm.WaitForIndex;
  finally
    Rsm.Free;
  end;
  SW.Stop;
  Result := SW.Elapsed.TotalMilliseconds;
end;

procedure ProcessOne(const Path: string; const Opt: TOptions; var Totals: TTotals;
  Report: TProc<string>);
begin
  var Sidecar := Path + '.idx';
  var Name    := TPath.GetFileName(Path);

  if Opt.Verify then begin
    var Before := '';
    if TFile.Exists(Sidecar) then begin
      Before := THashSHA2.GetHashStringFromFile(Sidecar, SHA256);
      TFile.Delete(Sidecar);
    end;
    var Ms := BuildSidecar(Path);
    Totals.Millis := Totals.Millis + Ms;
    if not TFile.Exists(Sidecar) then begin
      Inc(Totals.Failed);
      Report(Format('%-42s FAILED (no sidecar written)', [Name]));
      Exit;
    end;
    var After := THashSHA2.GetHashStringFromFile(Sidecar, SHA256);
    if Before = '' then begin
      Inc(Totals.Built);
      Report(Format('%-42s built    %7.0f ms  %s', [Name, Ms, After.Substring(0, 16)]));
    end
    else if Before = After then begin
      Inc(Totals.Verified);
      Report(Format('%-42s verified %7.0f ms  %s', [Name, Ms, After.Substring(0, 16)]));
    end
    else begin
      Inc(Totals.Mismatch);
      Report(Format('%-42s MISMATCH old=%s new=%s',
        [Name, Before.Substring(0, 16), After.Substring(0, 16)]));
    end;
    Exit;
  end;

  if SidecarIsFresh(Path) and not Opt.Force then begin
    Inc(Totals.Skipped);
    Exit;
  end;

  var Ms := BuildSidecar(Path);
  Totals.Millis := Totals.Millis + Ms;
  if TFile.Exists(Sidecar) then begin
    Inc(Totals.Built);
    Report(Format('%-42s built    %7.0f ms  %d bytes',
      [Name, Ms, TFile.GetSize(Sidecar)]));
  end
  else begin
    // Either the container has no parsable symbol records, or the directory
    // is not writable. The writability probe below distinguishes the two.
    Inc(Totals.Failed);
    Report(Format('%-42s no sidecar (unparsable or not writable)', [Name]));
  end;
end;

procedure Run(const Opt: TOptions; const Inputs: TArray<string>);
var
  Totals: TTotals;
begin
  Totals := Default(TTotals);
  var Cursor := 0;
  var Guard  := TCriticalSection.Create;
  try
    var Report: TProc<string> :=
      procedure(S: string)
      begin
        Writeln(S);
        Flush(Output);
      end;

    var Work: TProc :=
      procedure
      begin
        while True do begin
          var Index: Integer;
          Guard.Acquire;
          try
            if Cursor > High(Inputs) then Exit;
            Index := Cursor;
            Inc(Cursor);
          finally
            Guard.Release;
          end;

          var Local := Default(TTotals);
          try
            ProcessOne(Inputs[Index], Opt, Local,
              procedure(S: string)
              begin
                Guard.Acquire;
                try
                  Report(S);
                finally
                  Guard.Release;
                end;
              end);
          except
            on E: Exception do begin
              Inc(Local.Failed);
              Guard.Acquire;
              try
                Report(TPath.GetFileName(Inputs[Index]) + ' ERROR: ' + E.Message);
              finally
                Guard.Release;
              end;
            end;
          end;

          Guard.Acquire;
          try
            Inc(Totals.Built,    Local.Built);
            Inc(Totals.Skipped,  Local.Skipped);
            Inc(Totals.Verified, Local.Verified);
            Inc(Totals.Mismatch, Local.Mismatch);
            Inc(Totals.Failed,   Local.Failed);
            Totals.Millis := Totals.Millis + Local.Millis;
          finally
            Guard.Release;
          end;
        end;
      end;

    var SW := TStopwatch.StartNew;
    var Threads: TArray<TThread>;
    SetLength(Threads, Opt.Workers);
    for var I := 0 to High(Threads) do begin
      Threads[I] := TThread.CreateAnonymousThread(Work);
      Threads[I].FreeOnTerminate := False;
      Threads[I].Start;
    end;
    for var T in Threads do begin
      T.WaitFor;
      T.Free;
    end;
    SW.Stop;

    Writeln;
    Writeln(Format('%d file(s): %d built, %d already fresh, %d verified, ' +
                   '%d MISMATCH, %d failed',
      [Length(Inputs), Totals.Built, Totals.Skipped, Totals.Verified,
       Totals.Mismatch, Totals.Failed]));
    Writeln(Format('wall %.1f s (sum of per-file build time %.1f s, %d worker(s))',
      [SW.Elapsed.TotalSeconds, Totals.Millis / 1000, Opt.Workers]));
    if Totals.Mismatch > 0 then
      ExitCode := 1;
  finally
    Guard.Free;
  end;
end;

begin
  try
    var Opt: TOptions;
    if not ParseOptions(Opt) then begin
      Writeln('usage: PrebuildIdx <dir-or-file> [-r] [-j N] [-verify] [-force]');
      Halt(2);
    end;

    var Inputs := CollectInputs(Opt);
    if Length(Inputs) = 0 then begin
      Writeln('nothing to do');
      Halt(0);
    end;

    var ProbeDir := TPath.GetDirectoryName(Inputs[0]);
    if not DirectoryIsWritable(ProbeDir) then
      Writeln('WARNING: ', ProbeDir, ' is not writable -- sidecars cannot be ',
              'created there and the debugger will keep rebuilding the index ',
              'on every session.');

    Writeln(Format('%d file(s) under %s', [Length(Inputs), Opt.Root]));
    Run(Opt, Inputs);
  except
    on E: Exception do begin
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
