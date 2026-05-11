# Claude Workflow Plugin - Uninstaller (Windows / PowerShell)
#
# Uninstall is the rare destructive op where we ask one yes/no confirmation.
# Files are MOVED to a trash directory rather than removed, so the user can
# recover if they change their mind.
#
# Usage:
#   .\uninstall.ps1
#   .\uninstall.ps1 -Path "C:\Projects\myproject"
#   .\uninstall.ps1 -RestoreBackup

param(
    [string]$Path = ".",
    [switch]$RestoreBackup
)

$ErrorActionPreference = "Stop"

function Write-Color {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
}

if (-not (Test-Path $Path)) {
    Write-Color "Target directory does not exist: $Path" Red
    exit 1
}
$Target = (Resolve-Path $Path).Path

Write-Host ""
Write-Color "Claude Workflow Plugin - Uninstaller" Cyan
Write-Host ""
Write-Host "Target: " -NoNewline
Write-Color $Target Cyan
Write-Host ""

# Discover ---------------------------------------------------------------------
$ToRemove = @()
$Descriptions = @()

$ClaudeDir = Join-Path $Target ".claude"
if (Test-Path $ClaudeDir) {
    $ToRemove += $ClaudeDir
    $AgentCount = (Get-ChildItem "$ClaudeDir\agents\*.md" -ErrorAction SilentlyContinue | Measure-Object).Count
    $ScriptCount = (Get-ChildItem "$ClaudeDir\scripts\*.sh" -ErrorAction SilentlyContinue | Measure-Object).Count
    $Descriptions += ".claude\ ($AgentCount agents, $ScriptCount scripts, settings.json, hooks, etc.)"
}

$PluginDir = Join-Path $Target ".claude-plugin"
if (Test-Path $PluginDir) {
    $ToRemove += $PluginDir
    $Descriptions += ".claude-plugin\ (plugin.json manifest)"
}

$BeadsDir = Join-Path $Target ".beads"
if (Test-Path $BeadsDir) {
    $ToRemove += $BeadsDir
    $Descriptions += ".beads\ (Beads task database -- contains all your tracked tasks)"
}

$ExistingBackups = Get-ChildItem -Path $Target -Filter ".claude-backup-*" -Directory -ErrorAction SilentlyContinue | Sort-Object Name
$LatestBackup = $ExistingBackups | Select-Object -Last 1

if ($ToRemove.Count -eq 0) {
    Write-Color "Nothing to remove. The plugin does not appear to be installed at $Target." Yellow
    exit 0
}

Write-Color "The following will be moved to a trash directory:" Yellow
foreach ($d in $Descriptions) { Write-Host "  - $d" }
Write-Host ""

if ($ExistingBackups -and $ExistingBackups.Count -gt 0) {
    Write-Color "Backups found (will be kept in place):" Cyan
    foreach ($b in $ExistingBackups) { Write-Host "  - $($b.FullName)" }
    if ($RestoreBackup) {
        Write-Host ""
        Write-Color "-RestoreBackup set: after removal, will restore from $($LatestBackup.FullName)" Yellow
    }
    Write-Host ""
}

# Confirmation -----------------------------------------------------------------
$Reply = Read-Host "Proceed with uninstall? (y/n)"
if ($Reply -notmatch '^[Yy]') {
    Write-Host "Cancelled."
    exit 0
}

# Move to trash ----------------------------------------------------------------
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$TrashDir = Join-Path $Target ".claude-uninstall-trash-$Stamp"
New-Item -ItemType Directory -Path $TrashDir -Force | Out-Null

foreach ($p in $ToRemove) {
    if (Test-Path $p) {
        Move-Item -Path $p -Destination $TrashDir
        Write-Color ("OK moved {0} -> {1}\" -f (Split-Path $p -Leaf), $TrashDir) Green
    }
}

# CLAUDE.md handling
$ClaudeMd = Join-Path $Target "CLAUDE.md"
if (Test-Path $ClaudeMd) {
    $content = Get-Content $ClaudeMd -Raw -ErrorAction SilentlyContinue
    $lineCount = (Get-Content $ClaudeMd -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
    if ($content -match [regex]::Escape("<!-- Describe your project: what it does, who it's for -->") -and $lineCount -lt 60) {
        Move-Item -Path $ClaudeMd -Destination $TrashDir
        Write-Color "OK moved CLAUDE.md (unmodified template) -> $TrashDir\" Green
    } else {
        Write-Color "note CLAUDE.md left in place (looks customized; remove manually if you want)" Cyan
    }
}

# Optional restore -------------------------------------------------------------
if ($RestoreBackup -and $LatestBackup) {
    Write-Host ""
    Write-Color "Restoring from $($LatestBackup.FullName)..." Yellow
    Get-ChildItem -Path $LatestBackup.FullName -Force | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $Target -Recurse -Force
    }
    Write-Color "OK restored configuration from backup" Green
    Write-Host "  (Note: .beads database was not in the backup; run 'bd init' to recreate.)"
}

Write-Host ""
Write-Color "Uninstall complete." Green
Write-Host ""
Write-Host "Trash:  " -NoNewline
Write-Color $TrashDir Cyan
Write-Host "  -> Recover with: Move-Item ""$TrashDir\*"" ""$Target\"" -Force"
Write-Host "  -> Permanently delete with: Remove-Item -Recurse -Force ""$TrashDir"""
Write-Host ""
