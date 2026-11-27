program TrampolineFixture;

{
  Debuggee fixture for DevTools\PatchFeasibilityProbe ("Increment 1" of
  docs\PROFILER_COVERAGE_PLAN.md: is instrumentation feasible as designed).

  Every experiment is one small routine, selected by the first command-line
  argument. The probe finds the addresses it patches from the TD32 line table
  through the BP markers below, never from a hardcoded offset, and it checks
  with Zydis that the compiled bytes have the shape the experiment needs.

  GUI SUBSYSTEM, NO CONSOLE, ON PURPOSE (see ExcNestFixture.dpr). The outcome
  leaves the process in two ways the probe can read from the debug loop:

    - OutputDebugString lines. "PF: ..." lines are the TRANSCRIPT: a patched
      run behaves as the plain run exactly when the two transcripts and the
      exit codes are equal. Addresses in them are module relative ("+1A2B"),
      "ext" outside the module, so two launches compare equal under ASLR.
      "PFI: ..." lines are information for the probe (absolute addresses) and
      are not compared.
    - the exit code: the low 16 bits of GSink, or 9000 + its low byte when an
      exception reached the main block.

  THE NAME IS NOT "PatchFixture" ON PURPOSE. A 32-bit executable without a
  manifest whose file name contains "patch", "setup", "install" or "update" is
  taken for an installer by Windows: CreateProcess fails with error 740
  (elevation required) and nothing is ever launched. Measured with this very
  fixture; the 64-bit build is not affected.

  Nothing here may open a dialog: a broken unwind is an expected outcome of
  some experiments, so the RTL's last-chance handler and its run-time error
  box are replaced.

  Build both bitnesses with DevTools\build_trampoline_fixture.bat
  (-$O- -V -VN -VR -GD). Three routines switch optimisation on locally because
  the shape they exist for needs it (E2TailRegs, E2TailLean, E3PokeFast).

  Usage: TrampolineFixture <experiment> [arguments]
    e1        raise below a try..except; the statement after the call is at
              the return address
    e1deep    the same, the raise two call levels below the routine with the try
    e1thru    the return address is in a routine WITHOUT a handler, between
              the raise and the routine with the try
    e2p       the callee raises from the last statement of a routine (natural
              epilogue of an unoptimised routine at the return address)
    e2r       the same, in a routine that saves registers (optimised)
    e2l       the same, in an optimised routine without a frame pointer
    e3x       write through nil inside try..except on EAccessViolation
    e3f       write through nil inside try..finally with an outer handler
    e3ok      the same statement as e3x with a valid pointer: no exception
    e3r       write through nil as the FIRST instruction of a statement
    e4        1000 direct calls in a loop, the last one raising; the callee
              prints its own stack
    e5e       an indirect call as the last instruction of a try body
    e5m       an indirect call in the middle of a try body
    e5b       an indirect call as the last instruction BEFORE a try body
    e7 <n> [reloc]
              the program hooks its own routine: copies its first <n> bytes to
              memory it allocates, appends a jump back and overwrites the start
              with a jump to its hook. With "reloc" a leading `jmp rel32` in
              the copied bytes is re-based, as an instruction-aware hooking
              library does.
}

{$APPTYPE GUI}
{$OPTIMIZATION OFF}
{$STACKFRAMES ON}
{$RANGECHECKS OFF}
{$OVERFLOWCHECKS OFF}

uses
  Winapi.Windows,
  System.SysUtils;

type
  EFixture = class(Exception);
  TBoolProc = procedure(DoRaise: Boolean);
  TTwoIntFunc = function(A, B: Integer): Integer;

const
  E4_CALLS = 1000;
  MAX_STACK_FRAMES = 48;

var
  GSink:       Integer = 0;
  GStep:       Integer = 16;
  GCalls:      Integer = 0;
  GHookCalls:  Integer = 0;
  GTarget:     Integer = 0;
  GModuleSize: NativeUInt = 0;
  GIndirect:   TBoolProc = nil;
  GGateway:    Pointer = nil;

{ ------------------------------------------------------------------ reporting }

procedure Report(const Text: string);
begin
  OutputDebugString(PChar('PF: ' + Text));
end;

