library NoDebugLib;

// A deliberately plain DLL built WITHOUT Delphi debug info (no .rsm / .tds;
// see build_target.bat). The debugger must load it, leave a breakpoint that
// references this source unverified, and keep the session alive -- "no symbols"
// must never mean a crash.

function NoDebugAdd(A, B: Integer): Integer; stdcall;
begin
  Result := A + B;   // {BP:NODEBUG_DLL_FUNC}
end;

exports
  NoDebugAdd;

begin
end.
