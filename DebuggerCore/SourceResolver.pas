unit SourceResolver;

// Resolves a source-file BASENAME (as carried by MAP/RSM/TD32 line tables) to a
// full on-disk path, searching a set of configured roots. Extracted verbatim
// from TDapServer so that both the DAP frontend and the MCP frontend (via
// TDebugSession) share ONE implementation and one session-stable cache.
//
// Roots (in priority order): an explicit SourceRoot, the debuggee EXE directory
// and its parent / grandparent, and any number of ExtraSourcePaths. Each root is
// probed at the top level and one level deep; ExtraSourcePaths get two levels and
// SourceRoot a depth-capped recursive scan as a last resort.

interface

uses
  System.SysUtils, System.IOUtils, System.Generics.Collections,
  DebugTarget;

type
  TSourceResolver = class
  private
    FSourceRoot:       string;
    FExePath:          string;
    FExtraSourcePaths: TArray<string>;
    FCache:            TDictionary<string, string>;  // lcase key -> path ('' = known-missing)
    function ResolveUncached(const BaseName: string): string;
  public
    constructor Create;
    destructor Destroy; override;

    // Configure the roots for a session. Clears the cache (roots changed).
    procedure Configure(const ASourceRoot, AExePath: string;
      const AExtraSourcePaths: TArray<string>);

    // Basename -> full path, cached. '' when not found. Strips surrounding
    // quotes / embedded NULs and normalizes separators first.
    function Resolve(const BaseName: string): string;

    // Unit name (namespace-stripped, as in a MAP public) -> its .pas path,
    // trying the bare name then the common Delphi namespace prefixes.
    function ResolveUnitToSource(const UnitName: string): string;

    // Trims the leading RTL exception-raise plumbing so a `raise` lands on the
    // raise site instead of inside the RTL. GATED ON THE EXCEPTION KIND: it
    // trims for a Delphi `raise` and returns the frames untouched for a
    // hardware fault, whose top frame is the fault itself. Pass
    // IDebugTarget.LastExceptionIsDelphiRaise; pass False when not stopped on an
    // exception at all.
    function TrimRaisePlumbing(const Frames: TArray<TStackFrame>;
      IsDelphiRaise: Boolean): TArray<TStackFrame>;
    // True when the frame's function name IS one of the known raise-plumbing
    // routines. Exact match on the last name segment, never a substring: a user
    // routine called AssertConfig must not read as `@Assert`.
    class function IsRaisePlumbingFrame(const FunctionName: string): Boolean; static;
  end;

implementation

constructor TSourceResolver.Create;
begin
  inherited Create;
  FCache := TDictionary<string, string>.Create;
end;

destructor TSourceResolver.Destroy;
begin
  FCache.Free;
  inherited;
end;

procedure TSourceResolver.Configure(const ASourceRoot, AExePath: string;
  const AExtraSourcePaths: TArray<string>);
begin
  FSourceRoot       := ASourceRoot;
  FExePath          := AExePath;
  FExtraSourcePaths := AExtraSourcePaths;
  FCache.Clear;
end;

