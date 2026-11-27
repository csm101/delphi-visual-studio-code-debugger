program QuietFailConsole;

// Console twin of QuietFailGui (fixture of FixtureQuietTests, scenario in
// QuietFailCore).

{$APPTYPE CONSOLE}

uses
  FixtureQuiet, QuietFailCore, System.SysUtils;

procedure RaiseUnhandled;
begin
  raise Exception.Create(QUIET_FAIL_MESSAGE);
end;

begin
  RunQuietFailScenario(RaiseUnhandled);
end.
