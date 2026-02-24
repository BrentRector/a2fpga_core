#Requires -Version 5.1
<#
.SYNOPSIS
    Publish an A2N20V2 Videx firmware release to GitHub.

.DESCRIPTION
    Creates a GitHub release with the current bitstream attached.
    Requires the gh CLI to be installed and authenticated.

.PARAMETER Version
    Semantic version tag (e.g., v0.9, v1.0, v1.1-rc1).

.PARAMETER Draft
    Create as a draft release (not publicly visible until manually published).

.PARAMETER PreRelease
    Mark as a pre-release.

.EXAMPLE
    .\tools\publish-release.ps1 v0.9
    .\tools\publish-release.ps1 v1.0 -Draft
    .\tools\publish-release.ps1 v1.1-rc1 -PreRelease
#>

param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Version,

    [switch]$Draft,

    [switch]$PreRelease
)

$ErrorActionPreference = 'Stop'

$Bitstream = "boards\a2n20v2\impl\pnr\a2n20v2.fs"
$AssetName = "a2n20v2-videx-$Version.fs"
$ReleaseName = "A2N20V2-VIDEX-$Version"
$Tag = $Version

# Validate version format
if ($Version -notmatch '^v\d+\.\d+([\.\-].+)?$') {
    Write-Error "Version must match vN.N[.suffix] (e.g., v0.9, v1.0, v1.1-rc1)"
    return
}

# Validate bitstream exists
if (-not (Test-Path $Bitstream)) {
    Write-Error "Bitstream not found at $Bitstream"
    return
}

# Validate on main branch
$Branch = git branch --show-current 2>&1
if ($Branch -ne 'main') {
    Write-Error "Must be on main branch (currently on '$Branch')"
    return
}

# Validate bitstream is committed
$BitstreamDiff = git diff --quiet HEAD -- $Bitstream 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Bitstream has uncommitted changes. Commit first."
    return
}

# Check for existing release
gh release view $Tag 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Error "Release $Tag already exists"
    return
}

$Commit = git rev-parse --short HEAD
$FileSize = (Get-Item $Bitstream).Length
$FileSizeMB = [math]::Round($FileSize / 1MB, 1)

Write-Host ""
Write-Host "Publishing release:" -ForegroundColor Cyan
Write-Host "  Tag:       $Tag"
Write-Host "  Name:      $ReleaseName"
Write-Host "  Asset:     $AssetName ($FileSizeMB MB)"
Write-Host "  Commit:    $Commit ($Branch)"
if ($Draft)      { Write-Host "  Mode:      DRAFT" -ForegroundColor Yellow }
if ($PreRelease) { Write-Host "  Mode:      PRE-RELEASE" -ForegroundColor Yellow }
Write-Host ""

$Confirm = Read-Host "Proceed? [y/N]"
if ($Confirm -notin @('y', 'Y')) {
    Write-Host "Aborted."
    return
}

# Build release notes
$Body = @"
Firmware release **$Version** from commit ``$Commit``.

## A2FPGA Multicard — Videx VideoTerm Edition

Firmware for the A2N20V2 board with Videx VideoTerm 80-column card emulation
and upstream bug fixes.

### Emulated Cards

| Slot | Card | Notes |
|:---:|--------|-------|
| 2 | Super Serial Card | USB serial for ADTPro |
| 3 | **Videx VideoTerm** | 80-column display |
| 4 | Mockingboard | Stereo AY-3-8910 sound |
| 7 | SuperSprite | TMS9918a sprite graphics |

### Flashing Instructions

**Mac/Linux (OpenFPGALoader):**
``````
openfpgaloader -b tangnano20k -f $AssetName
``````

**Windows (GoWin Programmer):**
Flash the ``.fs`` file to the GW2AR-18C device in External Flash Mode
(Generic Flash, address 0x000000).

### More Information

See the [README](https://github.com/BrentRector/a2fpga_core#readme) for
slot configuration, build instructions, and complete documentation.
"@

# Copy bitstream with release name to temp directory
$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) "a2fpga-release-$Version"
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
$TempAsset = Join-Path $TempDir $AssetName
Copy-Item $Bitstream $TempAsset

try {
    # Write release notes to temp file (avoids quoting issues)
    $NotesFile = Join-Path $TempDir "notes.md"
    $Body | Out-File -FilePath $NotesFile -Encoding utf8NoBOM

    # Build gh command arguments
    $GhArgs = @(
        'release', 'create', $Tag,
        '--title', $ReleaseName,
        '--target', 'main',
        '--notes-file', $NotesFile,
        $TempAsset
    )

    if ($Draft)      { $GhArgs += '--draft' }
    if ($PreRelease) { $GhArgs += '--prerelease' }

    # Create the release
    & gh @GhArgs

    if ($LASTEXITCODE -ne 0) {
        Write-Error "gh release create failed"
        return
    }

    Write-Host ""
    Write-Host "Release $ReleaseName published successfully." -ForegroundColor Green
    Write-Host "View at: https://github.com/BrentRector/a2fpga_core/releases/tag/$Tag"
}
finally {
    Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
}
