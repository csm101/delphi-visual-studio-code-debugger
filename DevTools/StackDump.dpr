program StackDump;

// Attaches read-only to a running process, walks one or all threads via
// StackWalk64, resolves frames via Delphi MAP + RSM. No DebugActiveProcess
// (read-only, doesn't steal debug ownership from another debugger). Suitable
// to inspect a target currently held by VS Code + our adapter.
//
// Usage:
//   StackDump.exe <pid> <map> <rsm> [tid]
//
// If tid is omitted, dumps every thread of the process. Outputs frame index,
// RIP VA, resolved name+offset and source:line per frame.

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, Winapi.Windows, Winapi.TlHelp32,
  DebugInfoTypes  in '..\DebuggerCore\DebugInfoTypes.pas',
  MapFileReader   in '..\DebuggerCore\MapFileReader.pas',
  RsmFileReader   in '..\DebuggerCore\RsmFileReader.pas';

const
  THREAD_GET_CONTEXT    = $0008;
  THREAD_SUSPEND_RESUME = $0002;
  THREAD_QUERY_INFORMATION = $0040;

type
  // DbgHelp imports (minimum needed for StackWalk64)
  STACKFRAME64 = record
    AddrPC:      record Offset: UInt64; Segment: Word; Mode: Integer; end;
    AddrReturn:  record Offset: UInt64; Segment: Word; Mode: Integer; end;
    AddrFrame:   record Offset: UInt64; Segment: Word; Mode: Integer; end;
    AddrStack:   record Offset: UInt64; Segment: Word; Mode: Integer; end;
    AddrBStore:  record Offset: UInt64; Segment: Word; Mode: Integer; end;
    FuncTableEntry: Pointer;
    Params:      array[0..3] of UInt64;
    Far:         BOOL;
    Virtual:     BOOL;
    Reserved:    array[0..2] of UInt64;
    KdHelp:      record {12 bytes worth; we don't use it} a, b, c: UInt64; end;
  end;
  PSTACKFRAME64 = ^STACKFRAME64;

const
  IMAGE_FILE_MACHINE_AMD64 = $8664;
  AddrModeFlat = 3;

function SymInitialize(hProcess: THandle; UserSearchPath: PAnsiChar; fInvadeProcess: BOOL): BOOL;
  stdcall; external 'dbghelp.dll';
function SymCleanup(hProcess: THandle): BOOL;
  stdcall; external 'dbghelp.dll';
function SymFunctionTableAccess64(hProcess: THandle; AddrBase: UInt64): Pointer;
  stdcall; external 'dbghelp.dll';
function SymGetModuleBase64(hProcess: THandle; Address: UInt64): UInt64;
  stdcall; external 'dbghelp.dll';
function StackWalk64(MachineType: DWORD; hProcess: THandle; hThread: THandle;
  StackFrame: PSTACKFRAME64; ContextRecord: Pointer;
  ReadMemoryRoutine: Pointer; FunctionTableAccess: Pointer;
  GetModuleBase: Pointer; TranslateAddress: Pointer): BOOL;
  stdcall; external 'dbghelp.dll';

function OpenThread(DesiredAccess: DWORD; InheritHandle: BOOL; ThreadId: DWORD): THandle;
  stdcall; external 'kernel32.dll';

function GetProcessIdW(H: THandle): DWORD;
  stdcall; external 'kernel32.dll' name 'GetProcessId';

function GetProcessImageBase(HProc: THandle): UInt64;
// Returns the address at which the process's main module is loaded.
// Under ASLR this is NOT the preferred ImageBase from the PE header
// (e.g. 0x400000) -- it can be any address picked by the loader. Stack
// frame RVAs MUST be computed against this runtime base, not the
// preferred base, or every lookup is off by the relocation delta.
var
  HSnap: THandle;
  Me:    TModuleEntry32;
  Pid:   DWORD;
begin
  Result := 0;
  Pid := GetProcessIdW(HProc);
  HSnap := CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, Pid);
  if HSnap = INVALID_HANDLE_VALUE then Exit;
  try
    Me.dwSize := SizeOf(Me);
    if Module32First(HSnap, Me) then
      Result := UInt64(Me.modBaseAddr);
  finally
    CloseHandle(HSnap);
  end;
end;

procedure DumpThread(HProc: THandle; Tid: DWORD; Map: TMapFile; Rsm: TRsmFile;
  ImageBase: UInt64);
var
  HThr:   THandle;
  Ctx:    TContext;
  SF:     STACKFRAME64;
  N:      Integer;
  Name:   string;
  FRva:   UInt64;
  Loc:    TSourceLocation;
