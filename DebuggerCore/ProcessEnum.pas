unit ProcessEnum;

// Rich running-process enumeration plus a pre-attach architecture gate.
// Replaces the old pid-only helpers (pid + exe basename + full path only) and
// powers the MCP `list_debuggable_processes` and `attach_to_process` tools.
//
// Standalone by design: depends only on Winapi + RTL so it can be compiled and
// smoke-tested in isolation (see DevTools\ProcessEnumProbe.dpr).

interface

uses
  System.SysUtils;

type
  // TODO unify with DebugSessionTypes.TProcessArch once that unit lands
  TProcessArch = (paUnknown, paX86, paX64, paArm64);

  TProcessInfo = record
    Pid, ParentPid, SessionId: Cardinal;
    ExeName, ExePath, CommandLine: string;
    StartTime: TDateTime;      // local time; 0 when unavailable
    Arch: TProcessArch;
    MainWindowTitle: string;   // '' for a console or windowless process; see AttachMainWindowTitles
  end;

// NameFilter '' = all; else case-insensitive basename match (with or without .exe).
function EnumerateProcesses(const NameFilter: string = ''): TArray<TProcessInfo>;

// ALL matches (never picks one).
function FindProcessesByName(const ExeName: string): TArray<TProcessInfo>;

function GetProcessInfo(Pid: Cardinal; out Info: TProcessInfo): Boolean;

// Architecture of THIS debugger process (cached; never changes at runtime).
function HostDebuggerArch: TProcessArch;

// Pre-attach gate: False + human-readable Reason when the target is unsupported.
function CanDebug(const Info: TProcessInfo; out Reason: string): Boolean;

function ArchToStr(Arch: TProcessArch): string;

// Fills in MainWindowTitle for each process that has a visible top-level window.
//
// Separate from EnumerateProcesses because it is a different question answered
// by a different API, and because most callers do not need it: it exists for the
// attach picker, where two instances of one application have the same name, the
// same image path and often the same command line, and the window caption is the
// only thing that tells a user which one is which.
//
// One EnumWindows pass for the whole array. Windows enumerates top-level windows
// in Z order, so the first match for a process is its front-most window.
procedure AttachMainWindowTitles(var Processes: TArray<TProcessInfo>);

implementation

uses
  Winapi.Windows,
  Winapi.TlHelp32,
  System.Generics.Collections;

// Imported manually because Winapi.Windows on this Delphi version doesn't
// surface it (same manual import as DapServer.pas).
function QueryFullProcessImageNameW(hProcess: THandle; dwFlags: DWORD;
  lpExeName: PWideChar; var lpdwSize: DWORD): BOOL; stdcall;
  external kernel32 name 'QueryFullProcessImageNameW';

const
  PROCESS_QUERY_LIMITED_INFORMATION = $1000;
  PROCESS_VM_READ                   = $0010;

  IMAGE_FILE_MACHINE_UNKNOWN = 0;
  IMAGE_FILE_MACHINE_I386    = $014C;
  IMAGE_FILE_MACHINE_AMD64   = $8664;
  IMAGE_FILE_MACHINE_ARM64   = $AA64;

  // Not surfaced by Winapi.Windows on this Delphi version.
  PROCESSOR_ARCHITECTURE_ARM64 = 12;

  ProcessBasicInformation = 0;

type
  // Kernel32 IsWow64Process2 (Win10 1709+): decodes emulation vs native machine.
  TIsWow64Process2 = function(hProcess: THandle; out ProcessMachine, NativeMachine: USHORT): BOOL; stdcall;

  // ntdll NtQueryInformationProcess. Returns NTSTATUS (0 == STATUS_SUCCESS).
  TNtQueryInformationProcess = function(ProcessHandle: THandle; ProcessInformationClass: DWORD;
    ProcessInformation: Pointer; ProcessInformationLength: ULONG; ReturnLength: PULONG): LongInt; stdcall;

  // x64 PROCESS_BASIC_INFORMATION (natural alignment reproduces the OS layout:
  // ExitStatus@0, PebBaseAddress@8, size 48).
  TProcessBasicInformation = record
    ExitStatus: LongInt;
    PebBaseAddress: Pointer;
    AffinityMask: ULONG_PTR;
    BasePriority: LongInt;
    UniqueProcessId: ULONG_PTR;
    InheritedFromUniqueProcessId: ULONG_PTR;
  end;

  // x64 UNICODE_STRING: Length@0 (bytes), MaximumLength@2, Buffer@8, size 16.
  TUnicodeString64 = record
    Length: USHORT;
    MaximumLength: USHORT;
    Buffer: PWideChar;
  end;

