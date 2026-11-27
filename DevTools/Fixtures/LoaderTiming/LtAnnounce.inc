// Shared by every LoaderTimingProbe fixture unit: one debug string that names
// the module the calling unit was linked into (HInstance is per module, so a
// unit in a package reports the package and not the host).
//
// The including unit must have Winapi.Windows in its uses clause.

procedure LtAnnounce(const What: string);
var
  Path: array[0..MAX_PATH] of Char;
begin
  var Length := GetModuleFileName(HInstance, Path, MAX_PATH);
  var Start := Length;
  while (Start > 0) and (Path[Start - 1] <> '\') do
    Dec(Start);
  var Line: string := 'LT ' + PChar(@Path[Start]) + ': ' + What;
  OutputDebugString(PChar(Line));
end;
