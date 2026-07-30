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
#
# ROOT-SCOPE FILES (v4.1 / U0.5, mirrored into PowerShell by U0.7)
# ----------------------------------------------------------------
# Through v4.0 this script removed .claude\, .claude-plugin\ and .beads\ and
# left every ROOT-level file the installer had written — .mcp.json, LESSONS.md
# and .worktreeinclude — sitting in the project. An operator who uninstalled
# got a tree that looked clean and still had three plugin files in it, with no
# way to tell which of them they had written themselves.
#
# $Target\.claude\install-manifest (written by every v4.1+ install) closes
# that: it records path/class/sha256 for everything the installer put on disk,
# so a root-scope row can be hashed and judged instead of guessed at.
#
#   hash matches the manifest -> untouched since install; moves to the trash
#                                with the directories.
#   hash differs              -> the operator edited it (a ledger they wrote
#                                into, an .mcp.json holding their own servers).
#                                LEFT IN PLACE, with a note.
#   cannot be hashed          -> also left in place. We never move a file we
#                                could not verify.
#
# No manifest, a foreign header, or a body with no valid row -> the pre-v4.1
# behaviour, unchanged: the three directories move and root files stay. That is
# the only correct fallback — with no table of hashes there is no way to tell a
# stock file from an operator's, and this is a destructive operation.
#
# Keep this walk equivalent to uninstall.sh's. The two scripts are a duplicated
# implementation of one contract; packaging-parity.test.sh pins the shared rules
# textually because there is no PowerShell on the CI lane that runs the L2 specs.
#
# Root scope stopped being FLAT in v4.1 / U0.8, which added the shipped-docs
# subset (docs/CODEX_SETUP.md, docs/HOOKS.md) to the surface. Nested rows keep
# their SUBPATH inside the trash directory (see the move loop): flattening
# docs\HOOKS.md to HOOKS.md would collide with any root-level file of the same
# name and would make the printed recovery command restore it to the wrong place.
#
# CRLF TOLERANCE DIVERGES FROM uninstall.sh (v4.1 / U0.8, m7e R1-F3): this script
# reads the manifest with [IO.File]::ReadAllLines, which strips the \r of a CRLF
# line ending, so a CRLF-line-ended install-manifest is consumed normally; the
# bash script parses with awk, keeps the \r on field 3, validates no row, and
# degrades to the legacy "leave every root file" behaviour. Both directions are
# safe (bash leaves more behind than it needs to), the installers only ever write
# LF, and neither script rewrites a manifest -- so this is recorded, not fixed.
#
# CONTAINMENT (v4.1 / U0.7, claude-workflow-plugin-wn4)
# ----------------------------------------------------
# A manifest row is UNTRUSTED INPUT to a script that MOVES files, so a row has to
# be proven to name a file inside the project before it is acted on. That takes
# TWO rules, because the first one is not enough:
#
#   lexical   Get-ManifestRootRows drops rooted rows (drive-qualified, UNC or
#             leading-separator) and rows carrying a `..` segment.
#   physical  Test-RowContained walks the row's directory chain from the target
#             down, refuses any component that is a REPARSE POINT (symlink or
#             junction), and requires the resolved parent to sit inside the
#             resolved target.
#
# The second rule exists because the first is a string test, while Test-Path and
# Get-FileHash both FOLLOW reparse points: a row like `data\thing.txt`, where
# `data` is a symlink to somewhere else on the disk, is lexically spotless and
# still reaches a file outside the project (wn4 — reproduced against the bash
# script before the fix; the readout even called it "unmodified since install").
#
# The reparse-point walk is what makes this work on Windows PowerShell 5.1:
# Resolve-Path and [IO.Path]::GetFullPath both normalise a path WITHOUT
# resolving links there, so a prefix comparison on its own would wave the
# symlinked row straight through.

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
# Normalised once, without a trailing separator, so the containment comparison
# below cannot be fooled by "C:\proj" vs "C:\project2".
$TargetRoot = $Target.TrimEnd('\', '/')

Write-Host ""
Write-Color "Claude Workflow Plugin - Uninstaller" Cyan
Write-Host ""
Write-Host "Target: " -NoNewline
Write-Color $Target Cyan
Write-Host ""

# Install-manifest helpers (v4.1 / U0.5 + U0.7) --------------------------------

# Get-Sha256 <path> — bare lowercase 64-hex sha256, or "" when it cannot be
# computed (missing file, unreadable, Get-FileHash unavailable).
#
# Empty is a legitimate answer here, not an error: the caller treats an
# unverifiable file as "leave it alone". Deliberately the opposite policy from
# the manifest generator, which fails hard — there a wrong hash silently
# overwrites a customized file, here an absent hash only means one extra file is
# left on disk for the operator to delete by hand.
#
# .Hash comes back UPPERCASE from Get-FileHash and the manifest is written in
# lowercase, so the ToLowerInvariant() is load-bearing, not cosmetic.
function Get-Sha256 {
    param([string]$FilePath)
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return "" }
    try {
        return (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    } catch {
        return ""
    }
}

# Test-RowContained <relative-path> — $true when $Target\<relative-path>'s PARENT
# DIRECTORY resolves inside the target. The wn4 guard; see the CONTAINMENT block
# in the file header.
#
# The PARENT is what is checked, not the file: a candidate that is itself a
# symlink is safe to move, because Move-Item relocates the LINK and leaves the
# file it points at alone. A symlinked parent is the dangerous shape, because
# then the move operates on a real file that lives somewhere else.
function Test-RowContained {
    param([string]$Rel)

    $segments = @(($Rel -replace '\\', '/').Split('/') | Where-Object { $_ -ne "" })
    if ($segments.Count -eq 0) { return $false }

    # WN4-CONTAINMENT-START (load-bearing; the same rule lives in uninstall.sh,
    # where the L2 META-TEST at installer-manifest-parity.sh 9c deletes it and
    # watches the symlinked-parent row move an outside file again. Keep both
    # sentinels in both scripts.)
    $walk = $script:TargetRoot
    for ($i = 0; $i -lt $segments.Count - 1; $i++) {
        $walk = Join-Path $walk $segments[$i]
        if (-not (Test-Path -LiteralPath $walk)) { return $false }
        $item = Get-Item -LiteralPath $walk -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) { return $false }
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $false
        }
    }
    $resolved = ""
    try { $resolved = (Resolve-Path -LiteralPath $walk -ErrorAction Stop).Path } catch { return $false }
    $resolved = $resolved.TrimEnd('\', '/')
    if ($resolved -eq $script:TargetRoot) { return $true }
    return $resolved.StartsWith($script:TargetRoot + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase)
    # WN4-CONTAINMENT-END
}

