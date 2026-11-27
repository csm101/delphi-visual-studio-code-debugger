program QuietFailGui;

// Fixture of FixtureQuietTests (scenario in QuietFailCore): a GUI-subsystem
// program with System.SysUtils, quieted by FixtureQuiet. QuietFailConsole is its
// console twin; QuietFailNoSysUtils* are the same without System.SysUtils.

uses
  FixtureQuiet, QuietFailCore, System.SysUtils;

procedure RaiseUnhandled;
begin
  raise Exception.Create(QUIET_FAIL_MESSAGE);
end;

begin
  RunQuietFailScenario(RaiseUnhandled);
end.
