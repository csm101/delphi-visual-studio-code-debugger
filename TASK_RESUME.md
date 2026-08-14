# TASK_RESUME

## Safelist increment 2a — auto-call time budget (uncommitted)

Getters the safelist authorises were called with the SAME 8 s watchdog as an
explicit "expand to evaluate" click. One blocking getter froze the Variables
panel for the whole timeout, once per authorised row. 2b (entry-byte hook sniff)
is NOT in this change.

**Written, not yet compiled:**

- `DebugTarget.pas` — `BeginAutoCallWindow` / `EndAutoCallWindow` /
  `AutoCallWindowExhausted` on `IDebugTarget`.
- `WinDebuggerBase.pas` — `FAutoCallDepth` / `FAutoCallDeadline` (plain fields:
  same-thread by construction), the three methods, and in `RunMethodCall` a
  second constant `REMOTE_CALL_AUTO_TIMEOUT_MS = 400` clamping `CallDeadline` to
  `min(now + 400, window deadline)` while a window is open.
- `VariableExpander.pas` — `AUTO_CALL_WINDOW_MS = 1000`; `ExpandProperties`
  opens ONE window around the whole property group (only when `Policy <> nil`
  and `Debugger <> nil`) and closes it in the existing `finally`; the auto-call
  branch also requires `not AutoCallWindowExhausted`; `EvaluateGetterInto`
  became a **function** returning False when the window is spent on failure, so
  the caller renders the placeholder instead of `<evaluation cancelled>`.
- `ValueReaderTests.pas` — `TFakeMemTarget` stubs (second `IDebugTarget` impl).
- `TestTargetCore.pas` — `TWidget.DoSlowScore` (`Sleep(5000)`) +
  `property SlowScore`. **Target must be rebuilt.**
- `SafelistDapTests.pas` — `ScoreRow` generalised to `PropRow(name)`, new
  `Safelist(expr, verdict)` helper, new test
  `AnAuthorisedGetterThatHangs_DefersInsteadOfHoldingThePanel`.

**Proven:** the test is RED without the clamp (renders `126` — the real value,
after waiting the full 5 s, which is the frozen panel) and GREEN with it. The
suite otherwise stood at 1254 / 1249 / 1 failed (only the new test) / 0 / 4.

**Measured, and it cost a wrong hypothesis:** a getter cut short leaves the
debuggee thread INSIDE its blocking call. Aborting hijacks RIP, but a thread
parked in `NtDelayExecution` does not reach the forced trap until the sleep ends,
so the pump falls through to its 2 s hard-restore -- and for the REST of the
5 s nothing else can be called on that thread. A second walk therefore sees every
authorised getter fail, which says nothing about the budget. The test reads both
rows from ONE walk for that reason. Neither the safelist file nor member order
was ever at fault (both were checked and cleared).

**Next action:** full `build_and_run.bat` (running); then commit, then decide
whether 2b is worth it.

**Watch for:** the 4500 ms bound in the new test is the only timing assertion; if
it proves flaky under parallel load the fix is a larger bound, not
`NOT_PARALLEL_SAFE`.

**Not decided:** whether `AUTO_CALL_WINDOW_MS` should be reachable from
launch.json. Deliberately hardcoded until real use shows the fallback is too
eager.
