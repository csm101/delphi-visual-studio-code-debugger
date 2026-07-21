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
    'Remove every breakpoint.', []));

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
    'top stack frames, top-frame locals, and exception info if any. Minimises round trips.', []));

  Result.Add(MakeTool('get_debuggee_output',
    'Return debuggee (program stdout) output produced since the previous call (incremental).', []));

  Result.Add(MakeTool('get_debugger_output',
    'Return debugger-generated output since the previous call — notably logpoint messages ' +
    '(incremental).', []));
end;

end.
