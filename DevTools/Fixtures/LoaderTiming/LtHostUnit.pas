unit LtHostUnit;

// A unit of LtHost.exe whose only job is to have an initialization section that
// announces itself (DevTools\LoaderTimingProbe fixture).

interface

var
  LtHostUnitInitialised: Boolean = False;

procedure LtAnnounce(const What: string);

implementation

uses
  Winapi.Windows;

{$I LtAnnounce.inc}

initialization
  LtAnnounce('initialization of unit LtHostUnit');
  LtHostUnitInitialised := True;

finalization
  LtAnnounce('finalization of unit LtHostUnit');

end.