var
  IsWow64Process2Fn: TIsWow64Process2 = nil;
  NtQueryInformationProcessFn: TNtQueryInformationProcess = nil;
  HostArchCache: TProcessArch = paUnknown;

function ArchToStr(Arch: TProcessArch): string;
begin
  case Arch of
    paX86:   Result := 'x86';
    paX64:   Result := 'x64';
    paArm64: Result := 'arm64';
  else
    Result := 'unknown';
  end;
end;

function MachineToArch(Machine: USHORT): TProcessArch;
begin
  case Machine of
    IMAGE_FILE_MACHINE_I386:  Result := paX86;
    IMAGE_FILE_MACHINE_AMD64: Result := paX64;
    IMAGE_FILE_MACHINE_ARM64: Result := paArm64;
  else
    Result := paUnknown;
  end;
end;

function ArchViaWow64Fallback(H: THandle): TProcessArch;
begin
  // Legacy path for hosts without IsWow64Process2. A WOW64 process is x86 on an
  // x64/arm64 host; otherwise it runs as the native machine.
  var IsWow64: BOOL := False;
  if not IsWow64Process(H, IsWow64) then
    Exit(paUnknown);
  if IsWow64 then
    Exit(paX86);

  var SysInfo: TSystemInfo;
  GetNativeSystemInfo(SysInfo);
  case SysInfo.wProcessorArchitecture of
    PROCESSOR_ARCHITECTURE_AMD64: Result := paX64;
    PROCESSOR_ARCHITECTURE_ARM64: Result := paArm64;
    PROCESSOR_ARCHITECTURE_INTEL: Result := paX86;
  else
    Result := paUnknown;
  end;
end;

function ArchOfHandle(H: THandle): TProcessArch;
begin
  if not Assigned(IsWow64Process2Fn) then
    Exit(ArchViaWow64Fallback(H));

  var ProcessMachine: USHORT := IMAGE_FILE_MACHINE_UNKNOWN;
  var NativeMachine: USHORT := IMAGE_FILE_MACHINE_UNKNOWN;
  if not IsWow64Process2Fn(H, ProcessMachine, NativeMachine) then
    Exit(ArchViaWow64Fallback(H));

  // ProcessMachine <> UNKNOWN means the process is being emulated as that
  // machine (e.g. I386 under WOW64, AMD64 under ARM64 emulation) and directly
  // names the process arch. UNKNOWN means native: decode NativeMachine.
  if ProcessMachine <> IMAGE_FILE_MACHINE_UNKNOWN then
    Result := MachineToArch(ProcessMachine)
  else
    Result := MachineToArch(NativeMachine);
end;

function HostDebuggerArch: TProcessArch;
begin
  if HostArchCache = paUnknown then
    HostArchCache := ArchOfHandle(GetCurrentProcess);
  Result := HostArchCache;
end;

function ExePathOfHandle(H: THandle): string;
begin
  Result := '';
  var Buf: array[0..1023] of WideChar;
  var Sz: DWORD := Length(Buf);
  if QueryFullProcessImageNameW(H, 0, @Buf[0], Sz) then
    SetString(Result, PWideChar(@Buf[0]), Sz);
end;

function StartTimeOfHandle(H: THandle): TDateTime;
begin
  Result := 0;
  var CreationFt, ExitFt, KernelFt, UserFt: TFileTime;
  if not GetProcessTimes(H, CreationFt, ExitFt, KernelFt, UserFt) then
    Exit;
  var LocalFt: TFileTime;
  if not FileTimeToLocalFileTime(CreationFt, LocalFt) then
    Exit;
  var St: TSystemTime;
  if not FileTimeToSystemTime(LocalFt, St) then
    Exit;
  Result := SystemTimeToDateTime(St);
end;

function SessionIdOfPid(Pid: Cardinal): Cardinal;
begin
  Result := 0;
  var Sid: DWORD := 0;
  if ProcessIdToSessionId(Pid, Sid) then
    Result := Sid;
end;

