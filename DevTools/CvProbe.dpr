program CvProbe;

// Probes a PE file's embedded CodeView debug section via DbgHelp.dll
// (which ships with Windows). Used to evaluate whether DbgHelp can
// substitute for our RsmFileReader when only Delphi `-V` (embedded
// `.debug` section, no separate .rsm) is used at build time.
//
// What we want to know:
//   1. Does DbgHelp recognize Delphi's CodeView output at all?
//   2. Can it resolve source/line for a given RVA?
//   3. Can it list public symbols with addresses?
//   4. Does it expose locals/params (S_BPREL32 records)?
//   5. Does it expose type info (LF_* records) for those locals?
//
// Usage: CvProbe.exe <path-to-exe>
//
// Output is plain text — easy to diff between Delphi-built EXEs and
// known-good MSVC-built EXEs to spot Delphi-specific quirks.

{$APPTYPE CONSOLE}

uses
  System.SysUtils, Winapi.Windows;

type
  IMAGEHLP_LINE64 = record
    SizeOfStruct: DWORD;
    Key:          Pointer;
    LineNumber:   DWORD;
    FileName:     PAnsiChar;
    Address:      UInt64;
  end;
  PIMAGEHLP_LINE64 = ^IMAGEHLP_LINE64;

  SYMBOL_INFO = record
    SizeOfStruct: ULONG;
    TypeIndex:    ULONG;
    Reserved:     array[0..1] of UInt64;
    Index:        ULONG;
    Size:         ULONG;
    ModBase:      UInt64;
    Flags:        ULONG;
    Value:        UInt64;
    Address:      UInt64;
    Register:     ULONG;
    Scope:        ULONG;
    Tag:          ULONG;
    NameLen:      ULONG;
    MaxNameLen:   ULONG;
    Name:         array[0..0] of AnsiChar; // variable
  end;
  PSYMBOL_INFO = ^SYMBOL_INFO;

const
  SYMOPT_LOAD_LINES        = $00000010;
  SYMOPT_DEFERRED_LOADS    = $00000004;
  SYMOPT_FAIL_CRITICAL_ERRORS = $00000200;
  SYMOPT_DEBUG             = $80000000;

  SYMFLAG_VALUEPRESENT     = $00000001;
  SYMFLAG_REGISTER         = $00000008;
  SYMFLAG_REGREL           = $00000010;
  SYMFLAG_FRAMEREL         = $00000020;
  SYMFLAG_PARAMETER        = $00000040;
  SYMFLAG_LOCAL            = $00000080;
  SYMFLAG_FUNCTION         = $00000800;

function SymInitializeW(hProcess: THandle; UserSearchPath: PWideChar;
  fInvadeProcess: BOOL): BOOL; stdcall; external 'dbghelp.dll';
function SymCleanup(hProcess: THandle): BOOL; stdcall; external 'dbghelp.dll';
function SymSetOptions(SymOptions: DWORD): DWORD; stdcall; external 'dbghelp.dll';
function SymGetOptions: DWORD; stdcall; external 'dbghelp.dll';
function SymLoadModuleExW(hProcess: THandle; hFile: THandle;
  ImageName, ModuleName: PWideChar; BaseOfDll: UInt64;
  DllSize: DWORD; Data: Pointer; Flags: DWORD): UInt64; stdcall; external 'dbghelp.dll';
function SymUnloadModule64(hProcess: THandle; BaseOfDll: UInt64): BOOL; stdcall; external 'dbghelp.dll';
function SymGetLineFromAddrW64(hProcess: THandle; Addr: UInt64;
  Displacement: PDWORD; var Line: IMAGEHLP_LINE64): BOOL; stdcall; external 'dbghelp.dll';
function SymFromAddrW(hProcess: THandle; Address: UInt64;
  Displacement: PUInt64; Symbol: PSYMBOL_INFO): BOOL; stdcall; external 'dbghelp.dll';
function SymEnumSymbols(hProcess: THandle; BaseOfDll: UInt64;
  Mask: PAnsiChar; Callback: Pointer; UserContext: Pointer): BOOL; stdcall; external 'dbghelp.dll';

var
  GTotalSyms:    Integer = 0;
  GFunctionSyms: Integer = 0;
  GLocalSyms:    Integer = 0;
  GParamSyms:    Integer = 0;
  GRegRelSyms:   Integer = 0;
  GFrameRelSyms: Integer = 0;
  GShownSamples: Integer = 0;

function EnumCallback(SymInfo: PSYMBOL_INFO; SymbolSize: ULONG;
  UserContext: Pointer): BOOL; stdcall;
var
  Name: string;
