// The body of every plain DLL fixture of DevTools\LoaderTimingProbe. The project
// file holds the `library` heading and the linker directives, then includes this.

uses
  Winapi.Windows,
  LtDllUnit in 'LtDllUnit.pas';

exports
  LtTouch;

procedure LtDllProc(Reason: Integer);
begin
  case Reason of
    DLL_PROCESS_DETACH: LtAnnounce('DllProc DLL_PROCESS_DETACH');
    DLL_THREAD_ATTACH:  LtAnnounce('DllProc DLL_THREAD_ATTACH');
    DLL_THREAD_DETACH:  LtAnnounce('DllProc DLL_THREAD_DETACH');
  end;
end;

begin
  DllProc := @LtDllProc;
  LtAnnounce('library begin..end block (DLL_PROCESS_ATTACH)');
end.