// Reads the target command line by walking its PEB.
//
// Offsets are the x64 layout confirmed via WinDbg `dt ntdll!_PEB` /
// `dt ntdll!_RTL_USER_PROCESS_PARAMETERS`:
//   PEB.ProcessParameters                     @ +$20
//   RTL_USER_PROCESS_PARAMETERS.CommandLine   @ +$70 (UNICODE_STRING)
//
// BITNESS CAVEAT: this layout is valid only for a SAME-BITNESS (x64) target.
// For a WOW64 x86 target under an x64 debugger the 32-bit PEB differs; reading
// it here would yield garbage, so the caller-supplied Arch gate skips it.
// Future path: NtWow64QueryInformationProcess64 to reach the 64-bit view.
// Any failure or partial read yields '' rather than raising.
function CommandLineOfHandle(H: THandle; Arch: TProcessArch): string;
begin
  Result := '';
  if not Assigned(NtQueryInformationProcessFn) then
    Exit;
  if Arch <> HostDebuggerArch then
    Exit;

  var Pbi: TProcessBasicInformation;
  FillChar(Pbi, SizeOf(Pbi), 0);
  var RetLen: ULONG := 0;
  if NtQueryInformationProcessFn(H, ProcessBasicInformation, @Pbi, SizeOf(Pbi), @RetLen) <> 0 then
    Exit;
  if Pbi.PebBaseAddress = nil then
    Exit;

  var Got: SIZE_T := 0;
  var ProcParams: Pointer := nil;
  if not ReadProcessMemory(H, PByte(Pbi.PebBaseAddress) + $20, @ProcParams, SizeOf(ProcParams), Got) then
    Exit;
  if ProcParams = nil then
    Exit;

  var CmdLine: TUnicodeString64;
  FillChar(CmdLine, SizeOf(CmdLine), 0);
  if not ReadProcessMemory(H, PByte(ProcParams) + $70, @CmdLine, SizeOf(CmdLine), Got) then
    Exit;
  if (CmdLine.Length = 0) or (CmdLine.Buffer = nil) then
    Exit;

  SetLength(Result, CmdLine.Length div SizeOf(WideChar));
  if ReadProcessMemory(H, CmdLine.Buffer, PWideChar(Result), CmdLine.Length, Got) then
    SetLength(Result, Got div SizeOf(WideChar))
  else
    Result := '';
end;

function BuildProcessInfo(const Pe: TProcessEntry32W): TProcessInfo;
begin
  Result := Default(TProcessInfo);
  Result.Pid       := Pe.th32ProcessID;
  Result.ParentPid := Pe.th32ParentProcessID;
  Result.ExeName   := string(Pe.szExeFile);
  Result.SessionId := SessionIdOfPid(Pe.th32ProcessID);
  Result.Arch      := paUnknown;
  Result.StartTime := 0;

  // Prefer VM_READ so the command-line walk can run; degrade gracefully when
  // rights are insufficient (system / elevated targets).
  var H := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION or PROCESS_VM_READ, False, Pe.th32ProcessID);
  var CanReadVm := H <> 0;
  if H = 0 then
    H := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, Pe.th32ProcessID);
  if H = 0 then
    Exit;
  try
    Result.ExePath   := ExePathOfHandle(H);
    Result.StartTime := StartTimeOfHandle(H);
    Result.Arch      := ArchOfHandle(H);
    if CanReadVm then
      Result.CommandLine := CommandLineOfHandle(H, Result.Arch);
  finally
    CloseHandle(H);
  end;
end;

function NormalizeExeFilter(const NameFilter: string): string;
begin
  Result := AnsiLowerCase(NameFilter);
  if (Result <> '') and not Result.EndsWith('.exe') then
    Result := Result + '.exe';
end;

function EnumerateProcesses(const NameFilter: string = ''): TArray<TProcessInfo>;
begin
  Result := nil;
  var Wanted := NormalizeExeFilter(NameFilter);

  var Snap := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snap = INVALID_HANDLE_VALUE then
    Exit;
  try
    var Pe: TProcessEntry32W;
    Pe.dwSize := SizeOf(Pe);
    if not Process32FirstW(Snap, Pe) then
      Exit;
    var Collected := TList<TProcessInfo>.Create;
    try
      repeat
        if (Wanted = '') or SameText(string(Pe.szExeFile), Wanted) then
          Collected.Add(BuildProcessInfo(Pe));
      until not Process32NextW(Snap, Pe);
      Result := Collected.ToArray;
    finally
      Collected.Free;
    end;
  finally
    CloseHandle(Snap);
  end;
