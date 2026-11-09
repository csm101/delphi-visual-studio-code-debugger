program StdioConsoleSample;

// Console-subsystem twin of StdioGuiSample; both run StdioSampleCore's scenario.
// A console child that shares its parent's console receives the parent's
// standard handles unless the parent passes handles of its own, and the parent
// here is the DAP / MCP server, whose stdin / stdout ARE the protocol channel
// (docs/TRAPS.md).
//
// The one fixture that is not GUI subsystem, on purpose: the console subsystem
// is the subject. Options in StdioConsoleSample.cfg.

{$APPTYPE CONSOLE}

uses
  StdioSampleCore;

begin
  RunStdioScenario;
end.