function TSourceResolver.Resolve(const BaseName: string): string;
begin
  var NormalizedName := Trim(BaseName);
  var NullPos := Pos(#0, NormalizedName);
  if NullPos > 0 then
    SetLength(NormalizedName, NullPos - 1);
  NormalizedName := Trim(NormalizedName);
  if (Length(NormalizedName) >= 2) and
     (((NormalizedName[1] = '"') and (NormalizedName[High(NormalizedName)] = '"')) or
      ((NormalizedName[1] = '''') and (NormalizedName[High(NormalizedName)] = ''''))) then
    NormalizedName := Trim(Copy(NormalizedName, 2, Length(NormalizedName) - 2));

  if NormalizedName = '' then
    Exit('');

  var Key := LowerCase(StringReplace(NormalizedName, '/', PathDelim, [rfReplaceAll]));
  if FCache.TryGetValue(Key, Result) then
    Exit;
  Result := ResolveUncached(NormalizedName);
  FCache.AddOrSetValue(Key, Result);
end;

function TSourceResolver.ResolveUncached(const BaseName: string): string;

  function SanitizeSourceName(const RawName: string): string;
  begin
    Result := Trim(RawName);
    if Result = '' then
      Exit;
    var NullPos := Pos(#0, Result);
    if NullPos > 0 then
      SetLength(Result, NullPos - 1);
    Result := Trim(Result);
    if (Length(Result) >= 2) and
       (((Result[1] = '"') and (Result[High(Result)] = '"')) or
        ((Result[1] = '''') and (Result[High(Result)] = ''''))) then
      Result := Trim(Copy(Result, 2, Length(Result) - 2));
  end;

  function NormalizeSeparators(const PathValue: string): string;
  begin
    Result := StringReplace(PathValue, '/', PathDelim, [rfReplaceAll]);
  end;

  function TryFile(const Candidate: string): string;
  begin
    Result := '';
    if Candidate = '' then
      Exit;
    if FileExists(Candidate) then
      Result := Candidate;
  end;

  function TryRoot(const Root, RelativeName, BaseOnlyName: string): string;
  begin
    Result := '';
    if Root = '' then
      Exit;
    Result := TryFile(TPath.Combine(Root, RelativeName));
    if Result <> '' then
      Exit;
    if not SameText(RelativeName, BaseOnlyName) then
      Result := TryFile(TPath.Combine(Root, BaseOnlyName));
  end;

  function TryOneLevel(const Root, RelativeName, BaseOnlyName: string): string;
  var
    SR: TSearchRec;
  begin
    Result := TryRoot(Root, RelativeName, BaseOnlyName);
    if Result <> '' then
      Exit;
    if FindFirst(IncludeTrailingPathDelimiter(Root) + '*', faDirectory, SR) = 0 then
    try
      repeat
        if (SR.Attr and faDirectory <> 0) and (SR.Name <> '.') and (SR.Name <> '..') then begin
          var SubRoot := IncludeTrailingPathDelimiter(Root) + SR.Name;
          Result := TryRoot(SubRoot, RelativeName, BaseOnlyName);
          if Result <> '' then
            Exit;
        end;
      until FindNext(SR) <> 0;
    finally
      System.SysUtils.FindClose(SR);
    end;
  end;

  function TryTwoLevels(const Root, RelativeName, BaseOnlyName: string): string;
  var
    SR: TSearchRec;
  begin
    Result := TryOneLevel(Root, RelativeName, BaseOnlyName);
    if Result <> '' then
      Exit;
    if FindFirst(IncludeTrailingPathDelimiter(Root) + '*', faDirectory, SR) = 0 then
    try
      repeat
        if (SR.Attr and faDirectory <> 0) and (SR.Name <> '.') and (SR.Name <> '..') then begin
          var Sub := IncludeTrailingPathDelimiter(Root) + SR.Name;
          Result := TryOneLevel(Sub, RelativeName, BaseOnlyName);
          if Result <> '' then
            Exit;
        end;
      until FindNext(SR) <> 0;
    finally
      System.SysUtils.FindClose(SR);
    end;
    Result := '';
  end;

  function TryRecursive(const Root, RelativeName, BaseOnlyName: string;
    MaxDepth: Integer): string;
    procedure Scan(const Dir: string; Depth: Integer; out FoundPath: string);
    var
      SR: TSearchRec;
    begin
      FoundPath := TryRoot(Dir, RelativeName, BaseOnlyName);
      if FoundPath <> '' then
        Exit;
      if Depth >= MaxDepth then
        Exit;
      if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faDirectory, SR) = 0 then
      try
        repeat
          if (SR.Attr and faDirectory = 0) or (SR.Name = '.') or (SR.Name = '..') then
            Continue;
          if SameText(SR.Name, '.git') or SameText(SR.Name, '__history') or
             SameText(SR.Name, '__recovery') then
            Continue;
          var SubDir := IncludeTrailingPathDelimiter(Dir) + SR.Name;
          Scan(SubDir, Depth + 1, FoundPath);
          if FoundPath <> '' then
            Exit;
        until FindNext(SR) <> 0;
      finally
        System.SysUtils.FindClose(SR);
      end;
    end;
  begin
    Result := '';
    if Root = '' then
      Exit;
    Scan(Root, 0, Result);
  end;

begin
  var RelativeName := NormalizeSeparators(SanitizeSourceName(BaseName));
  if RelativeName = '' then
    Exit('');
  var BaseOnlyName := ExtractFileName(RelativeName);
  if BaseOnlyName = '' then
    BaseOnlyName := RelativeName;

  // Already an absolute path that exists on disk: use it directly.
  if TPath.IsPathRooted(RelativeName) then begin
    var FullCandidate := TPath.GetFullPath(RelativeName);
    if FileExists(FullCandidate) then
      Exit(FullCandidate);
    RelativeName := BaseOnlyName;
  end;

  if FSourceRoot <> '' then begin
    Result := TryRoot(FSourceRoot, RelativeName, BaseOnlyName);
    if Result <> '' then
      Exit;
    Result := TryOneLevel(FSourceRoot, RelativeName, BaseOnlyName);
    if Result <> '' then
      Exit;
  end;

  if FExePath <> '' then begin
    var ExeDir := ExtractFileDir(FExePath);
    var ParentDir := ExtractFileDir(ExeDir);
    var GrandParentDir := ExtractFileDir(ParentDir);
    Result := TryRoot(ExeDir, RelativeName, BaseOnlyName);
    if Result <> '' then
      Exit;
    Result := TryRoot(ParentDir, RelativeName, BaseOnlyName);
    if Result <> '' then
      Exit;
    Result := TryRoot(GrandParentDir, RelativeName, BaseOnlyName);
    if Result <> '' then
      Exit;
  end;

  for var P in FExtraSourcePaths do
    if P <> '' then begin
      Result := TryRoot(P, RelativeName, BaseOnlyName);
      if Result <> '' then
        Exit;
      Result := TryTwoLevels(P, RelativeName, BaseOnlyName);
      if Result <> '' then
        Exit;
    end;

  if FSourceRoot <> '' then begin
    Result := TryRecursive(FSourceRoot, RelativeName, BaseOnlyName, 6);
    if Result <> '' then
      Exit;
  end;

  Result := '';
end;

// KEPT, though TrimRaisePlumbing no longer calls it: the names are measured and
// a caller that needs to recognise plumbing frames individually (a stack
// annotator, a future step-to-handler) should use this rather than re-deriving
// the list. It is NOT sufficient for trimming, and that is the point worth
// remembering -- see TrimRaisePlumbing.
class function TSourceResolver.IsRaisePlumbingFrame(
  const FunctionName: string): Boolean;
const
  // The RTL routines that stand between `raise` and the raise site, plus the two
  // OS entry points that can appear above them. Compiler-generated names carry a
  // leading '@'; the Itanium-mangled forms drop it, so both spellings are here.
  PLUMBING: array[0..13] of string = (
    '@RaiseExcept', '_RaiseExcept', 'RaiseExcept',
    '@RaiseAtExcept', '@RaiseAgain',
    '@HandleAnyException', '@HandleFinally', '@HandleOnException',
    '@HandleAutoException',
    '@Assert', 'AssertErrorHandler',
    'RaiseException', 'RtlRaiseException', 'KiUserExceptionDispatcher');
begin
  Result := False;
  if FunctionName = '' then
    Exit;

  // Strip a unit qualifier (System.@RaiseExcept -> @RaiseExcept) and any
  // trailing offset the symbolication may have appended (name+0x1C -> name).
  var Name := FunctionName;
  var Plus := Pos('+', Name);
  if Plus > 0 then
    Name := Copy(Name, 1, Plus - 1);
  var Dot := LastDelimiter('.', Name);
  if Dot > 0 then
    Name := Copy(Name, Dot + 1, Length(Name) - Dot);
  Name := Trim(Name);

  for var Candidate in PLUMBING do
    if SameText(Name, Candidate) then
      Exit(True);
end;

function TSourceResolver.TrimRaisePlumbing(const Frames: TArray<TStackFrame>;
  IsDelphiRaise: Boolean): TArray<TStackFrame>;
begin
  Result := Frames;

  // THE GATE IS THE EXCEPTION KIND, and it is a fact rather than an inference.
  //
  // For a Delphi `raise` ($0EEDFADE) everything above the raise site is RTL and
  // OS plumbing BY CONSTRUCTION -- the raise came from user code, so the frames
  // between it and here cannot be anything else. Trimming to the first frame
  // with resolvable source is therefore exact for this kind.
  //
  // For a hardware fault the top frame IS the fault, and trimming it discards
  // the one thing the debugger was opened for.
  //
  // A by-NAME criterion was tried first and MEASURED not to work: at a Delphi
  // raise frame 0 is a NAMELESS kernelbase frame, so a name list halts the trim
  // immediately and never reaches @RaiseExcept. There is nothing there to name.
  if not IsDelphiRaise then
    Exit;

  for var I := 0 to High(Frames) do
    if (Frames[I].SourceFile <> '') and (Resolve(Frames[I].SourceFile) <> '') then begin
      if I > 0 then
        Result := Copy(Frames, I, Length(Frames) - I);
      Exit;
    end;
end;

function TSourceResolver.ResolveUnitToSource(const UnitName: string): string;
begin
  Result := '';
  if UnitName = '' then
    Exit;
  Result := Resolve(UnitName + '.pas');
  if Result <> '' then
    Exit;
  for var Prefix in ['System', 'Vcl', 'Winapi', 'Data', 'System.Win', 'Vcl.Imaging',
                     'Data.Win', 'Xml', 'Soap', 'Web', 'FMX', 'System.Net', 'Vcl.Touch',
                     'Bde', 'IBX', 'Datasnap'] do begin
    Result := Resolve(Prefix + '.' + UnitName + '.pas');
    if Result <> '' then
      Exit;
  end;
  Result := '';
end;

end.