end;

function FindProcessesByName(const ExeName: string): TArray<TProcessInfo>;
begin
  Result := EnumerateProcesses(ExeName);
end;

function GetProcessInfo(Pid: Cardinal; out Info: TProcessInfo): Boolean;
begin
  Result := False;
  Info := Default(TProcessInfo);

  var Snap := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snap = INVALID_HANDLE_VALUE then
    Exit;
  try
    var Pe: TProcessEntry32W;
    Pe.dwSize := SizeOf(Pe);
    if not Process32FirstW(Snap, Pe) then
      Exit;
    repeat
      if Pe.th32ProcessID = Pid then begin
        Info := BuildProcessInfo(Pe);
        Exit(True);
      end;
    until not Process32NextW(Snap, Pe);
  finally
    CloseHandle(Snap);
  end;
end;

function CanDebug(const Info: TProcessInfo; out Reason: string): Boolean;
begin
  Reason := '';
  if Info.Arch = paUnknown then begin
    Reason := 'cannot determine target architecture';
    Exit(False);
  end;
  var Host := HostDebuggerArch;
  if Info.Arch <> Host then begin
    Reason := Format('target is %s; this debugger is %s and cannot debug a different architecture',
      [ArchToStr(Info.Arch), ArchToStr(Host)]);
    Exit(False);
  end;
  Result := True;
end;

procedure ResolveDynamicApis;
begin
  var HKernel := GetModuleHandle(kernel32);
  if HKernel <> 0 then
    @IsWow64Process2Fn := GetProcAddress(HKernel, 'IsWow64Process2');

  var HNtdll := GetModuleHandle('ntdll.dll');
  if HNtdll = 0 then
    HNtdll := LoadLibrary('ntdll.dll');
  if HNtdll <> 0 then
    @NtQueryInformationProcessFn := GetProcAddress(HNtdll, 'NtQueryInformationProcess');
end;

// ------------------------------- window titles ------------------------------

// GetWindowText is deliberate: for a top-level window owned by another process
// it returns the cached caption WITHOUT sending WM_GETTEXT, so a hung
// application cannot block the enumeration. A WM_GETTEXT round trip here would
// make the picker hang on exactly the process a user most wants to attach to.
function CaptionOf(Wnd: HWND): string;
begin
  var Buffer: array[0..511] of Char;
  var Copied := GetWindowText(Wnd, Buffer, Length(Buffer));
  if Copied <= 0 then
    Exit('');
  Result := string(Buffer).Trim;
end;

function IsCandidateMainWindow(Wnd: HWND): Boolean;
begin
  if not IsWindowVisible(Wnd) then
    Exit(False);
  // Tool windows are palettes and hidden helpers - never what a user calls the
  // application's window. Delphi's own TApplication window is one of them.
  if GetWindowLong(Wnd, GWL_EXSTYLE) and WS_EX_TOOLWINDOW <> 0 then
    Exit(False);
  Result := True;
end;

function CollectWindowTitle(Wnd: HWND; Param: LPARAM): BOOL; stdcall;
begin
  Result := True; // keep enumerating whatever this window turns out to be
  if not IsCandidateMainWindow(Wnd) then
    Exit;

  var Pid: DWORD := 0;
  GetWindowThreadProcessId(Wnd, @Pid);
  if Pid = 0 then
    Exit;

  var Titles := TDictionary<Cardinal, string>(Param);
  if Titles.ContainsKey(Pid) then
    Exit; // already have this process's front-most window

  var Caption := CaptionOf(Wnd);
  if Caption <> '' then
    Titles.Add(Pid, Caption);
end;

procedure AttachMainWindowTitles(var Processes: TArray<TProcessInfo>);
begin
  if Length(Processes) = 0 then
    Exit;

  var Titles := TDictionary<Cardinal, string>.Create;
  try
    EnumWindows(@CollectWindowTitle, LPARAM(Titles));
    for var Index := 0 to High(Processes) do begin
      var Caption := '';
      if Titles.TryGetValue(Processes[Index].Pid, Caption) then
        Processes[Index].MainWindowTitle := Caption;
    end;
  finally
    Titles.Free;
  end;
end;

initialization
  ResolveDynamicApis;

end.
