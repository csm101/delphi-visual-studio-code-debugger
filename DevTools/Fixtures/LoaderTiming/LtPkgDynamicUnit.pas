unit LtPkgDynamicUnit;

// The one unit of the LtPkgDynamic package, a DevTools\LoaderTimingProbe fixture that
// LtHost.exe loads with LoadPackage (-pkg). Its initialization section announces itself with
// a debug string, and so does the routine the host calls.

interface

function LtPkgDynamicValue(Value: Integer): Integer;

exports
  LtPkgDynamicValue;

implementation

uses
  Winapi.Windows;

{$I LtAnnounce.inc}

var
  GCalls: Integer = 0;

function LtPkgDynamicValue(Value: Integer): Integer;
begin
  Inc(GCalls);
  LtAnnounce('LtPkgDynamicValue called');
  Result := Value * 10 + GCalls;
end;

initialization
  LtAnnounce('initialization of unit LtPkgDynamicUnit');

finalization
  LtAnnounce('finalization of unit LtPkgDynamicUnit');

end.
