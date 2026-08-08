unit McpToolSchemas;

// Builds the MCP `tools/list` array: one entry per semantic debugging tool, each
// with a name, a description written for an autonomous agent, and a JSON-Schema
// `inputSchema`. Kept separate from dispatch so the surface is easy to audit.

interface

uses
  System.JSON;

// Returns a fresh TJSONArray of tool definitions (caller owns it).
function BuildToolsArray: TJSONArray;

implementation

type
  TPropSpec = record
    Name, JsonType, Desc: string;
    Required: Boolean;
  end;

function Prop(const AName, AType, ADesc: string; ARequired: Boolean = False): TPropSpec;
begin
  Result.Name     := AName;
  Result.JsonType := AType;
  Result.Desc     := ADesc;
  Result.Required := ARequired;
end;

function MakeTool(const Name, Desc: string;
  const Props: array of TPropSpec): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('name', Name);
  Result.AddPair('description', Desc);

  var Schema := TJSONObject.Create;
  Schema.AddPair('type', 'object');
  var PropsObj := TJSONObject.Create;
  var RequiredArr := TJSONArray.Create;
  for var P in Props do begin
    var PObj := TJSONObject.Create;
    PObj.AddPair('type', P.JsonType);
    PObj.AddPair('description', P.Desc);
    PropsObj.AddPair(P.Name, PObj);
    if P.Required then
      RequiredArr.Add(P.Name);
  end;
  Schema.AddPair('properties', PropsObj);
  if RequiredArr.Count > 0 then
    Schema.AddPair('required', RequiredArr)
  else
    RequiredArr.Free;
  Result.AddPair('inputSchema', Schema);
end;

