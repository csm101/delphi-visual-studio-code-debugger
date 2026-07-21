# Registers (or removes) the Delphi Win64 MCP debug server with Claude Code and
# VS Code. Shared by install-dev.bat (points at the build output) and the
# installer / setup zip (points at the installed copy). Idempotent -- safe to
# re-run; -Unregister removes the registration.
#
#   powershell -ExecutionPolicy Bypass -File register-mcp.ps1 <path-to-DelphiDebuggerMcp.exe>
#   powershell -ExecutionPolicy Bypass -File register-mcp.ps1 -Unregister
#
# Claude Code registration uses the `claude` CLI (user scope). VS Code (stable +
# Insiders) is registered by merging the user mcp.json, which needs no CLI.

param(
    [Parameter(Position = 0)][string]$McpExe = '',
    [switch]$Unregister
)

$ErrorActionPreference = 'Continue'
$ServerName = 'delphi-win64-debugger'

if (-not $Unregister) {
    if ($McpExe -eq '' -or -not (Test-Path $McpExe)) {
        Write-Error "MCP server exe not found: '$McpExe' (build it with build_mcp.bat first)."
        exit 1
    }
    $McpExe = (Resolve-Path $McpExe).Path
}

# ---------------------------------------------------------------- Claude Code
function Register-ClaudeCode {
    $cli = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $cli) {
        Write-Host "  Claude Code: 'claude' CLI not on PATH -- skipped."
        if (-not $Unregister) {
            Write-Host "    To register manually:  claude mcp add $ServerName -s user -- `"$McpExe`""
        }
        return
    }
    # Remove first so re-runs update in place (no-op if not present).
    & claude mcp remove $ServerName -s user 2>$null | Out-Null
    if ($Unregister) {
        Write-Host "  Claude Code: removed $ServerName."
        return
    }
    & claude mcp add $ServerName -s user -- $McpExe 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Claude Code: registered $ServerName (user scope)."
    } else {
        Write-Host "  Claude Code: 'claude mcp add' failed (exit $LASTEXITCODE)."
        Write-Host "    Try manually:  claude mcp add $ServerName -s user -- `"$McpExe`""
    }
}

# ------------------------------------------------------------- VS Code family
# Merge the server into an editor's user mcp.json (VS Code 1.102+ format:
# { "servers": { "<name>": { "type":"stdio", "command":..., "args":[] } } }).
function Update-VsCodeMcp([string]$Display, [string]$UserDataDir) {
    $userRoot = Join-Path $env:APPDATA $UserDataDir
    if (-not (Test-Path $userRoot)) {
        return  # editor not installed
    }
    $userDir = Join-Path $userRoot 'User'
    New-Item -ItemType Directory -Force -Path $userDir | Out-Null
    $mcpPath = Join-Path $userDir 'mcp.json'

    $root = $null
    if (Test-Path $mcpPath) {
        try { $root = Get-Content $mcpPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $root = $null }
    }
    if ($null -eq $root) { $root = [pscustomobject]@{} }
    if (-not ($root.PSObject.Properties.Name -contains 'servers')) {
        $root | Add-Member -NotePropertyName servers -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if ($root.servers.PSObject.Properties.Name -contains $ServerName) {
        $root.servers.PSObject.Properties.Remove($ServerName)
    }
    if (-not $Unregister) {
        $srv = [pscustomobject]@{ type = 'stdio'; command = $McpExe; args = @() }
        $root.servers | Add-Member -NotePropertyName $ServerName -NotePropertyValue $srv -Force
    }
    ($root | ConvertTo-Json -Depth 12) | Set-Content -Path $mcpPath -Encoding UTF8
    if ($Unregister) { Write-Host "  ${Display}: removed $ServerName  ($mcpPath)" }
    else             { Write-Host "  ${Display}: registered $ServerName  ($mcpPath)" }
    return $true
}

Write-Host ""
if ($Unregister) { Write-Host "Unregistering MCP server '$ServerName'..." }
else             { Write-Host "Registering MCP server '$ServerName' -> $McpExe" }

Register-ClaudeCode

$editors = @(
    @{ Name = 'VS Code';          Dir = 'Code' },
    @{ Name = 'VS Code Insiders'; Dir = 'Code - Insiders' }
)
$anyEditor = $false
foreach ($e in $editors) {
    if (Update-VsCodeMcp $e.Name $e.Dir) { $anyEditor = $true }
}
if (-not $anyEditor) {
    Write-Host "  VS Code: no user directory found under %APPDATA%\Code(- Insiders) -- skipped."
}

Write-Host ""
if (-not $Unregister) {
    Write-Host "Done. Restart Claude Code / reload VS Code to pick up the server."
}
exit 0
