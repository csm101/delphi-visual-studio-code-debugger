# Registers (or removes) the Delphi MCP debug server with Claude Code, under the
# name `delphi-debugger`. A registration under the earlier name
# `delphi-win64-debugger` is removed when found, so two names never point at two
# copies of the same server. Shared by install-dev.bat (points at the build
# output) and the installer / setup zip (points at the installed copy).
# Idempotent -- safe to re-run.
#
#   powershell -ExecutionPolicy Bypass -File register-mcp.ps1 <path-to-DelphiDebuggerMcp.exe> [-VsCode]
#   powershell -ExecutionPolicy Bypass -File register-mcp.ps1 -Unregister [<path-to-DelphiDebuggerMcp.exe>]
#
# Claude Code registration uses the `claude` CLI (user scope).
#
# VS Code's user mcp.json is written only with -VsCode (install-dev.bat, which
# points VS Code at the build output). The extension registers the server with
# VS Code itself since 0.7.0, so an mcp.json entry next to it listed the server
# twice; without -VsCode this script only REMOVES entries that point at the
# given exe -- the duplicates an earlier Setup.exe wrote.
#
# -Unregister with a path removes only the registrations that point at that
# exe: a development build registered under the same name is someone else's.
# Without a path it removes the names whatever they point at.

param(
    [Parameter(Position = 0)][string]$McpExe = '',
    [switch]$Unregister,
    [switch]$VsCode
)

$ErrorActionPreference = 'Continue'
$ServerName = 'delphi-debugger'
$LegacyServerName = 'delphi-win64-debugger'

if (-not $Unregister) {
    if ($McpExe -eq '' -or -not (Test-Path $McpExe)) {
        Write-Error "MCP server exe not found: '$McpExe' (build it with build_mcp.bat first)."
        exit 1
    }
    $McpExe = (Resolve-Path $McpExe).Path
}
elseif ($McpExe -ne '') {
    $McpExe = [IO.Path]::GetFullPath($McpExe)   # may already be deleted
}

function Test-SamePath([string]$A, [string]$B) {
    if ([string]::IsNullOrWhiteSpace($A) -or [string]::IsNullOrWhiteSpace($B)) { return $false }
    try {
        $left  = [IO.Path]::GetFullPath($A.Trim('"'))
        $right = [IO.Path]::GetFullPath($B.Trim('"'))
    } catch { return $false }
    return [string]::Equals($left, $right, [StringComparison]::OrdinalIgnoreCase)
}

# What `claude mcp get <name>` reports as the command, or $null when the name
# is not registered.
function Get-ClaudeCommand([string]$Name) {
    $out = & claude mcp get $Name 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    foreach ($line in @($out)) {
        if ($line -match '^\s*Command:\s*(.+?)\s*$') { return $Matches[1].Trim('"') }
    }
    return $null
}

# Whether a registration of this name is ours to remove in this run.
function Test-OursToRemove([string]$RegisteredCommand) {
    if ($McpExe -eq '') { return $true }   # -Unregister without a path: the names, whatever they point at
    return (Test-SamePath $RegisteredCommand $McpExe)
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
    if ($Unregister) {
        foreach ($name in @($LegacyServerName, $ServerName)) {
            $command = Get-ClaudeCommand $name
            if ($null -eq $command) { continue }
            if (Test-OursToRemove $command) {
                & claude mcp remove $name -s user 2>$null | Out-Null
                Write-Host "  Claude Code: removed $name."
            } else {
                Write-Host "  Claude Code: $name points at $command, not at this installation -- kept."
            }
        }
        return
    }
    # Remove first so re-runs update in place (no-op if not present), and the
    # registration made under the old name with it.
    & claude mcp remove $LegacyServerName -s user 2>$null | Out-Null
    & claude mcp remove $ServerName -s user 2>$null | Out-Null
    & claude mcp add $ServerName -s user -- $McpExe 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Claude Code: registered $ServerName (user scope)."
    } else {
        Write-Host "  Claude Code: 'claude mcp add' failed (exit $LASTEXITCODE)."
        Write-Host "    Try manually:  claude mcp add $ServerName -s user -- `"$McpExe`""
    }
}

# ------------------------------------------------------------- VS Code family
# An editor's user mcp.json (VS Code 1.102+ format:
# { "servers": { "<name>": { "type":"stdio", "command":..., "args":[] } } }).
# Written with -VsCode; otherwise only cleaned of the entries that point at
# $McpExe. A file that is not plain JSON (comments) is left alone.
function Update-VsCodeMcp([string]$Display, [string]$UserDataDir) {
    $userRoot = Join-Path $env:APPDATA $UserDataDir
    if (-not (Test-Path $userRoot)) {
        return  # editor not installed
    }
    $userDir = Join-Path $userRoot 'User'
    $mcpPath = Join-Path $userDir 'mcp.json'
    $writing = $VsCode -and -not $Unregister
    if (-not $writing -and -not (Test-Path $mcpPath)) {
        return
    }

    $root = $null
    if (Test-Path $mcpPath) {
        try { $root = Get-Content $mcpPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } catch {
            Write-Host "  ${Display}: $mcpPath is not plain JSON -- left as it is."
            return
        }
    }
    if ($null -eq $root) { $root = [pscustomobject]@{} }
    if (-not ($root.PSObject.Properties.Name -contains 'servers')) {
        if (-not $writing) { return }
        $root | Add-Member -NotePropertyName servers -NotePropertyValue ([pscustomobject]@{}) -Force
    }

    $removed = @()
    foreach ($name in @($LegacyServerName, $ServerName)) {
        $entry = $root.servers.PSObject.Properties[$name]
        if ($null -eq $entry) { continue }
        if ($writing -or (Test-OursToRemove $entry.Value.command)) {
            $root.servers.PSObject.Properties.Remove($name)
            $removed += $name
        }
    }
    if ($writing) {
        $srv = [pscustomobject]@{ type = 'stdio'; command = $McpExe; args = @() }
        $root.servers | Add-Member -NotePropertyName $ServerName -NotePropertyValue $srv -Force
    }
    if (-not $writing -and $removed.Count -eq 0) {
        return
    }
    New-Item -ItemType Directory -Force -Path $userDir | Out-Null
    ($root | ConvertTo-Json -Depth 12) | Set-Content -Path $mcpPath -Encoding UTF8
    if ($writing) { Write-Host "  ${Display}: registered $ServerName  ($mcpPath)" }
    else          { Write-Host "  ${Display}: removed $($removed -join ', ')  ($mcpPath)" }
}

Write-Host ""
if ($Unregister) { Write-Host "Unregistering MCP server '$ServerName'$(if ($McpExe) { " ($McpExe)" })..." }
else             { Write-Host "Registering MCP server '$ServerName' -> $McpExe" }

Register-ClaudeCode

foreach ($e in @(
    @{ Name = 'VS Code';          Dir = 'Code' },
    @{ Name = 'VS Code Insiders'; Dir = 'Code - Insiders' }
)) {
    Update-VsCodeMcp $e.Name $e.Dir
}

Write-Host ""
if (-not $Unregister) {
    Write-Host "Done. Restart Claude Code to pick up the server."
}
exit 0