function BuildToolsArray: TJSONArray;
begin
  Result := TJSONArray.Create;

  // ---- Session / process management ----
  Result.Add(MakeTool('list_debuggable_processes',
    'List running processes with pid, executable name/path, command line, ' +
    'parent pid, start time and architecture. Optionally filter by executable name. ' +
    'Use this to find a target to attach to.',
    [Prop('nameFilter', 'string', 'Case-insensitive executable basename to filter by (e.g. "notepad" or "notepad.exe"). Omit for all processes.')]));

  Result.Add(MakeTool('launch_debuggee',
    'Start a new process under the debugger. Returns once the process is running ' +
    '(or, if stopAtEntry is true, once it stops at entry). Set breakpoints before or ' +
    'after, then use continue_and_wait.',
    [Prop('program', 'string', 'Full path to the target .exe.', True),
     Prop('args', 'string', 'Command-line arguments passed to the target.'),
     Prop('mapFile', 'string', 'Override path to the .map (defaults to the exe with .map).'),
     Prop('rsmFile', 'string', 'Override path to the .rsm (defaults to the exe with .rsm).'),
     Prop('sourceRoot', 'string', 'Primary root directory to resolve source files against.'),
     Prop('sourceSearchPaths', 'array', 'Additional source roots (array of paths; each may be ;-separated and use ${env:VAR}). Searched when a file is not under sourceRoot.'),
     Prop('workspaceFolder', 'string', 'Base for resolving ${workspaceFolder} in the paths above.'),
     Prop('exceptionFilters', 'array', 'Which exceptions break: any of "delphi" (first-chance Delphi raises), "av" (access violations), "all" (every first-chance), "unhandled" (second-chance). Omit for the default [delphi, av, unhandled]; pass [] or e.g. ["unhandled"] to stop breaking on first-chance exceptions in a noisy app.'),
     Prop('delphiExceptionClasses', 'string', 'Comma/semicolon-separated class names to narrow the "delphi" filter (e.g. "EAccessViolation, EConvertError"). Empty = all Delphi raises.'),
     Prop('stopAtEntry', 'boolean', 'Stop at the program entry point instead of running to the first breakpoint.')]));

  Result.Add(MakeTool('launch_from_config',
    'Launch using an existing VS Code launch.json (the same file the DAP debugger ' +
    'uses) so you need not re-specify program / map / rsm / source paths. Reads a ' +
    'delphi-win64 configuration (JSONC + ${workspaceFolder}/${env:} supported). Stops ' +
    'at entry; then set breakpoints and continue_and_wait.',
    [Prop('configFile', 'string', 'Path to launch.json. Defaults to .vscode\launch.json under the current directory.'),
     Prop('configName', 'string', 'Which configuration ("name") to use. Defaults to the first with type "delphi-win64".'),
     Prop('workspaceFolder', 'string', 'Base for ${workspaceFolder}. Defaults to the launch.json''s parent directory.')]));

  Result.Add(MakeTool('attach_to_process',
    'Attach the debugger to an already-running process, selected by processId or by ' +
    'processName. If a name matches more than one process the call fails and lists the ' +
    'candidates so you can pick a pid. A target of a different architecture is rejected. ' +
    'By default detaching leaves the process running.',
    [Prop('processId', 'integer', 'PID of the target process.'),
     Prop('processName', 'string', 'Executable basename to attach to (must be unambiguous).'),
     Prop('program', 'string', 'Override the exe path used to locate .map/.rsm (defaults to the running image).'),
     Prop('mapFile', 'string', 'Override path to the .map.'),
     Prop('rsmFile', 'string', 'Override path to the .rsm.'),
     Prop('sourceRoot', 'string', 'Primary root directory to resolve source files against.'),
     Prop('sourceSearchPaths', 'array', 'Additional source roots (array of paths; each may be ;-separated and use ${env:VAR}).'),
     Prop('workspaceFolder', 'string', 'Base for resolving ${workspaceFolder} in the paths above.'),
     Prop('killOnDetach', 'boolean', 'If true, terminate the target when the debug session ends; default false (leave it running).')]));

  Result.Add(MakeTool('attach_from_config',
    'Attach using an existing VS Code launch.json "attach" configuration (same file ' +
    'the DAP debugger uses): it supplies the process selector (processId/processName), ' +
    'program/map/rsm and the source paths, so you need not restate them. JSONC and ' +
    '${workspaceFolder}/${env:} are handled.',
    [Prop('configFile', 'string', 'Path to launch.json. Defaults to .vscode\launch.json under the current directory.'),
     Prop('configName', 'string', 'Which configuration ("name"). Defaults to the first delphi-win64 request:"attach" entry.'),
     Prop('workspaceFolder', 'string', 'Base for ${workspaceFolder}. Defaults to the launch.json''s parent directory.'),
     Prop('killOnDetach', 'boolean', 'Terminate the target on session end; default false.')]));

  Result.Add(MakeTool('detach_debugger',
    'Detach from the debuggee, leaving the process RUNNING. Only meaningful for an ' +
    'attached session that did not request killOnDetach.', []));

  Result.Add(MakeTool('terminate_debuggee',
    'Terminate the debuggee process.', []));

  Result.Add(MakeTool('stop_debugging',
    'End the debugging session. Detaches (leaving the process running) for an attached ' +
    'session, or terminates a launched one, unless killOnDetach was set.', []));

  Result.Add(MakeTool('get_debug_session_status',
    'Return the current session state (none/launching/attaching/running/stopped/exited/' +
    'detached/terminated) and, when stopped, the stop reason and current location.', []));

  // ---- Breakpoints ----
  Result.Add(MakeTool('set_breakpoint',
    'Set (or replace) a source-line breakpoint. Returns whether the line resolved to code ' +
    '(verified). Optional condition / hit-count / logpoint refine when it fires.',
    [Prop('sourceFile', 'string', 'Source file basename or path (e.g. "Unit1.pas").', True),
     Prop('line', 'integer', 'Source line number (1-based).', True),
     Prop('condition', 'string', 'Pascal expression; the breakpoint only stops when it is true / non-zero (e.g. "i = 3", "Count > 10").'),
     Prop('hitCondition', 'string', 'Hit-count gate: "5" (5th hit), ">5", ">=5", "%5" (every 5th).'),
     Prop('logMessage', 'string', 'Logpoint: when set, the breakpoint does NOT stop; it emits this message (with {expr} substituted) to the debugger output instead.')]));

  Result.Add(MakeTool('set_breakpoints',
    'Set several breakpoints at once. Each object in "breakpoints" takes sourceFile, ' +
    'line, and optional condition / hitCondition / logMessage. All breakpoints for a ' +
    'given file replace that file''s previous set; files not listed are unchanged.',
    [Prop('breakpoints', 'array', 'Array of { sourceFile, line, condition?, hitCondition?, logMessage? }.', True)]));

  Result.Add(MakeTool('list_breakpoints',
    'List all currently set breakpoints with their verified state.', []));

  Result.Add(MakeTool('remove_all_breakpoints',
    'Remove every breakpoint (source and address).', []));

  Result.Add(MakeTool('set_breakpoint_at_address',
    'Set (or replace) a breakpoint at an ABSOLUTE ADDRESS instead of a source line -- what ' +
    'makes disassemble() actionable in a frame with no symbols (a runtime package built ' +
    'without debug info) or at a specific instruction found by inspection. The address is ' +
    'resolved against the CURRENTLY LOADED modules and stored as (module, offset), never as ' +
    'the bare address -- an address is meaningless across a relaunch or an ASLR-rebased ' +
    'package, so it is re-resolved to a fresh address whenever that module (re)loads. An ' +
    'address inside a module that is NOT currently loaded is refused (verified=false, with a ' +
    'reason) rather than planted somewhere that may belong to something else once a module ' +
    'maps there. Setting the same address again replaces the prior entry. Optional condition / ' +
    'hit-count / logpoint work exactly as they do for a source breakpoint. Appears in ' +
    'list_breakpoints with kind="address".',
    [Prop('address', 'string', 'Absolute address, e.g. "0x140012340" (as echoed by disassemble/get_call_stack/get_raw_stack_scan). Decimal is also accepted.', True),
     Prop('condition', 'string', 'Pascal expression; the breakpoint only stops when it is true / non-zero.'),
     Prop('hitCondition', 'string', 'Hit-count gate: "5" (5th hit), ">5", ">=5", "%5" (every 5th).'),
     Prop('logMessage', 'string', 'Logpoint: when set, the breakpoint does NOT stop; it emits this message (with {expr} substituted) to the debugger output instead.')]));

  Result.Add(MakeTool('remove_breakpoint_at_address',
    'Remove one address breakpoint by id (from set_breakpoint_at_address or list_breakpoints). ' +
    'Returns the remaining breakpoints (source and address).',
    [Prop('id', 'string', 'The id of the address breakpoint to remove.', True)]));

  // ---- Data breakpoints (watchpoints) ----
  Result.Add(MakeTool('set_data_breakpoint',
    'Set a hardware watchpoint that stops execution when the watched memory is written ' +
    '(or read-or-written). Backed by the CPU''s debug registers: only 4 slots exist, shared ' +
    'by the whole process, and the 5th request is refused by name (what already holds the ' +
    'slots), never silently dropped. There is NO read-only watchpoint on x86/x64 -- ' +
    'access="readWrite" is the closest to "stop on read" and it ALSO fires on writes, it does ' +
    'not filter them out; the response says so. A local variable is refused with a reason -- ' +
    'its address is only valid for the lifetime of its stack frame -- so watch the containing ' +
    'global or object field instead, or pass a literal address you already have. Requires the ' +
    'session to be stopped (arming touches live thread contexts). When it fires, the stop''s ' +
    'stopReason is "dataBreakpoint" and dataBreakpointDescription names the watched ' +
    'expression, the old and new values, and the THREAD that wrote it -- frequently the whole ' +
    'answer to "who did this".',
    [Prop('expression', 'string',
       'A literal address ("0x1234", "$1234" or a plain decimal) or a global/unit variable name. ' +
       'Local variables are refused, not silently accepted as a stale address.', True),
     Prop('size', 'integer',
       'Width in bytes: 1, 2, 4 or 8. The address must already be aligned to this width; a ' +
       'misaligned or other-width request is refused, never rounded.', True),
     Prop('access', 'string',
       '"write" to stop only on writes, or "readWrite" to also catch reads -- there is no ' +
       'read-only hardware watchpoint on x86/x64, so "readWrite" ALSO fires on writes, it does ' +
       'not filter them out. "read" alone is refused rather than silently treated as "readWrite".',
       True)]));

  Result.Add(MakeTool('list_data_breakpoints',
    'List every data breakpoint (watchpoint) currently tracked: id, expression, resolved ' +
    'address (plus owning module+rva when known), size, access, whether it actually armed ' +
    '(verified), the hardware slot it holds (0-3, or -1 when refused/not yet armed), and a ' +
    'message -- the refusal reason when not verified, or the read-or-write caveat when access ' +
    'is "readWrite".', []));

  Result.Add(MakeTool('remove_data_breakpoint',
    'Remove one data breakpoint by id (from set_data_breakpoint or list_data_breakpoints) and ' +
    'free its hardware slot. Returns the remaining data breakpoints. Requires the session to ' +
    'be stopped.',
    [Prop('id', 'string', 'The id of the data breakpoint to remove.', True)]));

  // ---- Execution control ----
  Result.Add(MakeTool('continue_and_wait',
    'Resume execution and wait until the debuggee next stops (breakpoint, exception, ' +
    'pause) or exits. Returns a compact debug snapshot of the new state.',
    [Prop('timeoutMs', 'integer', 'Max milliseconds to wait before returning a still-running result (default 30000).')]));

  Result.Add(MakeTool('step_over',
    'Step over one source line, then wait for the stop. By default the stopped thread; ' +
    'pass threadId (from get_threads) to step another thread -- only that thread advances ' +
    '(the rest stay frozen), and run control afterwards targets it. Returns a snapshot.',
    [Prop('threadId', 'integer',
      'OS thread id to step (from get_threads). Omit for the current stopped thread.', False)]));
  Result.Add(MakeTool('step_into',
    'Step into a call on the current source line, then wait for the stop. By default the ' +
    'stopped thread; pass threadId (from get_threads) to step another thread. Returns a snapshot.',
    [Prop('threadId', 'integer',
      'OS thread id to step (from get_threads). Omit for the current stopped thread.', False)]));
  Result.Add(MakeTool('step_out',
    'Run until the current function returns, then wait for the stop. By default the stopped ' +
    'thread; pass threadId (from get_threads) to step another thread. Returns a snapshot.',
    [Prop('threadId', 'integer',
      'OS thread id to step (from get_threads). Omit for the current stopped thread.', False)]));

  Result.Add(MakeTool('pause_execution',
    'Pause a running debuggee. Returns a snapshot once it stops.', []));

  Result.Add(MakeTool('wait_until_stopped',
    'Wait until the debuggee stops (without issuing a command). Use after the target was ' +
    'left running. Returns a snapshot.',
    [Prop('timeoutMs', 'integer', 'Max milliseconds to wait (default 30000).')]));

  // ---- State inspection ----
  Result.Add(MakeTool('get_current_source_location',
    'Return the current function, source file and line at the stop.', []));

  Result.Add(MakeTool('get_call_stack',
    'Return the call stack (innermost frame first) with function, source file and line. ' +
    'By default the stopped/current thread; pass threadId (from get_threads) to walk another thread.',
    [Prop('threadId', 'integer',
      'OS thread id to walk (from get_threads). Omit for the current stopped thread.', False)]));

  Result.Add(MakeTool('get_loaded_modules',
    'List every image mapped in the debuggee (the executable first, then each DLL / runtime ' +
    'package), with its load base, size, symbol state and the debug-info formats that actually ' +
    'loaded for it. Answers the two questions a nameless frame raises: is the owning module even ' +
    'loaded, and does it carry debug info. `symbols` is the same vocabulary the frames use -- ' +
    '"loaded", "noSymbols" (built without debug info), "indexing" (retry shortly). `formats` ' +
    'lists what REGISTERED ("td32", "map", "rsm", "dcp", "jdbg", "tds"), not what was looked ' +
    'for, so an empty list next to "noSymbols" means the binary has none rather than that a ' +
    'sidecar is merely missing. Also the way to tell whether a breakpoint that has not bound is ' +
    'waiting for a package that is not loaded YET. Valid while running as well as while stopped.',
    []));

  Result.Add(MakeTool('get_source_files',
    'List the source files the loaded debug info can name, grouped by owning module. ' +
    'This is the file spelling set_breakpoint expects -- use it instead of guessing a name ' +
    'from a unit or a path. Each group carries `listedBy` (the format that produced the list: ' +
    '"td32", "tds" or "map"), `complete` (false while an index is still filling -- re-ask ' +
    'shortly, the list is partial), and `fileCount`. `listedBy` is null when the module''s ' +
    'loaded formats CANNOT enumerate files (".rsm", ".dcp" and ".jdbg" map addresses but hold ' +
    'no file index): that means "unknown", NOT "this module has no source files", and a ' +
    'breakpoint there may still bind. Only formats already loaded are consulted, so a module ' +
    'whose sidecars have not been probed yet can be missing from the answer; get_loaded_modules ' +
    'says which those are. Valid while running as well as while stopped. ' +
    'Pass `module` to restrict the answer to one image (matched on the file name, ' +
    'case-insensitive), or `nameOnly` to drop the compile-time paths.',
    [Prop('module', 'string',
       'Restrict to this module file name, e.g. "myapp.exe" or "libfoo.bpl". Omit for all.', False),
     Prop('nameOnly', 'boolean',
       'Omit the recorded compile-time path of each file and return names only (default false).', False)]));

  Result.Add(MakeTool('get_raw_stack_scan',
    'LAST RESORT, and NOT a call stack. Brute-force sweep of the thread''s stack for words ' +
    'that could be return addresses, ordered from the top of the stack down. Use it only when ' +
    'get_call_stack STOPS short -- 32-bit targets carry no unwind data, so the walk ends at the ' +
    'first routine built without a frame pointer -- and the question is which of the user''s own ' +
    'routines is somewhere underneath. Each hit is marked kind="rawStackHit"; proven=true means ' +
    'the instruction ending at that address was DECODED and is a call, proven=false means there ' +
    'was no line table to decode from. NEITHER means the routine is still on the current chain: ' +
    'a call that has already returned leaves its return address behind, and no sweep can tell the ' +
    'difference. Report these as places the program HAS BEEN, never as callers, and never merge ' +
    'them into a call stack.',
    [Prop('threadId', 'integer',
       'OS thread id to sweep (from get_threads). Omit for the current stopped thread.', False),
     Prop('maxItems', 'integer',
       'Stop after this many hits. Omit for all of them.', False)]));

  Result.Add(MakeTool('get_threads',
    'List the debuggee''s threads at the current stop (id, name, isStopped, isCurrent). ' +
    'isCurrent marks the thread the debugger reports for this stop -- after a pause that is ' +
    'the main application thread, not the transient thread the OS injected to break in. ' +
    'Pass another thread''s id to get_call_stack to inspect it.', []));

  Result.Add(MakeTool('set_exception_filters',
    'Change which exceptions break, on the LIVE session (also settable at launch via ' +
    'exceptionFilters). Useful to silence first-chance breaks in an app that raises many ' +
    '(e.g. pass ["unhandled"] so only truly-unhandled exceptions stop).',
    [Prop('filters', 'array', 'Any of "delphi", "av", "all", "unhandled". [] = never break on first-chance.', True),
     Prop('delphiExceptionClasses', 'string', 'Comma/semicolon-separated class names to narrow the "delphi" filter. Empty = all.')]));

  Result.Add(MakeTool('get_locals',
    'Return the local variables of a stack frame with their formatted values and types. ' +
    'A class/record value carries expandable:true and a handle; pass the handle to ' +
    'expand_variable to read its children. Defaults to the top frame of the stopped ' +
    'thread; after a pause that is usually inside a system DLL and has no locals, so ' +
    'read the stack with get_call_stack and pass the frameIndex of the frame you want.',
    [Prop('frameIndex', 'integer',
       'Stack frame to read, as returned by get_call_stack (0 = innermost). Omit for the top frame.', False),
     Prop('threadId', 'integer',
       'OS thread id owning the frame (from get_threads). Omit for the stopped thread.', False)]));

  Result.Add(MakeTool('expand_variable',
    'Read the child fields of an expandable variable (class instance or record), given ' +
    'the handle returned by get_locals / get_compact_debug_snapshot / a prior ' +
    'expand_variable. Handles are valid until the next stop. Nested classes/records in ' +
    'the result carry their own handles, so object graphs can be walked step by step.',
    [Prop('handle', 'string', 'The opaque expansion handle of the variable to expand.', True)]));

  Result.Add(MakeTool('get_variable',
    'Return a single named variable. Prefers a frame local (so a class/record/array ' +
    'result carries an expansion handle); otherwise evaluates the name (fields, globals, ' +
    'dotted paths).',
    [Prop('name', 'string', 'The variable or expression name, e.g. "Widget" or "Self.Count".', True),
     Prop('frameIndex', 'integer',
       'Stack frame to read in, as returned by get_call_stack (0 = innermost). Omit for the top frame.', False),
     Prop('threadId', 'integer',
       'OS thread id owning the frame (from get_threads). Omit for the stopped thread.', False)]));

  Result.Add(MakeTool('evaluate_expression',
    'Evaluate a Pascal expression in the context of a stack frame (locals, fields, ' +
    'globals, arithmetic, casts, method calls). Defaults to the top frame of the stopped ' +
    'thread; after a pause that is usually inside a system DLL where nothing resolves, so ' +
    'pass the frameIndex of a frame in your own code.',
    [Prop('expression', 'string', 'The expression to evaluate, e.g. "Widget.FValue" or "Count + 1".', True),
     Prop('frameIndex', 'integer',
       'Stack frame to evaluate in, as returned by get_call_stack (0 = innermost). Omit for the top frame.', False),
     Prop('threadId', 'integer',
       'OS thread id owning the frame (from get_threads). Omit for the stopped thread.', False)]));

  Result.Add(MakeTool('get_exception_details',
    'When stopped on an exception, return its class, message, description and stack.', []));

  Result.Add(MakeTool('get_compact_debug_snapshot',
    'Return, in one call: session state, stop reason, current thread, current location, ' +
    'top stack frames, top-frame locals, and exception info if any. When stopReason is ' +
    '"dataBreakpoint" (a watchpoint fired), dataBreakpointDescription names the watched ' +
    'expression, the old and new values, and the firing thread. Minimises round trips.', []));

  Result.Add(MakeTool('get_debuggee_output',
    'Return debuggee (program stdout) output produced since the previous call (incremental).', []));

  Result.Add(MakeTool('get_debugger_output',
    'Return debugger-generated output since the previous call — notably logpoint messages ' +
    '(incremental).', []));

  Result.Add(MakeTool('read_memory',
    'Read a block of the debuggee''s memory. Returns the bytes as hex plus little-endian ' +
    'integer interpretations, for inspecting raw structures (VMT slots, record fields) the ' +
    'evaluator does not surface. The session must be stopped.',
    [Prop('address', 'string', 'Start address, decimal or 0x-hex (e.g. "0x239B7765CC0").', True),
     Prop('count', 'integer', 'Number of bytes to read (1..4096).', True)]));

  Result.Add(MakeTool('write_memory',
    'Write bytes into the debuggee''s memory at an address. Use with care — it mutates the ' +
    'live process. The session must be stopped.',
    [Prop('address', 'string', 'Start address, decimal or 0x-hex.', True),
     Prop('hexBytes', 'string', 'Bytes to write as contiguous hex (e.g. "48008B00"); whitespace ignored.', True)]));

  Result.Add(MakeTool('disassemble',
    'Disassemble machine code (Zydis, x86/x64, either bitness) starting at an address or at a ' +
    'call-stack frame''s instruction pointer. Use this instead of reading raw bytes with ' +
    'read_memory and reading them yourself — hand-decoding bytes produces a confident WRONG ' +
    'answer, which this tool exists to prevent. Each instruction reports its address (the same ' +
    '"0x..." string a frame or a raw-stack-scan hit already carries in its own "address" field — ' +
    'pass that straight back in, no re-parsing needed), raw bytes, Intel-syntax text, and — when ' +
    'a symbol provider knows one — the nearest function+offset and source file/line. An ' +
    'instruction Zydis cannot decode is reported as "db XX" with decoded:false — NEVER a guessed ' +
    'mnemonic. If the Zydis DLL is missing or the wrong version (no VC++ runtime, or not ' +
    'installed at all), the call returns available:false with a reason and no instructions at ' +
    'all — the ORDINARY case on a machine without it, not an error. ' +
    'Optional "before" asks for up to that many instructions PRECEDING the address. x86/x64 ' +
    'cannot be decoded backwards, so this is answered ONLY when a PROVEN earlier instruction ' +
    'boundary exists (the containing function''s start — from debug info, or from the module''s ' +
    'PE export table when it has none at all — or a nearer line-table boundary) AND decoding ' +
    'forward from it lands EXACTLY on the requested address. When neither holds, "before" comes ' +
    'back with refused:true and a reason naming the cause — but the forward "instructions" are ' +
    'still returned: a refused "before" is not a failed call. The result never mixes proven and ' +
    'unproven instructions in one list.',
    [Prop('address', 'string',
       'Start address, decimal or 0x-hex — e.g. the "address" field already on a stack frame or a ' +
       'raw-stack-scan hit. Omit to use frameIndex/threadId instead.'),
     Prop('frameIndex', 'integer',
       'Used only when address is omitted: which call-stack frame''s instruction pointer to start ' +
       'at, as returned by get_call_stack (0 = innermost). Omit for the top frame.'),
     Prop('threadId', 'integer',
       'Used only when address is omitted: OS thread id owning the frame (from get_threads). ' +
       'Omit for the stopped thread.'),
     Prop('count', 'integer', 'Number of instructions to decode forward from the address (1..500). Default 10.'),
     Prop('before', 'integer',
       'Number of instructions to also return PRECEDING the address (0..100). Default 0 (omitted). ' +
       'May come back refused — see the tool description.')]));
end;

end.
