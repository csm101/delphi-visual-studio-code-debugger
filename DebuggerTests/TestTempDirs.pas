unit TestTempDirs;

// Throwaway directories the suite makes, where they live, and how they go away.
//
// Several tests copy a whole target (exe + map + rsm, several megabytes) into a
// scratch directory and LAUNCH it from there. Deleting that directory in a
// `finally` looks right and is not: the debuggee is still running from the
// copied exe and the adapter still has it mapped, so the delete removes what it
// can, fails on the exe, and leaves the directory behind -- every run, silently,
// because a cleanup failure is not a test failure.
//
// Measured on the maintainer's machine, whose TEMP is a RAMDISK: 177
// `dbg_stale_rsm_*`, 176 `tdsstale_*` and 87 `mcp_no_zydis_*` directories
// loose in TEMP, 805 MB between them.
//
// Three rules, in one place so five fixtures cannot each get them slightly
// wrong:
//   * every scratch directory lives under ONE parent (`%TEMP%\DelphiDebuggerTests`),
//     so whatever survives can be removed by deleting a single folder;
//   * the session ends BEFORE the delete, which then retries briefly (Windows
//     releases the image section shortly after the process object goes, not at
//     the same moment);
//   * each test sweeps its own leftovers from earlier runs on the way in.

interface

// The single parent every scratch directory lives under. Created on demand.
function TestScratchRoot: string;

// A fresh scratch directory under that root, named `<Prefix><pid>_<tick>` --
// unique per worker process AND per call, because RunTests runs several worker
// processes at once and two of them reach the same test within a millisecond.
function MakeTestScratchDir(const Prefix: string): string;

// Removes a directory that may be held for another moment, retrying for about a
// second. Best effort: failing to delete a scratch directory is not a test
// result.
procedure DeleteTempDirWithRetry(const Dir: string);

// Removes leftovers of earlier runs, matched by name prefix. Looks under the
// scratch root AND directly under TEMP, where the older builds put them.
// Directories only, prefix-scoped, failures ignored -- one still held by a live
// sibling worker is simply left for a later run to sweep.
procedure PurgeLeftoverTempDirs(const Prefix: string);

implementation

uses
  System.SysUtils, System.IOUtils, Winapi.Windows;

const
  SCRATCH_ROOT_NAME = 'DelphiDebuggerTests';

function TestScratchRoot: string;
begin
  Result := TPath.Combine(TPath.GetTempPath, SCRATCH_ROOT_NAME);
  try
    if not TDirectory.Exists(Result) then
      TDirectory.CreateDirectory(Result);
  except
    // Losing the root is not worth failing a test over: fall back to TEMP
    // itself, which is where these directories used to live anyway.
    Result := TPath.GetTempPath;
  end;
end;

function MakeTestScratchDir(const Prefix: string): string;
begin
  Result := TPath.Combine(TestScratchRoot,
              Format('%s%d_%d', [Prefix, GetCurrentProcessId, GetTickCount]));
  TDirectory.CreateDirectory(Result);
end;

procedure DeleteTempDirWithRetry(const Dir: string);
begin
  if Dir = '' then
    Exit;
  // Ten seconds, measured rather than chosen: at one second three directories
  // per full run survived, at three seconds one still did -- and that one
  // deleted cleanly by hand moments later, so the only thing missing was
  // patience. The wait costs nothing on the normal path (the first attempt
  // succeeds) and is paid only by a directory whose image section is genuinely
  // still mapped. Whatever survives even that is swept by the next run, so the
  // total stays bounded either way; this keeps it at zero.
  for var Attempt := 1 to 100 do begin
    try
      if not TDirectory.Exists(Dir) then
        Exit;
      TDirectory.Delete(Dir, True);
      Exit;
    except
      Sleep(100);
    end;
  end;
end;

procedure PurgeLeftoverTempDirs(const Prefix: string);

  procedure SweepUnder(const Parent: string);
  begin
    try
      for var Dir in TDirectory.GetDirectories(Parent, Prefix + '*') do
        try
          // Only OLD leftovers. The suite runs as several worker PROCESSES, and
          // a sibling's scratch directory matches the same prefix while its
          // test is still using it -- a file lock saved the fixtures whose
          // scratch holds a running exe, but a directory of plain JSON files
          // deleted out from under a live sibling failed two tests on their
          // first parallel run. Ten minutes cleanly separates "a crashed
          // earlier run left this behind" from "a sibling made this seconds
          // ago"; a leftover younger than that survives one run and is swept
          // by the next.
          if TDirectory.GetCreationTime(Dir) < Now - (10 / (24 * 60)) then
            TDirectory.Delete(Dir, True);
        except
          // Held by a running sibling, or by an image section not yet released.
        end;
    except
      // An unreadable directory is not a test's problem.
    end;
  end;

begin
  if Prefix = '' then
    Exit;
  SweepUnder(TestScratchRoot);
  SweepUnder(TPath.GetTempPath);   // leftovers from before the shared root
end;

end.
