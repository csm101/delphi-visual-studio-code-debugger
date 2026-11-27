program QuietFailNoSysUtilsConsole;

// Console twin of QuietFailNoSysUtilsGui (fixture of FixtureQuietTests, scenario
// in QuietFailCore).

{$APPTYPE CONSOLE}

uses
  FixtureQuietNoSysUtils, QuietFailCore;

type
  // No Exception class without System.SysUtils: any class can be raised.
  EQuietFailNoSysUtils = class(TObject)
  end;

procedure RaiseUnhandled;
begin
  raise EQuietFailNoSysUtils.Create;
end;

begin
  RunQuietFailScenario(RaiseUnhandled);
end.