# Get-ManifestRootRows — one "<path>`t<sha256>" string per ROOT-SCOPE row of
# $Target\.claude\install-manifest; nothing at all when the manifest is absent,
# carries a foreign header, or holds no valid row.
#
# Root scope is defined by the PATH RULE — not under .claude/ and not under
# .claude-plugin/ — rather than by a list of names, so the release that ships a
# fourth root-level file needs no edit here. Rooted paths and any path containing
# a .. segment are dropped: this feeds a move, and a manifest row that escaped
# the target would relocate a file from outside the project.
#
# The valid-row count gates the WHOLE output. A header-only or truncated
# manifest has to degrade to "we know nothing about this tree" (legacy
# behaviour), never to "this tree has no root-scope files".
function Get-ManifestRootRows {
    $manifest = Join-Path $Target ".claude\install-manifest"
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { return }

    $lines = @()
    try { $lines = [System.IO.File]::ReadAllLines($manifest) } catch { return }
    if ($lines.Count -lt 1) { return }
    if (-not $lines[0].StartsWith("# claude-workflow-plugin ")) { return }

    $valid = 0
    $rows = @()
    foreach ($line in $lines) {
        $f = $line.Split("`t")
        if ($f.Count -lt 3) { continue }
        if ($f[0] -eq "") { continue }
        if (@("workflow", "operator", "merged") -notcontains $f[1]) { continue }
        # -cnotmatch, not -notmatch: the generator writes LOWERCASE hex and PS
        # regex operators are case-INSENSITIVE by default, which would accept a
        # hand-edited uppercase hash the bash side rejects.
        if ($f[2] -cnotmatch '^[0-9a-f]{64}$') { continue }
        $valid++
        $rel = $f[0]
        $norm = $rel -replace '\\', '/'
        if ($norm.StartsWith(".claude/") -or $norm.StartsWith(".claude-plugin/")) { continue }
        if ([System.IO.Path]::IsPathRooted($rel) -or $rel.Contains(":")) { continue }
        if ($norm.StartsWith("/")) { continue }
        if ($norm -eq ".." -or $norm.StartsWith("../") -or $norm.EndsWith("/..") -or $norm.Contains("/../")) { continue }
        $rows += ($rel + "`t" + $f[2])
    }
    if ($valid -lt 1) { return }
    $rows
}

