# Builds the distributable zip and creates a DRAFT GitHub release for it.
#
# Called through make_release.bat. Never publishes: it leaves a draft so the
# notes can be read once with fresh eyes before anything becomes visible.
#
#   make_release.bat                     build, render notes, create the draft
#   make_release.bat -DryRun             render the notes and stop, change nothing
#   make_release.bat -SkipBuild          reuse the zip already in dist\
#   make_release.bat -Highlights x.md    file whose contents become "What's new"
#
# The version is never typed by hand: it comes from the extension manifest,
# which is the same value the installer registers with VS Code. A release whose
# tag disagrees with the manifest inside its own zip is a support nightmare, so
# there is deliberately no way to override it here.

param(
    [switch]$DryRun,
    [switch]$SkipBuild,
    [switch]$Verify,
    [string]$Highlights = ''
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot

function Fail([string]$message) {
    Write-Host "ERROR: $message" -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------ verify mode --
# Run AFTER publishing: the tag does not exist until then, because GitHub
# creates it when the draft is published, not when it is created.
#
# This is the check whose absence let one mistake ship four times. `gh release
# view` reported the notes and the assets, all of them correct, while the tag
# pointed at a commit eleven days older than the payload -- and nothing compared
# the two.
if ($Verify) {
    $manifestPath = Join-Path $repo 'install\local.delphi-win64-debug\package.json'
    $version = (Get-Content $manifestPath -Raw | ConvertFrom-Json).version
    if (-not $version) { Fail "the extension manifest declares no version" }
    $tag = "v$version"

    $rel = gh release view $tag --json tagName,isDraft,targetCommitish 2>&1 | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { Fail "release $tag not found on GitHub." }
    if ($rel.isDraft) {
        Write-Host "NOTE: $tag is still a DRAFT, so no tag exists yet. Publish it first:" -ForegroundColor Yellow
        Write-Host "  gh release edit $tag --draft=false"
        exit 0
    }

    & git -C $repo fetch --tags --quiet origin
    $tagCommit = (& git -C $repo rev-parse --quiet --verify "$tag^{commit}" 2>$null)
    if (-not $tagCommit) { Fail "$tag is published but no such tag reached this clone." }
    $tagCommit = $tagCommit.Trim()

    Write-Host "release $tag"
    Write-Host "  target recorded on the release : $($rel.targetCommitish)"
    Write-Host "  commit the tag actually points : $tagCommit"

    # The target is written as a full sha by this script. Anything else means an
    # older release, or a hand-made one, that named a BRANCH -- which is exactly
    # how the tag drifts away from the payload.
    if ($rel.targetCommitish -notmatch '^[0-9a-f]{40}$') {
        Fail ("$tag records `"$($rel.targetCommitish)`" as its target, which is a branch name, " +
              "not a commit. GitHub resolved it when the release was published, so the tag " +
              "describes whatever that branch pointed at THEN -- not necessarily what was shipped.")
    }
    if ($tagCommit -ne $rel.targetCommitish) {
        Fail ("$tag points at $tagCommit but the release was built from $($rel.targetCommitish). " +
              "The tag and the payload describe different trees.")
    }

    Write-Host ''
    Write-Host "OK: $tag points at the commit it was built from." -ForegroundColor Green
    exit 0
}

# --------------------------------------------------------------- preflight --

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Fail "the GitHub CLI (gh) is not on PATH. Install it from https://cli.github.com/ and run 'gh auth login'."
}
gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "gh is installed but not authenticated. Run 'gh auth login'." }

$manifestPath = Join-Path $repo 'install\local.delphi-win64-debug\package.json'
if (-not (Test-Path $manifestPath)) { Fail "extension manifest not found: $manifestPath" }
$version = (Get-Content $manifestPath -Raw | ConvertFrom-Json).version
if (-not $version) { Fail "the extension manifest declares no version" }
$tag = "v$version"

# A tag that already exists means this version was released before. Bump the
# manifest instead of overwriting something people may already have downloaded.
# (`gh release view` finds drafts too, which is what we want: a draft is a
# release in progress, not a free slot.) A dry run only reports it, since it
# sends nothing to GitHub and rendering the notes is still useful.
gh release view $tag --json tagName 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    if (-not $DryRun) {
        Fail "release $tag already exists. Bump `"version`" in install\local.delphi-win64-debug\package.json first."
    }
    Write-Host "NOTE: release $tag already exists; a real run would refuse to overwrite it." -ForegroundColor Yellow
}

# Unpushed commits would produce a release pointing at a tree nobody can fetch.
$unpushed = (git -C $repo log --oneline '@{u}..HEAD' 2>$null | Measure-Object -Line).Lines
if ($LASTEXITCODE -eq 0 -and $unpushed -gt 0) {
    Write-Host "WARNING: $unpushed commit(s) not pushed to the upstream branch." -ForegroundColor Yellow
    Write-Host "         The release would point at a commit the remote does not have." -ForegroundColor Yellow
}

# ...and HEAD in particular is not a matter of judgement: the tag is created at
# that exact commit, so if the remote does not have it there is nothing for the
# tag to point at. Commits BEHIND head being unpushed is the caller's call; this
# one is not.
if (-not $DryRun) {
    $head = (& git -C $repo rev-parse HEAD).Trim()
    & git -C $repo fetch --quiet origin 2>$null
    & git -C $repo merge-base --is-ancestor $head '@{u}' 2>$null
    if ($LASTEXITCODE -ne 0) {
        Fail ("HEAD ($head) is not on the upstream branch. The release is tagged at that " +
              "exact commit, so push first: git push")
    }
}

# ------------------------------------------------------------------- build --

$zip = Join-Path $repo "dist\delphi-win64-debugger-setup-v$version.zip"

if ($SkipBuild) {
    if (-not (Test-Path $zip)) { Fail "-SkipBuild was given but $zip does not exist." }
    Write-Host "Reusing existing zip: $zip"
}
else {
    Write-Host "=== Building $tag ==="
    cmd /c "`"$repo\build_setup_zip.bat`""
    if ($LASTEXITCODE -ne 0) { Fail "build_setup_zip.bat failed." }
    if (-not (Test-Path $zip)) { Fail "the build did not produce $zip" }
}

# Hashed through .NET rather than Get-FileHash: that cmdlet is missing on older
# Windows PowerShell hosts, and this script must not depend on which engine the
# launcher happened to pick.
$sha256 = [System.Security.Cryptography.SHA256]::Create()
try {
    $sha = [BitConverter]::ToString($sha256.ComputeHash([IO.File]::ReadAllBytes($zip))).Replace('-', '')
}
finally {
    $sha256.Dispose()
}

# ------------------------------------------------------------------- notes --

$templatePath = Join-Path $repo 'install\RELEASE_NOTES_TEMPLATE.md'
if (-not (Test-Path $templatePath)) { Fail "notes template not found: $templatePath" }
$notes = Get-Content $templatePath -Raw

$highlightText = ''
if ($Highlights -ne '') {
    if (-not (Test-Path $Highlights)) { Fail "highlights file not found: $Highlights" }
    $highlightText = (Get-Content $Highlights -Raw).Trim()
}
else {
    Write-Host "No -Highlights file given: the release will carry no 'What's new' section." -ForegroundColor Yellow
}

# The tool count is read from the server's own schemas rather than kept in the
# template, where it silently rots. It was already wrong once.
$schemas = Get-Content (Join-Path $repo 'MCPDebugger\McpToolSchemas.pas') -Raw
$toolCount = ([regex]::Matches($schemas, '"name"\s*:\s*"[a-z_]+"') |
              ForEach-Object { $_.Value } | Sort-Object -Unique).Count
if ($toolCount -eq 0) {
    $server = Get-Content (Join-Path $repo 'MCPDebugger\McpServer.pas') -Raw
    $toolCount = ([regex]::Matches($server, "Name = '([a-z_]+)'") |
                  ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique).Count
}
if ($toolCount -eq 0) { Fail "could not count the MCP tools - check MCPDebugger\McpToolSchemas.pas" }

$notes = $notes.Replace('{{VERSION}}', $version).
                Replace('{{SHA256}}', $sha).
                Replace('{{MCP_TOOL_COUNT}}', "$toolCount").
                Replace('{{HIGHLIGHTS}}', $highlightText)

# A placeholder that survives into a published release looks like neglect.
# The character class includes digits on purpose: {{SHA256}} has one, and an
# earlier version of this pattern silently could not see the single placeholder
# most likely to matter.
$leftovers = [regex]::Matches($notes, '\{\{[A-Z0-9_]+\}\}') | ForEach-Object { $_.Value } | Sort-Object -Unique
if ($leftovers.Count -gt 0) { Fail "unresolved placeholder(s) in the notes: $($leftovers -join ', ')" }

$notesPath = Join-Path $repo "dist\release-notes-v$version.md"
Set-Content -LiteralPath $notesPath -Value $notes -Encoding UTF8 -NoNewline

Write-Host ''
Write-Host "version:  $version"
Write-Host "zip:      $zip  ($([math]::Round((Get-Item $zip).Length / 1MB, 2)) MB)"
Write-Host "sha256:   $sha"
Write-Host "mcp tools: $toolCount"
Write-Host "notes:    $notesPath"

if ($DryRun) {
    Write-Host ''
    Write-Host "DRY RUN - nothing was sent to GitHub. Review the notes above, then re-run without -DryRun."
    exit 0
}

# ----------------------------------------------------------------- release --

Write-Host ''
# GitHub creates the tag at this commitish WHEN THE DRAFT IS PUBLISHED, so a
# BRANCH NAME here means the tag lands wherever that branch happens to point at
# that moment. It pointed at `main`, which is not the branch this project
# releases from: v0.5.0, v0.6.0, v0.6.1 and v0.6.2 all tagged the same stale
# commit, and none of them describes the tree that was actually shipped.
# Pin the exact commit that was built.
$target = (& git -C $repo rev-parse HEAD).Trim()
Write-Host "=== Creating DRAFT release $tag at $target ==="
gh release create $tag --draft --target $target `
    --title "$tag - Delphi Debugger for VS Code and AI Agents" `
    --notes-file $notesPath `
    $zip
if ($LASTEXITCODE -ne 0) { Fail "gh release create failed." }

# Read the target back rather than trusting that it was stored as asked. It is
# what GitHub will turn into a tag at publish time, and it is the only thing
# standing between the tag and the payload.
$draft = gh release view $tag --json targetCommitish 2>&1 | ConvertFrom-Json
if ($LASTEXITCODE -eq 0 -and $draft.targetCommitish -ne $target) {
    Fail ("the draft records `"$($draft.targetCommitish)`" as its target, not $target. " +
          "Publishing it would tag a different tree from the one in the zip. Delete the " +
          "draft (gh release delete $tag) before anything else.")
}

Write-Host ''
Write-Host "Draft created. It is NOT visible to anyone yet." -ForegroundColor Green
Write-Host "Review it on the Releases tab, then publish with:"
Write-Host "  gh release edit $tag --draft=false"
Write-Host "and then CHECK WHERE THE TAG LANDED -- the tag is created at publish time,"
Write-Host "so this is the first moment it can be verified:"
Write-Host "  make_release.bat -Verify"
