# PostToolUse hook: keep docs/TASK_RESUME.md a cursor, not a journal.
#
# docs/TASK_RESUME.md once reached 3343 lines (~91k tokens) because it was appended to
# instead of rewritten. CLAUDE.md now says it is overwritten and capped, but an
# instruction is not a mechanism -- this is the mechanism.
#
# Reads the hook payload on stdin. Silent unless the file exceeds the cap;
# exit code 2 feeds the message back to the model.

$ErrorActionPreference = 'Stop'
$MaxLines = 150

try {
  $raw = [Console]::In.ReadToEnd()
  if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

  $payload = $raw | ConvertFrom-Json
  $target  = $payload.tool_input.file_path
  if (-not $target) { $target = $payload.tool_response.filePath }
  if (-not $target) { exit 0 }

  if ([System.IO.Path]::GetFileName($target) -ne 'docs/TASK_RESUME.md') { exit 0 }
  if (-not (Test-Path -LiteralPath $target)) { exit 0 }

  $lines = (Get-Content -LiteralPath $target | Measure-Object -Line).Lines
  if ($lines -le $MaxLines) { exit 0 }

  $msg = @"
docs/TASK_RESUME.md is now $lines lines, over the $MaxLines-line cap.

It is the cursor inside the task in flight, not a journal, and it is OVERWRITTEN
rather than appended to. Going over the cap means it is holding something that
belongs elsewhere. Move it now, before it grows further:

  a measured fact about a format      -> RSM_*.md, docs/TD32_FORMAT_NOTES.md
  an architectural decision/mechanism -> docs/DAP_DEBUGGER_ARCHITECTURE.md
  an open question or refuted attempt -> docs/KNOWN_UNKNOWNS.md
  a rule that prevents wasted work    -> docs/TRAPS.md
  done / next at project scale        -> docs/PROJECT_STATE.md
  the narrative of a landed change    -> the commit message

Then delete from docs/TASK_RESUME.md everything that is no longer true.
"@
  [Console]::Error.WriteLine($msg)
  exit 2
}
catch {
  # A broken hook must never block work.
  exit 0
}