# Discover ---------------------------------------------------------------------
$ToRemove = @()
$Descriptions = @()
# Root-scope files that will NOT move, and why. Reported after the move next to
# the CLAUDE.md note, so the record of what was left behind sits with the record
# of what went.
$RootKeptModified = @()
$RootKeptUnverified = @()
# Rows REFUSED because they resolve outside the project (wn4). Kept separate from
# the two "kept" lists on purpose: those are files the operator owns, this is a
# manifest we do not trust.
$RootRefusedOutside = @()

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

# Root-scope files, from the install manifest (v4.1 / U0.5). Enumerated HERE,
# before the confirmation, so every path that will move is on screen when the
# operator answers y/n. Appended after the three directories so a tree with no
# usable manifest produces exactly the pre-v4.1 listing.
if (-not (Get-Command Get-FileHash -ErrorAction SilentlyContinue)) {
    if (Test-Path -LiteralPath (Join-Path $Target ".claude\install-manifest")) {
        Write-Color "note Get-FileHash is unavailable (needs PowerShell 4.0 or newer);" Yellow
        Write-Host "     root-level plugin files cannot be verified and will be left in place."
        Write-Host ""
    }
} else {
    foreach ($row in @(Get-ManifestRootRows)) {
        if (-not $row) { continue }
        $parts = $row.Split("`t")
        if ($parts.Count -lt 2) { continue }
        $mfPath = $parts[0]
        $mfHash = $parts[1]
        $candidate = Join-Path $Target $mfPath
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        if (-not (Test-RowContained $mfPath)) {
            $RootRefusedOutside += $mfPath
            continue
        }
        $actual = Get-Sha256 $candidate
        if (-not $actual) {
            $RootKeptUnverified += $mfPath
        } elseif ($actual -eq $mfHash) {
            $ToRemove += $candidate
            $Descriptions += "$mfPath (unmodified since install)"
        } else {
            $RootKeptModified += $mfPath
        }
    }
}

# Existing backups (will be left in place by default; user can clean later).
# All THREE prefixes are listed: .claude-backup-* from install modes 1/2, plus
# .claude-v2-backup-* and .claude-v3-backup-* from the two migration flows.
# Listing only the first made an upgraded project look like it had no backups at
# all — and the migration ones are precisely the snapshots holding the
# pre-upgrade tree.
$ExistingBackups = @(Get-ChildItem -Path $Target -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like ".claude-backup-*" -or
                   $_.Name -like ".claude-v2-backup-*" -or
                   $_.Name -like ".claude-v3-backup-*" } |
    Sort-Object Name)
# -RestoreBackup restores from a mode-1/2 .claude-backup-* ONLY, deliberately:
# a migration backup is a snapshot of a PREVIOUS MAJOR's tree, so restoring one
# after an uninstall would resurrect a v2/v3 layout under a v4 name. The listing
# above is informational; the restore source is not widened.
$RestorableBackups = @($ExistingBackups | Where-Object { $_.Name -like ".claude-backup-*" })
$LatestBackup = $RestorableBackups | Select-Object -Last 1

if ($ToRemove.Count -eq 0) {
    Write-Color "Nothing to remove. The plugin does not appear to be installed at $Target." Yellow
    exit 0
}

Write-Color "The following will be moved to a trash directory:" Yellow
foreach ($d in $Descriptions) { Write-Host "  - $d" }
Write-Host ""

if ($RootKeptModified.Count -gt 0 -or $RootKeptUnverified.Count -gt 0) {
    Write-Color "Left in place (yours, not the installer's any more):" Cyan
    foreach ($kept in $RootKeptModified) { Write-Host "  - $kept (modified since install)" }
    foreach ($kept in $RootKeptUnverified) { Write-Host "  - $kept (could not be verified)" }
    Write-Host ""
}

# Refused rows (wn4). Printed BEFORE the confirmation and in their own block: an
# operator staring at the last screen of a destructive op needs to see that a row
# was ignored — and needs it NOT to appear in the "will be moved" list above.
if ($RootRefusedOutside.Count -gt 0) {
    Write-Color "Refused (the install manifest names a path outside this project):" Yellow
    foreach ($refused in $RootRefusedOutside) {
        Write-Host "  - $refused (resolves outside the project; not touched)"
    }
    Write-Host "  The manifest has been edited or a directory in the path is a symlink."
    Write-Host ""
}

