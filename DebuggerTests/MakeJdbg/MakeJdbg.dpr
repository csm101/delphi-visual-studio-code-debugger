program MakeJdbg;

// Test-support tool: converts a Delphi .map into a JCL '.jdbg' sidecar using
// JCL's own ConvertMapFileToJdbgFile. Used by build_jdbg.bat to give the test
// target JCL-only debug data so JclDebugReaderTests can exercise the provider.
// JCL-dependent; built only when JCL is present (see build_jdbg.bat).

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  JclDebug;

begin
  if ParamCount < 1 then begin
    Writeln('Usage: MakeJdbg.exe <path-to-map>');
    Halt(2);
  end;
  var MapPath := ParamStr(1);
  if not FileExists(MapPath) then begin
    Writeln('MAP not found: ', MapPath);
    Halt(2);
  end;
  if ConvertMapFileToJdbgFile(MapPath) then
    Writeln('OK: ', ChangeFileExt(MapPath, '.jdbg'))
  else begin
    Writeln('FAILED to convert: ', MapPath);
    Halt(1);
  end;
end.
