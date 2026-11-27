program QuietFailNoSysUtilsGui;

// QuietFailGui without System.SysUtils, quieted by FixtureQuietNoSysUtils
// (fixture of FixtureQuietTests, scenario in QuietFailCore).

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
