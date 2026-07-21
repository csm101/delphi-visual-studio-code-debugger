program DelphiDebuggerMcp;

// MCP (Model Context Protocol) stdio server exposing the Delphi Win64 debugger
// as semantic tools for an autonomous agent. Shares the debug engine with the
// DAP adapter via TDebugSession; stdout carries ONLY JSON-RPC (diagnostics go to
// %TEMP%\mcp_adapter.log). Register with Claude Code as a stdio MCP server.

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Winapi.Windows,
  McpServer in 'McpServer.pas',
  McpJson in 'McpJson.pas',
  McpToolSchemas in 'McpToolSchemas.pas',
  LaunchConfig in 'LaunchConfig.pas',
  DebugSession in '..\DebuggerCore\DebugSession.pas',
  DebugSessionTypes in '..\DebuggerCore\DebugSessionTypes.pas',
  SourceResolver in '..\DebuggerCore\SourceResolver.pas',
  ProcessEnum in '..\DebuggerCore\ProcessEnum.pas';

begin
  try
    RunMcpServer;
  except
    on E: Exception do begin
      var Msg := 'Fatal: ' + E.ClassName + ': ' + E.Message + sLineBreak;
      var Bytes := TEncoding.UTF8.GetBytes(Msg);
      var Written: DWORD;
      WriteFile(GetStdHandle(STD_ERROR_HANDLE), Bytes[0], Length(Bytes), Written, nil);
      ExitCode := 1;
    end;
  end;
end.
