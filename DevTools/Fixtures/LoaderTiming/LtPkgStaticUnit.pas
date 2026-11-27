unit LtPkgStaticUnit;

// The one unit of the LtPkgStatic package, a DevTools\LoaderTimingProbe fixture that
// LtHost.exe requires statically. Its initialization section announces itself with
// a debug string, and so does the routine the host calls.

interface

function LtPkgStaticValue(Value: Integer): Integer;

exports
  LtPkgStaticValue;

implementation

uses
  Winapi.Windows;

{$I LtAnnounce.inc}

var
  GCalls: Integer = 0;

function LtPkgStaticValue(Value: Integer): Integer;
begin
  Inc(GCalls);
  LtAnnounce('LtPkgStaticValue called');
  Result := Value * 10 + GCalls;
end;

initialization
  LtAnnounce('initialization of unit LtPkgStaticUnit');

finalization
  LtAnnounce('finalization of unit LtPkgStaticUnit');

end.