begin
  HThr := OpenThread(THREAD_GET_CONTEXT or THREAD_SUSPEND_RESUME or
    THREAD_QUERY_INFORMATION, False, Tid);
  if HThr = 0 then begin
    Writeln(Format('TID %d: OpenThread failed (%d)', [Tid, GetLastError]));
    Exit;
  end;
  try
    if SuspendThread(HThr) = DWORD(-1) then begin
      Writeln(Format('TID %d: SuspendThread failed', [Tid]));
      Exit;
    end;
    try
      Ctx := Default(TContext);
      Ctx.ContextFlags := CONTEXT_FULL;
      if not GetThreadContext(HThr, Ctx) then begin
        Writeln(Format('TID %d: GetThreadContext failed (%d)', [Tid, GetLastError]));
        Exit;
      end;

      Writeln(Format('--- thread %d (RIP=$%x RBP=$%x RSP=$%x) ---',
        [Tid, Ctx.Rip, Ctx.Rbp, Ctx.Rsp]));

      SF := Default(STACKFRAME64);
      SF.AddrPC.Offset    := Ctx.Rip;
      SF.AddrPC.Mode      := AddrModeFlat;
      SF.AddrFrame.Offset := Ctx.Rbp;
      SF.AddrFrame.Mode   := AddrModeFlat;
      SF.AddrStack.Offset := Ctx.Rsp;
      SF.AddrStack.Mode   := AddrModeFlat;

      N := 0;
      while StackWalk64(IMAGE_FILE_MACHINE_AMD64, HProc, HThr, @SF, @Ctx,
          nil, @SymFunctionTableAccess64, @SymGetModuleBase64, nil) do begin
        if SF.AddrPC.Offset = 0 then Break;

        var Va  := SF.AddrPC.Offset;
        var Rva: UInt64;
        if Va >= ImageBase then
          Rva := Va - ImageBase
        else
          Rva := 0;

        Write(Format('  #%02d  $%x', [N, Va]));
        if (Rva > 0) and Map.RvaToFunctionName(Rva, Name) then begin
          Map.RvaToFunctionStart(Rva, FRva);
          Write(Format('  %s+0x%x', [Name, Rva - FRva]));
        end;
        if (Rva > 0) and Map.RvaToSourceLine(Rva, Loc) then
          Write(Format('  (%s:%d)', [ExtractFileName(Loc.SourceFile), Loc.Line]));
        Writeln;

        Inc(N);
        if N >= 50 then Break;
      end;
    finally
      ResumeThread(HThr);
    end;
  finally
    CloseHandle(HThr);
  end;
end;

procedure Run;
var
  TargetPid: DWORD;
  MapPath, RsmPath: string;
  TidArg: DWORD;
  HProc: THandle;
  HSnap: THandle;
  Te: TThreadEntry32;
  Map: TMapFile;
  Rsm: TRsmFile;
begin
  if ParamCount < 3 then begin
    Writeln('Usage: StackDump.exe <pid> <map> <rsm> [tid]');
    Halt(1);
  end;
  TargetPid := StrToInt(ParamStr(1));
  MapPath   := ParamStr(2);
  RsmPath   := ParamStr(3);
  TidArg    := 0;
  if ParamCount >= 4 then TidArg := StrToInt(ParamStr(4));

  HProc := OpenProcess(PROCESS_QUERY_INFORMATION or PROCESS_VM_READ, False, TargetPid);
  if HProc = 0 then begin
    Writeln('OpenProcess failed: ', GetLastError);
    Halt(2);
  end;
  try
    if not SymInitialize(HProc, nil, True) then begin
      Writeln('SymInitialize failed: ', GetLastError);
      Halt(3);
    end;
    var ActualBase := GetProcessImageBase(HProc);
    if ActualBase = 0 then ActualBase := $400000;

    try
      Map := TMapFile.Create;
      Rsm := TRsmFile.Create;
      try
        // MAP/RSM are anchored to the PE PreferredBase; runtime ImageBase
        // can be different under ASLR. We compute RVAs as (VA - ActualBase)
        // -- the MAP/RSM lookups then treat them as preferred-base relative.
        Map.LoadFromFile(MapPath, $400000);
        Rsm.LoadFromFile(RsmPath);
        Map.RvaToFunctionName(0, MapPath); // force background index

        Writeln(Format('Process PID=%d  ActualBase=$%x  PreferredBase=$400000',
          [TargetPid, ActualBase]));

        if TidArg <> 0 then
          DumpThread(HProc, TidArg, Map, Rsm, ActualBase)
        else begin
          HSnap := CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
          if HSnap = INVALID_HANDLE_VALUE then begin
            Writeln('CreateToolhelp32Snapshot failed: ', GetLastError);
            Exit;
          end;
          try
            Te.dwSize := SizeOf(Te);
            if Thread32First(HSnap, Te) then
              repeat
                if Te.th32OwnerProcessID = TargetPid then
                  DumpThread(HProc, Te.th32ThreadID, Map, Rsm, ActualBase);
              until not Thread32Next(HSnap, Te);
          finally
            CloseHandle(HSnap);
          end;
        end;
      finally
        Rsm.Free;
        Map.Free;
      end;
    finally
      SymCleanup(HProc);
    end;
  finally
    CloseHandle(HProc);
  end;
end;

begin
  try
    Run;
  except
    on E: Exception do begin
      Writeln('ERROR: ', E.ClassName, ': ', E.Message);
      Halt(10);
    end;
  end;
end.
