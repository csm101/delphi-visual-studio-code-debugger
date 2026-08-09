program ExcNestFixture;

{
  Debuggee fixture for DevTools\ExcHandlerProbe.

  Raises inside NESTED protection, so that at the first-chance exception both an
  inner try/finally and an outer try/except are already on the stack:

      Level1Except   try .. except      <- the block a "step at an exception
        Level2Finally  try .. finally      stop" is expected to land in, unless
          Level3Raise    raise            the finally runs first
            (or a nil-pointer write with -av)

  It is a SEPARATE target on purpose: adding scenarios to DebuggerTests'
  TestTarget shifts RSM import indices and marker ordering (TRAPS.md).

  GUI SUBSYSTEM, NO OUTPUT, ON PURPOSE. A console debuggee makes Windows
  allocate a new console window on every launch, and a probe that relaunches it
  dozens of times steals the keyboard focus every few seconds. There is nothing
  to print anyway: everything this fixture exists to demonstrate is observed
  from the DEBUGGER side. GSink is written only so the compiler cannot elide the
  blocks; ExitCode carries it out for anyone who wants it.

  Build both bitnesses with DevTools\build_exc_fixture.bat -- full debug info
  (-$O- -V -VN -VR -GD) so a candidate handler address found in .pdata / in the
  fs:[0] chain can be mapped back to a source line and checked against the block
  it is supposed to be.

  Usage: ExcNestFixture [-av] [-bare | -two] [-nofinally]
    (default)   raise Exception.Create  -> $0EEDFADE
    -av         write through a nil pointer -> $C0000005
    -bare       outer handler is a bare `except` with no `on` clause
    -two        outer handler has two `on` clauses, the first not matching
    -nofinally  skip Level2Finally, so the outer handler is the FIRST protected
                frame the exception reaches. Without it every scenario lands in
                the intervening try/finally first (which is the correct answer
                for a debugger that stops at whichever handler runs first), and
                the except variants are unreachable as a landing site.
}

uses
  System.SysUtils;

var
  GSink: Integer = 0;

procedure Level3Raise(UseAccessViolation: Boolean);
begin
  Inc(GSink);
  if UseAccessViolation then begin
    var Bad: PInteger := nil;
    Bad^ := 42;                                       // AV_SITE
    Exit;
  end;
  raise Exception.Create('exc-nest-probe');           // RAISE_SITE
end;

procedure Level2Finally(UseAccessViolation: Boolean);
begin
  try
    Level3Raise(UseAccessViolation);
  finally
    Inc(GSink, 10);                                   // FINALLY_BLOCK
  end;
end;

// The single seam that decides whether the intervening try/finally is on the
// stack. Without -nofinally every scenario lands in Level2Finally's finally,
// because that is the handler the exception reaches first; with it, the outer
// routine's own except block is the first protected frame.
procedure RaiseInto(UseAccessViolation, SkipFinally: Boolean);
begin
  if SkipFinally then
    Level3Raise(UseAccessViolation)
  else
    Level2Finally(UseAccessViolation);
end;

procedure Level1Except(UseAccessViolation, SkipFinally: Boolean);
begin
  try
    RaiseInto(UseAccessViolation, SkipFinally);
  except
    on E: Exception do
      Inc(GSink, 100);                                // EXCEPT_BLOCK
  end;
end;

// Same shape, but a bare `except` with no `on` clause -- the layout question is
// whether the clause table degenerates to a count of zero and where the block
// address then lives.
procedure Level1BareExcept(UseAccessViolation, SkipFinally: Boolean);
begin
  try
    RaiseInto(UseAccessViolation, SkipFinally);
  except
    Inc(GSink, 1000);                                 // BARE_EXCEPT_BLOCK
  end;
end;

// Two `on` clauses, the FIRST of which does not match, so the table must carry
// both and the debugger cannot simply take entry 0.
procedure Level1TwoClauses(UseAccessViolation, SkipFinally: Boolean);
begin
  try
    RaiseInto(UseAccessViolation, SkipFinally);
  except
    on E: EAccessViolation do
      Inc(GSink, 10000);                              // AV_CLAUSE
    on E: Exception do
      Inc(GSink, 100000);                             // EXC_CLAUSE
  end;
end;

begin
  var UseAv := FindCmdLineSwitch('av', ['-', '/'], True);
  var SkipFinally := FindCmdLineSwitch('nofinally', ['-', '/'], True);
  if FindCmdLineSwitch('bare', ['-', '/'], True) then
    Level1BareExcept(UseAv, SkipFinally)
  else if FindCmdLineSwitch('two', ['-', '/'], True) then
    Level1TwoClauses(UseAv, SkipFinally)
  else
    Level1Except(UseAv, SkipFinally);
  ExitCode := GSink;
end.
