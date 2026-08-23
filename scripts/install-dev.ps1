param([string]$RepoRoot)

# Dev mode: point the installed VS Code extension's debug-adapter `program`
# directly at the compiler build output, so a `build_dap.bat` rebuild is picked
# up on the next debug session with NO copy and NO re-install.
#
# This PATCHES the VSIX-installed extension folder(s) in place
# (local.delphi-win64-debug-<version>). That is robust on VS Code 1.96+, which
# only loads VSIX-registered extensions and ignores raw folder copies dropped
# into the extensions directory. (The old approach -- creating an unversioned
# local.delphi-win64-debug folder -- was silently ignored on 1.96+ and could
# double-register the `delphi-win64` debug type on older builds.)

$RepoRoot = $RepoRoot.Trim('"').TrimEnd('\', '/')

# Write package.json WITHOUT a byte-order mark. `Set-Content -Encoding UTF8`
# emits one under Windows PowerShell 5.1, which is what install-dev.bat invokes,
# and VS Code's extension-manifest parser rejects a BOM outright: the extension
# then shows as "delphi-win64-debug ... is not valid JSON" and loses its display
# name, its icon and every contribution. The staged file in the repository has no
# BOM; only this script was adding one.
function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
}

$adapterExe = Join-Path $RepoRoot 'VisualStudioCodeDelphiDebugger\Win64\Debug\VisualStudioCodeDelphiDebugger.exe'
if (-not (Test-Path $adapterExe)) {
    Write-Error "Adapter exe not found: $adapterExe  (run build_dap.bat first)"
    exit 1
}

$extRoot = Join-Path $env:USERPROFILE '.vscode\extensions'
$targets = @(Get-ChildItem -Path $extRoot -Directory -Filter 'local.delphi-win64-debug*' -ErrorAction SilentlyContinue)
if ($targets.Count -eq 0) {
    Write-Error "No installed 'local.delphi-win64-debug*' extension found under $extRoot.`nRun install\Install.exe (or the distributed Setup.exe) once first, then re-run install-dev."
    exit 1
}

# VS Code accepts forward slashes on Windows and they need no JSON escaping.
$adapterJson = $adapterExe -replace '\\', '/'

# The extension itself now HAS code (extension.js + the webview assets), not just
# a manifest, so pointing `program` at the build output is no longer enough for a
# dev loop: an edit to extension.js, a new command or a new launch property would
# stay invisible until the next full Install.exe. Mirror the staged extension
# files into the installed folder first, then patch the manifest below.
# The adapter exe is skipped on purpose -- `program` points at the build output.
$stageDir = Join-Path $RepoRoot 'install\local.delphi-win64-debug'
if (-not (Test-Path $stageDir)) {
    Write-Error "Extension source folder not found: $stageDir"
    exit 1
}

# A version BUMP cannot be delivered by syncing files. VS Code registers an
# extension by id+version: the folder name and `extensions.json` both carry the
# version it was installed with, and only VS Code's own installer writes those.
# So the synced manifest KEEPS the installed version rather than the staged one.
# Copying the staged version in would leave the registry saying one thing and the
# manifest another - an inconsistency this script created once before this guard
# existed. Everything else in the manifest (new commands, new launch properties)
# does sync, which is the point.
$stagedVersion = (Get-Content (Join-Path $stageDir 'package.json') -Raw |
                  ConvertFrom-Json).version

$synced = 0
foreach ($t in $targets) {
    # The version VS Code registered this folder under. Take it from the FOLDER
    # NAME, not from the manifest inside: VS Code chose that name at install time
    # and it stays true, whereas the manifest is the file this script overwrites
    # and may already carry a staged version from an earlier run.
    $installedPkg = Join-Path $t.FullName 'package.json'
    $installedVersion = $null
    if ($t.Name -match '-(\d+\.\d+\.\d+)$') {
        $installedVersion = $Matches[1]
    }
    elseif (Test-Path $installedPkg) {
        $installedVersion = (Get-Content $installedPkg -Raw | ConvertFrom-Json).version
    }

    foreach ($src in (Get-ChildItem -Path $stageDir -Recurse -File)) {
        if ($src.Extension -eq '.exe') { continue }
        $rel  = $src.FullName.Substring($stageDir.Length).TrimStart('\', '/')
        $dest = Join-Path $t.FullName $rel
        $destDir = Split-Path $dest -Parent
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force $destDir | Out-Null }
        Copy-Item $src.FullName $dest -Force
        $synced++
    }

    if ($installedVersion -and ($installedVersion -ne $stagedVersion)) {
        $raw = Get-Content $installedPkg -Raw -Encoding UTF8
        $raw = [regex]::Replace($raw, '"version"\s*:\s*"[^"]*"',
                                '"version": "' + $installedVersion + '"', 1)
        Write-Utf8NoBom $installedPkg $raw
        Write-Host ("Kept registered version {0} (repository stages {1}); run install\Install.exe to register the new one." `
                    -f $installedVersion, $stagedVersion)
    }
}
Write-Host "Synced $synced extension file(s) from $stageDir"

$patched = 0
foreach ($t in $targets) {
    $pkg = Join-Path $t.FullName 'package.json'
    if (-not (Test-Path $pkg)) { continue }
    $raw = Get-Content $pkg -Raw -Encoding UTF8
    # Match only the adapter `program` (its value ends in the adapter exe name);
    # the launch-config schema `program` (the user's target exe) never does.
    $new = [regex]::Replace(
        $raw,
        '"program"\s*:\s*"[^"]*VisualStudioCodeDelphiDebugger\.exe"',
        '"program": "' + $adapterJson + '"')
    if ($new -ne $raw) {
        Write-Utf8NoBom $pkg $new
        Write-Host "Patched: $pkg"
        $patched++
    }
    else {
        Write-Host "Already points at build output: $pkg"
    }
}

Write-Host ""
Write-Host "Adapter: $adapterExe"
Write-Host "Reload VS Code once (Ctrl+Shift+P -> Developer: Reload Window)."
Write-Host "After that: build_dap.bat alone is enough for ADAPTER changes -- but a"
Write-Host "change to the extension itself (extension.js, the manifest, the webview)"
Write-Host "needs this script again plus a window reload, because VS Code loads that"
Write-Host "code from the installed folder, not from the repository."