# Gated on $ExistingBackups rather than $LatestBackup: a project whose only
# backup is a v2/v3 migration snapshot still has backups to report, and it is the
# one that most needs to hear so.
if ($ExistingBackups.Count -gt 0) {
    Write-Color "Backups found (will be kept in place):" Cyan
    foreach ($b in $ExistingBackups) { Write-Host "  - $($b.FullName)" }
    if ($RestoreBackup) {
        Write-Host ""
        if ($LatestBackup) {
            Write-Color "-RestoreBackup set: after removal, will restore from $($LatestBackup.FullName)" Yellow
        } else {
            Write-Color "-RestoreBackup set, but no .claude-backup-* directory exists to restore from." Yellow
            Write-Host "  (A .claude-v2-backup-*/.claude-v3-backup-* migration snapshot is never restored"
            # ASCII hyphen, not the em dash install.sh uses here: this file carries
            # no byte-order mark, so Windows PowerShell 5.1 decodes it as the ANSI
            # code page and a UTF-8 em dash ends in byte 0x94 = U+201D, which the
            # PowerShell grammar treats as a DOUBLE-QUOTE CHARACTER. Inside this
            # string that byte would close it and the whole script would stop
            # parsing (R1-F1). No test pins this sentence to the bash one.
            Write-Host "   automatically - it holds a previous major's layout. Copy from it by hand if that"
            Write-Host "   is really what you want.)"
        }
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

# The trash MIRRORS the project layout rather than flattening into it (v4.1 /
# U0.8). Every entry in $ToRemove is "$Target\<relative-path>", and a manifest
# root row may now be NESTED (docs/HOOKS.md), so moving to $TrashDir directly
# would drop it at the trash root: it would collide with a same-named file from
# another directory, and the recovery command printed at the end would restore it
# to the project root instead of back into docs\. Stripping the target prefix and
# recreating the parent keeps the trash a faithful, restorable snapshot. The three
# directories and the flat root files are unaffected -- their relative path IS
# their leaf name.
foreach ($p in $ToRemove) {
    if (Test-Path -LiteralPath $p) {
        $rel = $p
        if ($rel.StartsWith($TargetRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rel = $rel.Substring($TargetRoot.Length).TrimStart('\', '/')
        }
        # Manifest rows are written with FORWARD slashes (the same rows are read
        # by the bash side), and Join-Path preserved them into $p, so the
        # relative path can arrive mixed-separator. Normalise before joining and
        # splitting -- the same -replace install.ps1 does wherever a plan path
        # meets the filesystem.
        $rel = $rel -replace '/', [string][System.IO.Path]::DirectorySeparatorChar
        $dest = Join-Path $TrashDir $rel
        $destParent = Split-Path $dest -Parent
        if (-not (Test-Path -LiteralPath $destParent)) {
            New-Item -ItemType Directory -Path $destParent -Force | Out-Null
        }
        Move-Item -LiteralPath $p -Destination $dest
        # The readout names the row as the MANIFEST spells it (forward slashes),
        # so it matches the pre-confirmation listing above line for line.
        Write-Color ("OK moved {0} -> {1}\" -f ($rel -replace '\\', '/'), $TrashDir) Green
    }
}

# Root-scope files the operator changed since install, or that could not be
# hashed: never moved. The note is the record — an operator reading only the tail
# of this output has to be able to see that something was deliberately left
# behind, and which.
foreach ($kept in $RootKeptModified) {
    Write-Color "note $kept left in place (modified since install; remove manually if you want)" Cyan
}
foreach ($kept in $RootKeptUnverified) {
    Write-Color "note $kept left in place (could not verify it against the install manifest)" Cyan
}
foreach ($refused in $RootRefusedOutside) {
    Write-Color "note $refused (resolves outside the project; refused, nothing was moved for that row)" Yellow
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
# -Force on Get-ChildItem so the hidden children (.claude\, .claude-plugin\,
# .beads\, .mcp.json) are enumerated, and Copy-Item -Recurse so the nested docs\
# subset lands back where it came from. `Move-Item "$TrashDir\*"` did neither.
Write-Host "  -> Recover everything: Get-ChildItem -Force ""$TrashDir"" | Copy-Item -Destination ""$Target"" -Recurse -Force"
Write-Host "  -> Permanently delete with: Remove-Item -Recurse -Force ""$TrashDir"""
Write-Host ""