begin
  Inc(GTotalSyms);
  if (SymInfo.Flags and SYMFLAG_FUNCTION) <> 0 then Inc(GFunctionSyms);
  if (SymInfo.Flags and SYMFLAG_LOCAL)    <> 0 then Inc(GLocalSyms);
  if (SymInfo.Flags and SYMFLAG_PARAMETER)<> 0 then Inc(GParamSyms);
  if (SymInfo.Flags and SYMFLAG_REGREL)   <> 0 then Inc(GRegRelSyms);
  if (SymInfo.Flags and SYMFLAG_FRAMEREL) <> 0 then Inc(GFrameRelSyms);
  if GShownSamples < 30 then begin
    SetString(Name, PAnsiChar(@SymInfo.Name[0]), SymInfo.NameLen);
    Writeln(Format('  [sym] %-50s addr=$%x flags=$%x tag=%d val=%d',
      [Name, SymInfo.Address, SymInfo.Flags, SymInfo.Tag, SymInfo.Value]));
    Inc(GShownSamples);
  end;
  Result := True;
end;

procedure Probe(const ExePath: string);
var
  HProc:    THandle;
  Base:     UInt64;
  Line:     IMAGEHLP_LINE64;
  Disp:     DWORD;
  Buf:      array[0..1023] of Byte;
  Sym:      PSYMBOL_INFO;
  AddrDisp: UInt64;
  S:        string;
begin
  HProc := GetCurrentProcess;
  SymSetOptions(SYMOPT_LOAD_LINES or SYMOPT_DEBUG);
  if not SymInitializeW(HProc, nil, False) then begin
    Writeln('SymInitialize failed: ', GetLastError);
    Halt(1);
  end;
  try
    Base := SymLoadModuleExW(HProc, 0, PWideChar(ExePath), nil, 0, 0, nil, 0);
    if Base = 0 then begin
      Writeln('SymLoadModuleEx failed: ', GetLastError);
      Halt(2);
    end;
    Writeln(Format('Loaded module at base=$%x', [Base]));

    // Try a few RVAs known from TestTarget.map (rough). We hand-pick three
    // that should land somewhere in user code.
    Writeln('--- SymGetLineFromAddr64 probes ---');
    for var Rva in [UInt64($1000), UInt64($2000), UInt64($5000), UInt64($A000),
                    UInt64($20000), UInt64($30000), UInt64($40000)] do begin
      FillChar(Line, SizeOf(Line), 0);
      Line.SizeOfStruct := SizeOf(Line);
      Disp := 0;
      if SymGetLineFromAddrW64(HProc, Base + Rva, @Disp, Line) then begin
        S := '';
        if Line.FileName <> nil then
          SetString(S, Line.FileName, StrLen(Line.FileName));
        Writeln(Format('  RVA $%x → %s:%d (disp=%d)', [Rva, S, Line.LineNumber, Disp]));
      end else
        Writeln(Format('  RVA $%x → no line (err=%d)', [Rva, GetLastError]));
    end;

    Writeln('--- SymFromAddr probes (function names at same RVAs) ---');
    Sym := PSYMBOL_INFO(@Buf[0]);
    Sym.SizeOfStruct := SizeOf(SYMBOL_INFO);
    Sym.MaxNameLen   := SizeOf(Buf) - SizeOf(SYMBOL_INFO);
    for var Rva in [UInt64($1000), UInt64($2000), UInt64($5000), UInt64($A000),
                    UInt64($20000), UInt64($30000), UInt64($40000)] do begin
      AddrDisp := 0;
      Sym.SizeOfStruct := SizeOf(SYMBOL_INFO);
      Sym.MaxNameLen   := SizeOf(Buf) - SizeOf(SYMBOL_INFO);
      if SymFromAddrW(HProc, Base + Rva, @AddrDisp, Sym) then begin
        SetString(S, PAnsiChar(@Sym.Name[0]), Sym.NameLen);
        Writeln(Format('  RVA $%x → %s (disp=%d, tag=%d, addr=$%x)',
          [Rva, S, AddrDisp, Sym.Tag, Sym.Address]));
      end else
        Writeln(Format('  RVA $%x → no symbol (err=%d)', [Rva, GetLastError]));
    end;

    Writeln('--- SymEnumSymbols (all symbols, * mask) ---');
    if not SymEnumSymbols(HProc, Base, '*', @EnumCallback, nil) then
      Writeln('SymEnumSymbols failed: ', GetLastError);
    Writeln(Format('Total symbols: %d', [GTotalSyms]));
    Writeln(Format('  functions:    %d', [GFunctionSyms]));
    Writeln(Format('  locals:       %d', [GLocalSyms]));
    Writeln(Format('  parameters:   %d', [GParamSyms]));
    Writeln(Format('  RegRel:       %d', [GRegRelSyms]));
    Writeln(Format('  FrameRel:     %d', [GFrameRelSyms]));

    SymUnloadModule64(HProc, Base);
  finally
    SymCleanup(HProc);
  end;
end;

begin
  try
    if ParamCount < 1 then begin
      Writeln('Usage: CvProbe.exe <path-to-exe-with-CodeView>');
      Halt(1);
    end;
    Probe(ParamStr(1));
  except
    on E: Exception do begin
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
      Halt(2);
    end;
  end;
end.