procedure ReportInfo(const Text: string);
begin
  OutputDebugString(PChar('PFI: ' + Text));
end;

function InModule(Address: NativeUInt): Boolean;
begin
  Result := (Address >= HInstance) and (Address - HInstance < GModuleSize);
end;

// A module-relative spelling of an address, so that two launches of the same
// binary print the same text whatever the image base was.
function Rel(Address: NativeUInt): string;
begin
  if Address = 0 then
    Exit('nil');
  if not InModule(Address) then
    Exit('ext');
  Result := '+' + IntToHex(Address - HInstance, 1);
end;

function IsHexDigit(C: Char): Boolean;
begin
  Result := CharInSet(C, ['0'..'9', 'A'..'F', 'a'..'f']);
end;

// The RTL writes absolute addresses into the message of an access violation.
// Every run of hexadecimal digits of pointer width that follows the word
// "address" is replaced by Rel() of it; an exception code is left alone.
function NormalizeAddresses(const Text: string): string;
const
  POINTER_DIGITS = SizeOf(Pointer) * 2;
  LEAD_IN = 'address ';
begin
  Result := '';
  var Index := 1;
  while Index <= Length(Text) do begin
    var Run := 0;
    while (Index + Run <= Length(Text)) and IsHexDigit(Text[Index + Run]) do
      Inc(Run);
    if (Run = POINTER_DIGITS) and Result.EndsWith(LEAD_IN) then
      Result := Result + Rel(NativeUInt(StrToUInt64('$' + Copy(Text, Index, Run))))
    else if Run > 0 then
      Result := Result + Copy(Text, Index, Run)
    else begin
      Result := Result + Text[Index];
      Run := 1;
    end;
    Inc(Index, Run);
  end;
end;

procedure ReportCaught(const Handler: string; E: Exception);
begin
  // EExternal.ExceptionRecord is deliberately not printed: by the time a handler
  // runs it points into stack the unwind has released, and its content differs
  // from one plain run to the next.
  Report(Format('caught %s in handler %s ExceptAddr=%s message="%s"',
    [E.ClassName, Handler, Rel(NativeUInt(ExceptAddr)), NormalizeAddresses(E.Message)]));
end;

