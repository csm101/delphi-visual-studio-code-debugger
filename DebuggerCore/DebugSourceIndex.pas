unit DebugSourceIndex;

{
  Per-module source-file membership index.

  Answers "does this debug module's symbols reference source file X?" in O(1)
  after the first query per module.

  First call for a module:
    1. If a fresh .ddbidx sidecar next to the debug source exists -> load it.
    2. Otherwise -> scan the debug source -> write .ddbidx for next run.

  The sidecar is invalidated when the debug source file is newer than the
  index (mtime comparison). No manual invalidation needed.

  Sidecar location: <debug-source-path>.ddbidx
    e.g. mylib.map.ddbidx  next to  mylib.map
    e.g. mylib.tds.ddbidx  next to  mylib.tds  (future)
  If the directory is read-only, SaveIndex silently skips writing; the index
  is rebuilt in memory each session (still cheaper than a full MAP parse for
  every BP lookup).

  Extending for new formats:
    Subclass TDebugSourceIndex, override BuildFromSource, instantiate where
    the debug source is selected (currently TDllModule.EnsureSourceIndex).
}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.IOUtils;

type
  // Abstract base -- subclasses implement BuildFromSource to populate the
  // file list from their specific debug-info format.
  TDebugSourceIndex = class
  private
    FSourcePath: string;
    FIndexPath:  string;
    FFiles:      TDictionary<string, Boolean>; // lowercase filename -> present
    FLoaded:     Boolean;
    function  IndexIsStale: Boolean;
    function  LoadIndex: Boolean;
    procedure SaveIndex;
  protected
    // Subclass fills Files with lowercased source filenames found in the
    // debug source at SourcePath. Called when no fresh sidecar exists.
    procedure BuildFromSource(Files: TDictionary<string, Boolean>);
      virtual; abstract;
    property  SourcePath: string read FSourcePath;
  public
    constructor Create(const ASourcePath: string);
    destructor  Destroy; override;
    procedure   EnsureLoaded;
    function    ContainsFile(const FileName: string): Boolean;
  end;

  // Index for Delphi .map files.
  // Scans "Line numbers for <file>" section headers -- no full MAP parse.
  TMapSourceIndex = class(TDebugSourceIndex)
  protected
    procedure BuildFromSource(Files: TDictionary<string, Boolean>); override;
  end;

  // TODO: TDSSourceIndex
  //   Build from Turbo Debugger Symbol (.tds) files embedded in or alongside
  //   a BPL. Scan the unit-name table in the TDS header to populate Files.

  // TODO: TEmbeddedDebugIndex
  //   Build from DWARF .debug_line or CodeView sections in the PE binary.
  //   Read section headers to locate the unit/file table, extract names.

implementation

const
  INDEX_HEADER = '# delphi-debug-source-index v2';

{ TDebugSourceIndex }

constructor TDebugSourceIndex.Create(const ASourcePath: string);
begin
  inherited Create;
  FSourcePath := ASourcePath;
  FIndexPath  := ASourcePath + '.ddbidx';
  FFiles      := TDictionary<string, Boolean>.Create;
end;

destructor TDebugSourceIndex.Destroy;
begin
  FFiles.Free;
  inherited;
end;

function TDebugSourceIndex.IndexIsStale: Boolean;
begin
  if not FileExists(FIndexPath) then
    Exit(True);
  if not FileExists(FSourcePath) then
    Exit(False); // source gone -- treat existing index as still valid
  try
    Result := TFile.GetLastWriteTimeUtc(FSourcePath) >
              TFile.GetLastWriteTimeUtc(FIndexPath);
  except
    Result := True;
  end;
end;

function TDebugSourceIndex.LoadIndex: Boolean;
var
  SR:        TStreamReader;
  Line:      string;
  HeaderOK:  Boolean;
begin
  HeaderOK := False;
  SR := TStreamReader.Create(FIndexPath, TEncoding.UTF8, False, 4096);
  try
    while not SR.EndOfStream do begin
      Line := Trim(SR.ReadLine);
      if Line = '' then
        Continue;
      if Line.StartsWith('#') then begin
        if SameText(Line, INDEX_HEADER) then
          HeaderOK := True;
        Continue;
      end;
      FFiles.AddOrSetValue(Line, True);
    end;
  finally
    SR.Free;
  end;
  if not HeaderOK then begin
    FFiles.Clear;
    Exit(False);
  end;
  Result := True;
end;

procedure TDebugSourceIndex.SaveIndex;
var
  SW: TStreamWriter;
begin
  try
    SW := TStreamWriter.Create(FIndexPath, False, TEncoding.UTF8);
    try
      SW.WriteLine(INDEX_HEADER);
      for var KV in FFiles do
        SW.WriteLine(KV.Key);
    finally
      SW.Free;
    end;
  except
    // Silently ignore -- read-only directory or other write failures are not
    // fatal; the index is rebuilt from source on the next session.
  end;
end;

procedure TDebugSourceIndex.EnsureLoaded;
begin
  if FLoaded then Exit;
  FLoaded := True;
  if (not IndexIsStale) and LoadIndex then
    Exit;
  FFiles.Clear;
  BuildFromSource(FFiles);
  SaveIndex;
end;

function TDebugSourceIndex.ContainsFile(const FileName: string): Boolean;
begin
  EnsureLoaded;
  Result := FFiles.ContainsKey(LowerCase(ExtractFileName(FileName)));
end;

{ TMapSourceIndex }

procedure TMapSourceIndex.BuildFromSource(Files: TDictionary<string, Boolean>);
// Streams the MAP file looking for "Line numbers for <file>(...)" section
// headers -- the only lines that name source files.  No segment table or
// symbol table parsing is needed.
const
  PREFIX = 'line numbers for ';
var
  SR:          TStreamReader;
  Line, LLine: string;
  Name:        string;
  P:           Integer;
begin
  if not FileExists(SourcePath) then
    Exit;
  SR := TStreamReader.Create(SourcePath, TEncoding.ANSI, False, 65536);
  try
    while not SR.EndOfStream do begin
      Line  := SR.ReadLine;
      LLine := LowerCase(TrimLeft(Line));
      if not LLine.StartsWith(PREFIX) then
        Continue;
      Name := Copy(LLine, Length(PREFIX) + 1, MaxInt);
      // Two MAP shapes seen:
      //   `Line numbers for UnitName(file.pas) segment ...`  <- Delphi output
      //   `Line numbers for file.pas segment ...`            <- C++ Builder
      // We want `file.pas` (the actual source filename) so the
      // ContainsFile lookup keyed by ExtractFileName matches.
      P := Pos('(', Name);
      if P > 0 then begin
        var Q := Pos(')', Name, P + 1);
        if Q > P then
          Name := Copy(Name, P + 1, Q - P - 1)
        else
          Name := Copy(Name, 1, P - 1);
      end else begin
        P := Pos(' segment', Name);
        if P > 0 then
          Name := Copy(Name, 1, P - 1);
      end;
      Name := LowerCase(Trim(ExtractFileName(Name)));
      if Name <> '' then
        Files.AddOrSetValue(Name, True);
    end;
  finally
    SR.Free;
  end;
end;

end.