{ ------------------------------------------------------- the program's tracer }

// The call-site test of JCL's TJclStackInfoList.ValidCallSite, which keeps a
// stack word only when the bytes in front of it are a call instruction.
function PrecededByCall(ReturnAddress: NativeUInt): Boolean;
begin
  if not InModule(ReturnAddress) or not InModule(ReturnAddress - 8) then
    Exit(False);
  var Low8 := PCardinal(ReturnAddress - 8)^;
  var Low4 := PCardinal(ReturnAddress - 4)^;
  var Rm1 := (Low4 shr 24) and 7;
  var Rm2 := (Low4 shr 16) and 7;
  var Rm5 := (Low8 shr 24) and 7;
  if (Low8 and $FF000000) = $E8000000 then
    Exit(True);                                        // call rel32
  if ((Low4 and $F8FF0000) = $10FF0000) and not (Rm1 in [4, 5]) then
    Exit(True);                                        // call [reg]
  if (Low4 and $F8FF0000) = $D0FF0000 then
    Exit(True);                                        // call reg
  if (Low4 and $00FFFF00) = $0014FF00 then
    Exit(True);                                        // call [reg+reg*i]
  if ((Low4 and $00F8FF00) = $0050FF00) and (Rm2 <> 4) then
    Exit(True);                                        // call [reg+disp8]
  if (Low4 and $0000FFFF) = $000054FF then
    Exit(True);                                        // call [reg+reg+disp8]
  if (Low8 and $FFFF0000) = $15FF0000 then
    Exit(True);                                        // call [disp32]
  if ((Low8 and $F8FF0000) = $90FF0000) and (Rm5 <> 4) then
    Exit(True);                                        // call [reg+disp32]
  if (Low8 and $00FFFF00) = $0094FF00 then
    Exit(True);                                        // call [reg+reg+disp32]
  Result := False;
end;

{$IFDEF CPUX64}
function CaptureBackTrace(FramesToSkip, FramesToCapture: Cardinal; BackTrace: PPointer; BackTraceHash: PCardinal): Word;
  stdcall; external kernel32 name 'RtlCaptureStackBackTrace';

function CollectReturnAddresses(var Addresses: array of NativeUInt): Integer;
begin
  Result := CaptureBackTrace(2, Length(Addresses), @Addresses[0], nil);
end;
{$ELSE}
function CallerFrame: NativeUInt;
asm
  mov eax, ebp
end;

function StackBase: NativeUInt;
asm
  mov eax, fs:[4]
end;

// The saved-EBP chain, as a frame-based tracer walks it.
function CollectReturnAddresses(var Addresses: array of NativeUInt): Integer;
begin
  Result := 0;
  // CallerFrame answers this routine's frame; one link up is ReportStack's.
  var Frame := PNativeUInt(CallerFrame)^;
  var Top := StackBase;
  while (Result < Length(Addresses)) and (Frame <> 0) and ((Frame and 3) = 0) and (Frame + 8 <= Top) do begin
    Addresses[Result] := PNativeUInt(Frame + SizeOf(Pointer))^;
    Inc(Result);
    var Next := PNativeUInt(Frame)^;
    if Next <= Frame then
      Break;
    Frame := Next;
  end;
end;
{$ENDIF}

// The return addresses above the caller of this routine. Frames outside the
// module are counted, not printed.
procedure ReportStack(const Title: string);
var
  Addresses: array[0..MAX_STACK_FRAMES - 1] of NativeUInt;
begin
  var Count := CollectReturnAddresses(Addresses);
  var Line := Title + ':';
  var Outside := 0;
  for var I := 0 to Count - 1 do begin
    if not InModule(Addresses[I]) then begin
      Inc(Outside);
      Continue;
    end;
    if Outside > 0 then begin
      Line := Line + Format(' ext*%d', [Outside]);
      Outside := 0;
    end;
    Line := Line + ' ' + Rel(Addresses[I]);
    if not PrecededByCall(Addresses[I]) then
      Line := Line + '!nocall';
  end;
  if Outside > 0 then
    Line := Line + Format(' ext*%d', [Outside]);
  Report(Line);
end;

{ ------------------------------------------------------------------------- E1 }

procedure E1Callee(DoRaise: Boolean);
begin
  Inc(GSink);                                          // {BP:E1_CALLEE}
  if DoRaise then
    raise EFixture.Create('e1');
end;

procedure E1Outer(DoRaise: Boolean);
begin
  try
    E1Callee(DoRaise);                                 // {BP:E1_CALL}
    GSink := GSink + GStep;                            // {BP:E1_NEXT}
    Inc(GSink, 1000);
  except
    on E: EFixture do
      ReportCaught('H_E1', E);
  end;
end;

procedure E1Mid(DoRaise: Boolean);
begin
  E1Callee(DoRaise);
  Inc(GSink, 2);
end;

procedure E1DeepOuter(DoRaise: Boolean);
begin
  try
    E1Mid(DoRaise);                                    // {BP:E1D_CALL}
    GSink := GSink + GStep;                            // {BP:E1D_NEXT}
    Inc(GSink, 2000);
  except
    on E: EFixture do
      ReportCaught('H_E1D', E);
  end;
end;

// No handler of its own: the exception only travels THROUGH this frame.
procedure E1ThruPatched(DoRaise: Boolean);
begin
  E1Mid(DoRaise);                                      // {BP:E1T_CALL}
  GSink := GSink + GStep;                              // {BP:E1T_NEXT}
  Inc(GSink, 4000);
end;

procedure E1ThruOuter(DoRaise: Boolean);
begin
  try
    E1ThruPatched(DoRaise);
    Inc(GSink, 8000);
  except
    on E: EFixture do
      ReportCaught('H_E1T', E);
  end;
end;

// The raising pass comes first: a one-shot breakpoint at the return address is
// then still armed while the exception travels through the frame.
procedure RunTwoPasses(const Name: string; Routine: TBoolProc);
begin
  Routine(True);
  Report(Format('%s after the raising pass sink=%d', [Name, GSink]));
  Routine(False);
  Report(Format('%s after the returning pass sink=%d', [Name, GSink]));
end;

{ ------------------------------------------------------------------------- E2 }

procedure E2Callee(DoRaise: Boolean);
begin
  Inc(GSink);
  if DoRaise then
    raise EFixture.Create('e2');
end;

procedure E2TailPlain(DoRaise: Boolean);
begin
  Inc(GSink, 2);
  E2Callee(DoRaise);                                   // {BP:E2P_CALL}
end;                                                   // {BP:E2P_END}

{$OPTIMIZATION ON}
// Enough values alive across a call that the compiler keeps them in registers
// it has to save: the epilogue then has more than `pop rbp; ret` after the
// stack adjustment.
procedure E2TailRegs(DoRaise: Boolean; A, B, C: Integer);
var
  V1, V2, V3, V4: Integer;
begin
  V1 := A * 3;
  V2 := B * 5;
  V3 := C * 7;
  V4 := A + B + C;
  E2Callee(False);
  Inc(GSink, V1 + V2 + V3 + V4);
  E2Callee(DoRaise);                                   // {BP:E2R_CALL}
end;                                                   // {BP:E2R_END}

{$STACKFRAMES OFF}
// Optimised and without a frame pointer: the third epilogue shape, the one that
// releases the frame with `add rsp` (x64) or has nothing to release (x86).
procedure E2TailLean(DoRaise: Boolean);
begin
  Inc(GSink, 2);
  E2Callee(DoRaise);                                   // {BP:E2L_CALL}
end;                                                   // {BP:E2L_END}
{$STACKFRAMES ON}
{$OPTIMIZATION OFF}

procedure E2PlainOuter(DoRaise: Boolean);
begin
  try
    E2TailPlain(DoRaise);
    Inc(GSink, 64);
  except
    on E: EFixture do
      ReportCaught('H_E2P', E);
  end;
end;

procedure E2LeanOuter(DoRaise: Boolean);
begin
  try
    E2TailLean(DoRaise);
    Inc(GSink, 64);
  except
    on E: EFixture do
      ReportCaught('H_E2L', E);
  end;
end;

procedure E2RegsOuter(DoRaise: Boolean);
begin
  try
    E2TailRegs(DoRaise, 3, 4, 5);
    Inc(GSink, 64);
  except
    on E: EFixture do
      ReportCaught('H_E2R', E);
  end;
end;

{ ------------------------------------------------------------------------- E3 }

procedure E3Except(P: PInteger);
begin
  try
    P^ := 42;                                          // {BP:E3X_FAULT}
    Inc(GSink, 4);
  except
    on E: EAccessViolation do
      ReportCaught('H_E3X', E);
  end;
end;

procedure E3FinallyInner(P: PInteger);
begin
  try
    P^ := 42;                                          // {BP:E3F_FAULT}
    Inc(GSink, 4);
  finally
    Report('E3 finally block ran');
    Inc(GSink, 32);
  end;
end;

procedure E3Finally(P: PInteger);
begin
  try
    E3FinallyInner(P);
    Inc(GSink, 64);
  except
    on E: EAccessViolation do
      ReportCaught('H_E3F_OUTER', E);
  end;
end;

{$OPTIMIZATION ON}
{$STACKFRAMES OFF}
// Optimised, so that the pointer is in a register and the store is the first
// instruction of the statement.
procedure E3PokeFast(P: PInteger);
begin
  P^ := 42;                                            // {BP:E3R_FAULT}
  Inc(GSink, 8);
end;
{$STACKFRAMES ON}
{$OPTIMIZATION OFF}

procedure E3Fast(P: PInteger);
begin
  try
    E3PokeFast(P);
    Inc(GSink, 64);
  except
    on E: EAccessViolation do
      ReportCaught('H_E3R', E);
  end;
end;

{ ------------------------------------------------------------------------- E4 }

procedure E4Callee(Index: Integer);
begin
  Inc(GCalls);
  if (Index = 1) or (Index = E4_CALLS) then
    ReportStack(Format('E4 stack inside the callee at call %d', [Index]));
  if Index = E4_CALLS then
    raise EFixture.Create('e4');
end;

procedure RunE4;
begin
  for var I := 1 to E4_CALLS do
    try
      E4Callee(I);                                     // {BP:E4_CALL}
      Inc(GSink);
    except
      on E: EFixture do begin
        Report(Format('E4 exception arrived at call %d', [I]));
        ReportCaught('H_E4', E);
      end;
    end;
  Report(Format('E4 calls=%d sink=%d', [GCalls, GSink]));
end;

{ ------------------------------------------------------------------------- E5 }

procedure E5Callee(DoRaise: Boolean);
begin
  Inc(GCalls);
  ReportStack('E5 stack inside the callee');
  if DoRaise then
    raise EFixture.Create('e5');
end;

procedure E5End(DoRaise: Boolean);
begin
  try
    Inc(GSink, 2);
    GIndirect(DoRaise);                                // {BP:E5E_CALL}
  except
    on E: EFixture do
      ReportCaught('H_E5E', E);
  end;
end;

procedure E5Mid(DoRaise: Boolean);
begin
  try
    GIndirect(DoRaise);                                // {BP:E5M_CALL}
    Inc(GSink, 2);
  except
    on E: EFixture do
      ReportCaught('H_E5M', E);
  end;
end;

// The call is OUTSIDE the try: its return address is where the try body begins.
procedure E5BeforeInner(DoRaise: Boolean);
begin
  GIndirect(DoRaise);                                  // {BP:E5B_CALL}
  try
    Inc(GSink, 2);
  except
    on E: EFixture do
      ReportCaught('H_E5B_WRONG_INNER', E);
  end;
end;

procedure E5Before(DoRaise: Boolean);
begin
  try
    E5BeforeInner(DoRaise);
    Inc(GSink, 64);
  except
    on E: EFixture do
      ReportCaught('H_E5B_OUTER', E);
  end;
end;

procedure RunE5(const Name: string; Routine: TBoolProc);
begin
  Routine(False);
  Report(Format('%s after the returning pass sink=%d calls=%d', [Name, GSink, GCalls]));
  Routine(True);
  Report(Format('%s after the raising pass sink=%d calls=%d', [Name, GSink, GCalls]));
end;

{ ------------------------------------------------------------------------- E7 }

function E7Target(A, B: Integer): Integer;
begin                                                  // {BP:E7_BEGIN}
  Result := A * 10 + B;                                // {BP:E7_BODY}
end;

function E7Hook(A, B: Integer): Integer;
begin
  Inc(GHookCalls);
  Result := TTwoIntFunc(GGateway)(A, B) + 1000;
end;

function EmitJump(At, Destination: PByte): PByte;
begin
{$IFDEF CPUX64}
  // jmp qword ptr [rip+0] followed by the absolute address: reaches anywhere.
  At[0] := $FF;
  At[1] := $25;
  PCardinal(At + 2)^ := 0;
  PUInt64(At + 6)^ := UInt64(Destination);
  Result := At + 14;
{$ELSE}
  At[0] := $E9;
  PInteger(At + 1)^ := Integer(NativeInt(Destination) - NativeInt(At) - 5);
  Result := At + 5;
{$ENDIF}
end;

// A deliberately small detour: CopyBytes bytes of the target go to memory the
// program allocates, followed by a jump back, and the target's first five bytes
// become a jump to the hook.
procedure InstallMiniDetour(Target, Hook: PByte; CopyBytes: Integer; Relocate: Boolean);
var
  OldProtect: DWORD;
begin
  var Gateway := PByte(VirtualAlloc(nil, 4096, MEM_COMMIT or MEM_RESERVE, PAGE_EXECUTE_READWRITE));
  GGateway := Gateway;
  var Cursor := Gateway;
  var Source := Target;
  var Remaining := CopyBytes;
  if Relocate and (Target^ = $E9) and (CopyBytes >= 5) then begin
    Cursor := EmitJump(Cursor, Target + 5 + PInteger(Target + 1)^);
    Inc(Source, 5);
    Dec(Remaining, 5);
  end;
  Move(Source^, Cursor^, Remaining);
  Inc(Cursor, Remaining);
  EmitJump(Cursor, Target + CopyBytes);
  ReportInfo(Format('E7 gateway=%x target=%x copied=%d', [NativeUInt(Gateway), NativeUInt(Target), CopyBytes]));

  VirtualProtect(Target, 5, PAGE_EXECUTE_READWRITE, OldProtect);
  Target^ := $E9;
  PInteger(Target + 1)^ := Integer(NativeInt(Hook) - NativeInt(Target) - 5);
  VirtualProtect(Target, 5, OldProtect, OldProtect);
  FlushInstructionCache(GetCurrentProcess, Target, 5);
end;

procedure RunE7(CopyBytes: Integer; Relocate: Boolean);
begin
  if CopyBytes < 5 then begin
    Report('E7 needs the number of bytes to copy (at least 5)');
    Exit;
  end;
  // The target is NOT called before it is hooked: a one-shot breakpoint on its
  // first byte has to be still armed when the bytes are copied.
  InstallMiniDetour(@E7Target, @E7Hook, CopyBytes, Relocate);
  Report('E7 hook installed');
  try
    var Value := E7Target(3, 4);
    Report(Format('E7 call through the hook returned %d', [Value]));
  except
    on E: Exception do
      ReportCaught('H_E7', E);
  end;
  Inc(GSink, GHookCalls);
  Report(Format('E7 hook calls=%d', [GHookCalls]));
end;

{ ----------------------------------------------------------------------- main }

// Replaces SysUtils' last-chance handler, which opens a message box in a GUI
// program.
procedure LastChanceHandler(ExceptObject: TObject; ExceptAddr: Pointer);
begin
  Report(Format('RTL last-chance handler: %s ExceptAddr=%s', [ExceptObject.ClassName, Rel(NativeUInt(ExceptAddr))]));
  ExitProcess(9900);
end;

function ImageSizeOfThisModule: NativeUInt;
begin
  var Dos := PImageDosHeader(HInstance);
  var Nt := PImageNtHeaders(HInstance + NativeUInt(Dos^._lfanew));
  Result := Nt^.OptionalHeader.SizeOfImage;
end;

function RunExperiment(const Name: string): Boolean;
begin
  Result := True;
  if Name = 'e1' then
    RunTwoPasses('E1', E1Outer)
  else if Name = 'e1deep' then
    RunTwoPasses('E1D', E1DeepOuter)
  else if Name = 'e1thru' then
    RunTwoPasses('E1T', E1ThruOuter)
  else if Name = 'e2p' then
    RunTwoPasses('E2P', E2PlainOuter)
  else if Name = 'e2r' then
    RunTwoPasses('E2R', E2RegsOuter)
  else if Name = 'e2l' then
    RunTwoPasses('E2L', E2LeanOuter)
  else if Name = 'e3x' then
    E3Except(nil)
  else if Name = 'e3f' then
    E3Finally(nil)
  else if Name = 'e3ok' then
    E3Except(@GTarget)
  else if Name = 'e3r' then
    E3Fast(nil)
  else if Name = 'e4' then
    RunE4
  else if Name = 'e5e' then
    RunE5('E5E', E5End)
  else if Name = 'e5m' then
    RunE5('E5M', E5Mid)
  else if Name = 'e5b' then
    RunE5('E5B', E5Before)
  else if Name = 'e7' then
    RunE7(StrToIntDef(ParamStr(2), 0), SameText(ParamStr(3), 'reloc'))
  else
    Result := False;
end;

begin
  NoErrMsg := True;
  ExceptProc := @LastChanceHandler;
  SetErrorMode(SEM_FAILCRITICALERRORS or SEM_NOGPFAULTERRORBOX or SEM_NOOPENFILEERRORBOX);
  GModuleSize := ImageSizeOfThisModule;
  GIndirect := E5Callee;

  var Name := LowerCase(ParamStr(1));
  Report('start ' + Name);
  var ReachedMainBlock := False;
  try
    if not RunExperiment(Name) then begin
      Report('unknown experiment');
      ExitCode := 2;
      Exit;
    end;
  except
    on E: Exception do begin
      ReachedMainBlock := True;
      ReportCaught('MAIN_BLOCK', E);
    end;
  end;
  Report(Format('done sink=%d target=%d', [GSink, GTarget]));
  if ReachedMainBlock then
    ExitCode := 9000 + (GSink and $FF)
  else
    ExitCode := GSink and $FFFF;
end.
