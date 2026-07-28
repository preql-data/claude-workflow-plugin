# Claude Workflow Plugin - Windows installer (PowerShell)
#
# NO RELEASE NUMBER IS WRITTEN IN THIS FILE (v4.1 / U0.8). The banner and the
# fresh-install readout interpolate the version read from the SOURCE
# .claude-plugin/plugin.json, so a release bump needs no installer edit and
# cannot leave a stale "v3" on an operator's screen.
#
# Single-source-of-truth: this script copies the canonical agent/script/hook
# definitions from the repo (alongside this file, or freshly cloned to a temp
# dir if piped from `irm | iex`). It does NOT embed the agent prompts.
#
# This plugin REQUIRES Beads (bd) for task tracking.
# Install Beads first:
#   irm https://raw.githubusercontent.com/steveyegge/beads/main/install.ps1 | iex
#
# Usage:
#   .\install.ps1                                       # uses current dir
#   .\install.ps1 -Path "C:\Projects\myproject"
#   .\install.ps1 -Upgrade                              # force the migration flow
#   irm https://.../install.ps1 | iex                   # auto-clones repo
#
# Upgrades (v4.1 / U0.7 — the PowerShell mirror of install.sh's machinery):
#   v2 -> v3   detected and REDIRECTED to install.sh. That migration is not
#              implemented here; see the redirect block below for why.
#   v3 -> v4   an installed .claude-plugin\plugin.json declaring 3.x. Backs the
#              tree up, classifies every shipped file by hash against the release
#              the target was installed from, replaces plugin-owned files,
#              preserves operator-owned edits (shipped copy written alongside as
#              <file>.new), and merges settings.json / .mcp.json key-wise instead
#              of clobbering them.
# -Upgrade forces whichever migration the target's signals point at; it may not
# be combined with -Mode.
#
# Re-runs: a target this installer has already written carries
# .claude\install-manifest, which records the release and the per-file hashes it
# installed. Mode 2 (Update) uses it as the classify old-table, so a second run
# gets the SAME per-file treatment as an upgrade — operator edits preserved with a
# .new alongside instead of overwritten — and skips its backup entirely when the
# tree is already at this release with nothing to write.
#
# WINDOWS EXECUTION IS A DOCUMENTED CAVEAT, NOT A SILENT CLAIM. The parity this
# file's assertions can prove is TEXTUAL (packaging-parity.test.sh, L1); the L2
# specs execute the bash installer only, and .github/workflows/windows-install.yml
# is dispatch-only. Treat every behaviour below as verified-by-inspection against
# install.sh until that workflow has run.

param(
    [string]$Path = ".",
    [string]$RepoUrl = $env:CLAUDE_WORKFLOW_REPO,
    [string]$RepoBranch = $env:CLAUDE_WORKFLOW_BRANCH,
    # Explicit mode override for non-interactive runs (irm | iex). Valid
    # values: "1" (backup+fresh), "2" (update), "3" (merge). Empty means
    # prompt interactively or default to Update under irm-pipe.
    [ValidateSet("", "1", "2", "3")]
    [string]$Mode = "",
    # Force the migration flow even when auto-detection is fuzzy. WHICH
    # migration is still a detection question — see the ladder below. Mirrors
    # install.sh's --upgrade, and like it cannot be combined with -Mode.
    [switch]$Upgrade
)

$ErrorActionPreference = "Stop"

if (-not $RepoUrl)    { $RepoUrl = "https://github.com/preql-data/claude-workflow-plugin.git" }
if (-not $RepoBranch) { $RepoBranch = "main" }

$MinBdVersion = [Version]"0.47"

function Write-Color {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
}

# Branding, version-dynamic (v4.1 / U0.8) -------------------------------------
# The banner prints before the source has been located, so the version comes
# from the clone this script is sitting in. $PSScriptRoot is empty under
# `irm | iex` (there is no file), in which case the label degrades to the
# unnumbered product name; the authoritative number for that run is
# $SourceVersionLabel, read once the source has been fetched.
#
# ConvertFrom-Json rather than a regex: it ships with PowerShell, so unlike the
# bash side there is no "the JSON parser may not be installed yet" problem.
$ScriptDir = $PSScriptRoot
$BrandVersion = ""
if ($ScriptDir) {
    $brandManifest = Join-Path $ScriptDir ".claude-plugin/plugin.json"
    if (Test-Path -LiteralPath $brandManifest) {
        try {
            $BrandVersion = (Get-Content -Raw -LiteralPath $brandManifest |
                ConvertFrom-Json).version
        } catch {
            $BrandVersion = ""
        }
    }
}
$BrandName = "Claude Workflow Plugin"
$BrandLabel = if ($BrandVersion) { "$BrandName v$BrandVersion" } else { $BrandName }

# -Upgrade and -Mode are mutually exclusive (v4.1 / U0.7) ---------------------
# They answer the same question with different mechanisms, and silently letting
# one win would make the destructive choice unpredictable: -Upgrade owns the
# whole decision (timestamped backup, per-file hash classification,
# verdict-driven writes) while -Mode picks one of the three flat existing-install
# behaviours. Refuse rather than guess — the same contract install.sh's L1 spec
# pins for --upgrade / --mode.
#
# Order-insensitive by construction: PowerShell binds parameters by NAME, so
# `-Upgrade -Mode 2` and `-Mode 2 -Upgrade` reach this test identically.
#
# Placed BEFORE the target directory is created and before any prerequisite is
# probed, so a wrong invocation is reported as a wrong invocation even on a
# machine with no git / jq / bd installed.
if ($Upgrade -and $Mode) {
    Write-Color "-Upgrade and -Mode $Mode cannot be combined." Red
    Write-Host "  -Upgrade runs a migration flow that decides per file (backup,"
    Write-Host "  classify, replace / preserve / merge)."
    Write-Host "  -Mode picks one flat behaviour for an existing .claude/."
    Write-Host "Pass exactly one of them."
    exit 1
}

# Resolve target path ---------------------------------------------------------
if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
$Target = (Resolve-Path $Path).Path

Write-Host ""
Write-Color $BrandLabel Cyan
Write-Color "Orchestrator-first workflow with mandatory QA gate" Cyan
Write-Host ""
Write-Host "Installing to: " -NoNewline
Write-Color $Target Green
Write-Host ""

# Prerequisites ---------------------------------------------------------------
Write-Color "Checking prerequisites..." Yellow

if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Color "OK git installed" Green
} else {
    Write-Color "git not found - REQUIRED" Red
    Write-Host "  Install from: https://git-scm.com/download/win"
    exit 1
}

if (Get-Command jq -ErrorAction SilentlyContinue) {
    Write-Color "OK jq installed" Green
} else {
    Write-Color "jq not found - REQUIRED" Red
    Write-Host "  Install: winget install jqlang.jq"
    exit 1
}

if (-not (Get-Command bd -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Color "Beads (bd) not found - REQUIRED" Red
    Write-Host ""
    Write-Color "Install Beads:" Cyan
    Write-Host "  # PowerShell"
    Write-Host "  irm https://raw.githubusercontent.com/steveyegge/beads/main/install.ps1 | iex"
    Write-Host ""
    Write-Host "After installing, run this installer again."
    exit 1
}

$BdVersionRaw = (bd --version 2>$null | Select-Object -First 1)
$BdVersionMatch = [regex]::Match("$BdVersionRaw", '(\d+)\.(\d+)(?:\.(\d+))?')
$BdVersionNum = $null
if ($BdVersionMatch.Success) {
    $major = $BdVersionMatch.Groups[1].Value
    $minor = $BdVersionMatch.Groups[2].Value
    $patch = if ($BdVersionMatch.Groups[3].Success) { $BdVersionMatch.Groups[3].Value } else { "0" }
    $BdVersionNum = [Version]"$major.$minor.$patch"
}
Write-Color "OK Beads installed ($BdVersionRaw)" Green

# D6: enforce minimum bd version at install time
if ($BdVersionNum -and $BdVersionNum -lt $MinBdVersion) {
    Write-Host ""
    Write-Color "Beads version $BdVersionNum is older than the required minimum $MinBdVersion." Red
    Write-Host "Upgrade Beads, then rerun this installer:"
    Write-Host "  irm https://raw.githubusercontent.com/steveyegge/beads/main/install.ps1 | iex"
    exit 1
}

Write-Host ""

# Locate source-of-truth files ------------------------------------------------
$ScriptDir = $null
if ($PSCommandPath) {
    $ScriptDir = Split-Path -Parent $PSCommandPath
} elseif ($MyInvocation.MyCommand.Definition) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
}

$SourceDir = $null
$TmpClone = $null

function Cleanup-Clone {
    if ($script:TmpClone -and (Test-Path $script:TmpClone)) {
        Remove-Item -Recurse -Force $script:TmpClone -ErrorAction SilentlyContinue
    }
}

try {
    if ($ScriptDir -and `
        (Test-Path (Join-Path $ScriptDir ".claude/agents")) -and `
        (Test-Path (Join-Path $ScriptDir ".claude-plugin/plugin.json"))) {
        $SourceDir = $ScriptDir
        Write-Color "OK Using local plugin source: $SourceDir" Green
    } else {
        Write-Color "Fetching plugin source from $RepoUrl ($RepoBranch)..." Yellow
        $TmpClone = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "claude-workflow-$(Get-Random)")
        New-Item -ItemType Directory -Path $TmpClone -Force | Out-Null
        try {
            git clone --depth 1 --branch $RepoBranch $RepoUrl $TmpClone 2>$null
        } catch {
            Remove-Item -Recurse -Force $TmpClone -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $TmpClone -Force | Out-Null
            git clone --depth 1 $RepoUrl $TmpClone
        }
        $SourceDir = $TmpClone
        Write-Color "OK Plugin source ready" Green
    }

    # Sanity-check
    # Critical-path scripts are explicitly required; the rest of
    # .claude/scripts/*.sh rides the glob copy below so the installer stays in
    # sync as helpers are added. review-check.sh and impact-report.sh are
    # listed because both gate ends fail CLOSED without them (v4 V3 / G2.n6d):
    # a partial install missing either leaves approve refusing and the Stop
    # hook blocking with no in-loop way to diagnose it.
    #
    # workflow-doctor.sh (v4.1 / C0a) is the only functional verification
    # surface; without it a target cannot answer "does this orchestrate?".
    # Both .claude/mcp/*/package-lock.json files are required because the
    # target's dependency install is `npm ci`, which REFUSES without a
    # lockfile — a truncated clone would otherwise yield a target whose MCP
    # servers can never be installed. Kept in sync with install.sh's list.
    $Required = @(
        ".claude/agents/orchestrator.md",
        ".claude/agents/qa.md",
        ".claude/agents/backend.md",
        ".claude/agents/frontend.md",
        ".claude/agents/devops.md",
        ".claude/scripts/session-start.sh",
        ".claude/scripts/intent-router.sh",
        ".claude/scripts/post-edit.sh",
        ".claude/scripts/verify-before-stop.sh",
        ".claude/scripts/session-end.sh",
        ".claude/scripts/qa-gate.sh",
        ".claude/scripts/review-check.sh",
        ".claude/scripts/impact-report.sh",
        ".claude/scripts/current-task.sh",
        ".claude/scripts/prevent-orchestrator-edits.sh",
        ".claude/scripts/workflow-doctor.sh",
        ".claude/mcp/bd-mcp/package-lock.json",
        ".claude/mcp/code-graph-mcp/package-lock.json",
        ".claude/hooks/hooks.json",
        ".claude/skills/workflow-engine/SKILL.md",
        ".claude/settings.json",
        ".claude-plugin/plugin.json",
        ".claude/commands/workflow-model.md",
        "docs/CODEX_SETUP.md",
        "docs/HOOKS.md"
    )
    foreach ($r in $Required) {
        if (-not (Test-Path (Join-Path $SourceDir $r))) {
            Write-Color "Plugin source missing: $r" Red
            Write-Host "(Looked in $SourceDir.) Aborting."
            exit 1
        }
    }

    # =====================================================================
    # Surface manifest + upgrade machinery (v4.1 / U0.7)
    # =====================================================================
    # install.sh shells out to .claude/scripts/workflow-manifest.sh for the
    # shipped-surface enumeration and the hash-based customization verdicts.
    # This file reimplements both NATIVELY instead of invoking that script,
    # because the one thing a Windows host cannot be assumed to have is a shell
    # that runs it: bash arrives with Git for Windows, but the plugin's own
    # installer must not depend on the thing it is installing support for.
    #
    # THE TWO OUTPUTS ARE BYTE-COMPATIBLE WITH THE BASH ONES, and that is a hard
    # requirement rather than tidiness. Three artifacts are shared across the two
    # implementations:
    #
    #   manifests\v<release>.sha256   frozen per-release table, READ by both.
    #   .claude\install-manifest      written by whichever installer ran, read by
    #                                 the other one on the next upgrade AND by
    #                                 uninstall.sh / uninstall.ps1.
    #   the L2/L3 parity specs        regenerate the manifest with the bash
    #                                 generator and diff it against the body.
    #
    # So: rows are "<path><TAB><class><TAB><sha256>", paths are relative with
    # FORWARD slashes, hashes are bare lowercase 64-hex, the sort is ORDINAL
    # (= LC_ALL=C), and there is no header, no timestamp and no hostname
    # anywhere in the body.
    #
    # The surface rules below mirror workflow-manifest.sh's generate_rows
    # one-for-one, which in turn mirrors the copy loops further down this file.
    # When a copy loop changes, all three change in the same commit.

    # Get-FileSha256 <path> — bare lowercase 64-hex sha256. THROWS on failure:
    # a manifest row with a plausible-but-wrong hash would make a customized file
    # look stock and get it silently overwritten on upgrade, so the whole
    # generate call has to fail rather than emit a placeholder. Callers catch and
    # degrade with a note (the fresh-install path) or refuse (the upgrade path).
    #
    # Get-FileHash returns UPPERCASE hex; the manifest is lowercase, and every
    # comparison in both implementations is a string equality. The
    # ToLowerInvariant() is therefore load-bearing.
    function Get-FileSha256 {
        param([string]$FilePath)
        $h = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256 -ErrorAction Stop).Hash
        if (-not $h -or $h.Length -ne 64) {
            throw "sha256 of $FilePath was not 64 chars (got '$h')"
        }
        return $h.ToLowerInvariant()
    }

    # Get-SurfaceFileRow — one row for a single file, or NOTHING when it is
    # absent. Absent is not an error: a v3.5 tree has no .claude/model-roles, and
    # that is the whole reason a table is frozen per release.
    function Get-SurfaceFileRow {
        param([string]$Root, [string]$Class, [string]$Rel)
        $full = Join-Path $Root $Rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return }
        "$Rel`t$Class`t$(Get-FileSha256 $full)"
    }

    # Get-SurfaceFlatRows — ONE directory level only, mirroring the generator's
    # `find -maxdepth 1`. That depth is what keeps .claude/scripts/tests/ (the
    # plugin's own repo-only L1 suite) out of the .claude/scripts/*.sh surface.
    #
    # The -like re-filter is deliberate: the FileSystem provider's -Filter is
    # evaluated by Windows itself and can match a file's 8.3 short name as well
    # as its real one, so `*.sh` could pull in a name the bash side never sees.
    function Get-SurfaceFlatRows {
        param([string]$Root, [string]$Class, [string]$Dir, [string]$Glob)
        $full = Join-Path $Root $Dir
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { return }
        Get-ChildItem -LiteralPath $full -Filter $Glob -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like $Glob } |
            ForEach-Object { Get-SurfaceFileRow -Root $Root -Class $Class -Rel "$Dir/$($_.Name)" }
    }

    # Get-SurfaceTreeRows — recursive scan of a wholesale-copied tree, PRUNING the
    # named directories at any depth and always dropping *.log. Mirrors the
    # generator's -prune rules, which mirror install.sh's rsync --exclude sets.
    #
    # An explicit stack walk rather than Get-ChildItem -Recurse: pruning matters,
    # filtering does not. .claude/mcp/*/node_modules holds thousands of files when
    # an operator has run npm install, and -Recurse would enumerate (and this
    # function would hash) every one of them before the filter dropped it.
    #
    # Reparse points are skipped rather than descended: a symlinked directory
    # inside the source tree would otherwise be walked as if it were content, and
    # a link back up the tree would not terminate.
    function Get-SurfaceTreeRows {
        param([string]$Root, [string]$Class, [string]$Dir, [string[]]$Prune)
        if (-not (Test-Path -LiteralPath (Join-Path $Root $Dir) -PathType Container)) { return }
        $stack = New-Object System.Collections.Stack
        $stack.Push($Dir)
        while ($stack.Count -gt 0) {
            $relDir = $stack.Pop()
            Get-ChildItem -LiteralPath (Join-Path $Root $relDir) -Force -ErrorAction SilentlyContinue |
                ForEach-Object {
                    if (($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return }
                    if ($_.PSIsContainer) {
                        if ($Prune -notcontains $_.Name) { $stack.Push("$relDir/$($_.Name)") }
                    } elseif ($_.Name -notlike '*.log') {
                        Get-SurfaceFileRow -Root $Root -Class $Class -Rel "$relDir/$($_.Name)"
                    }
                }
        }
    }

    # Get-WorkflowSurfaceRows <root> — THE SURFACE, sorted. Mirrors
    # workflow-manifest.sh's generate_rows exactly; keep the two in sync in the
    # same commit.
    #
    # DELIBERATELY EXCLUDED (same list as the generator): CLAUDE.md (never-touched
    # operator memory, seeded from a template and never upgraded),
    # .claude/scripts/tests/ (repo-only), all of docs/ EXCEPT the two files named
    # below (docs/ in an install target is the operator's directory; the plugin
    # borrows exactly two filenames in it, so they are named individually and
    # never scanned), and every per-machine artifact.
    function Get-WorkflowSurfaceRows {
        param([string]$Root)
        $rows = @(
            # --- workflow: plugin-owned product ---------------------------
            Get-SurfaceFlatRows -Root $Root -Class "workflow" -Dir ".claude/agents"   -Glob "*.md"
            Get-SurfaceFlatRows -Root $Root -Class "workflow" -Dir ".claude/scripts"  -Glob "*.sh"
            Get-SurfaceFlatRows -Root $Root -Class "workflow" -Dir ".claude/commands" -Glob "*.md"
            Get-SurfaceFileRow  -Root $Root -Class "workflow" -Rel ".claude/hooks/hooks.json"
            Get-SurfaceFileRow  -Root $Root -Class "workflow" -Rel ".claude/skills/workflow-engine/SKILL.md"
            Get-SurfaceTreeRows -Root $Root -Class "workflow" -Dir ".claude/mcp" -Prune @("node_modules", ".tmp")
            Get-SurfaceTreeRows -Root $Root -Class "workflow" -Dir ".claude/tests/mutation" -Prune @("runs")
            Get-SurfaceFileRow  -Root $Root -Class "workflow" -Rel ".worktreeinclude"
            Get-SurfaceFileRow  -Root $Root -Class "workflow" -Rel ".claude-plugin/plugin.json"
            # The shipped-docs subset (v4.1 / U0.8). Class workflow: plugin-owned
            # reference material a release rewrites, so an operator edit is
            # reported and replaced with their copy in the backup, exactly like
            # any other plugin-owned file. Absent files are omitted, which is how
            # a pre-U0.8 tag still freezes.
            Get-SurfaceFileRow  -Root $Root -Class "workflow" -Rel "docs/CODEX_SETUP.md"
            Get-SurfaceFileRow  -Root $Root -Class "workflow" -Rel "docs/HOOKS.md"
            # --- operator: seeded once, never clobbered -------------------
            Get-SurfaceFlatRows -Root $Root -Class "operator" -Dir ".claude/rubrics" -Glob "*.md"
            Get-SurfaceFileRow  -Root $Root -Class "operator" -Rel ".claude/rubric-config"
            Get-SurfaceFileRow  -Root $Root -Class "operator" -Rel ".claude/review-config"
            Get-SurfaceFileRow  -Root $Root -Class "operator" -Rel ".claude/model-ranking"
            Get-SurfaceFileRow  -Root $Root -Class "operator" -Rel ".claude/model-roles"
            Get-SurfaceFileRow  -Root $Root -Class "operator" -Rel ".claude/effort-verdict"
            Get-SurfaceFileRow  -Root $Root -Class "operator" -Rel "LESSONS.md"
            # --- merged: jq key-wise merge, never a copy ------------------
            Get-SurfaceFileRow  -Root $Root -Class "merged" -Rel ".claude/settings.json"
            Get-SurfaceFileRow  -Root $Root -Class "merged" -Rel ".mcp.json"
        ) | Where-Object { $_ }
        # ORDINAL sort, which is what LC_ALL=C sort does on the bash side. Every
        # shipped path is ASCII, so ordinal on UTF-16 code units and bytewise on
        # UTF-8 are the same order — and a culture-aware Sort-Object would NOT be
        # (it ignores punctuation weight, so `.claude-plugin/...` and
        # `.claude/...` could come back swapped and the body would stop
        # byte-equalling the bash generator's).
        $sorted = [string[]]$rows
        if ($sorted.Count -gt 1) { [Array]::Sort($sorted, [System.StringComparer]::Ordinal) }
        return $sorted
    }

    # Write-LfFile — the ONLY writer used for manifest and merged-JSON output.
    #
    # LF-ONLY, UTF-8 WITHOUT BOM, and both halves are load-bearing:
    #   * install.sh reads the manifest body with `awk -F'\t'` and requires
    #     length($3) == 64. A CRLF body leaves \r on the end of every hash, NO row
    #     validates, and install_manifest_old_table degrades a later mode-2 Update
    #     to the pre-v4.1 plain-copy path — which silently re-clobbers operator
    #     edits. The failure is invisible: the Update still succeeds.
    #   * a BOM breaks the header check ("# claude-workflow-plugin ...") the same
    #     way, and older jq rejects BOM'd JSON outright.
    # Out-File / Set-Content / > would write the host's newline (CRLF on Windows)
    # and, under Windows PowerShell 5.1, -Encoding UTF8 means UTF-8 WITH BOM.
    # Neither is usable here; do not "simplify" this back.
    function Write-LfFile {
        param([string]$FilePath, [string[]]$Lines)
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($FilePath, (($Lines -join "`n") + "`n"), $utf8NoBom)
    }

    # --- source manifest, generated ONCE per run --------------------------
    $script:SourceManifestRows = @()
    $script:SourceManifestTried = $false

    # Get-SourceManifestRows — the source surface, generated at most once. Callers
    # test the COUNT: an empty result is a normal outcome (an unreadable file, no
    # hash provider), not an error, and they degrade with a note rather than
    # aborting an otherwise-good install.
    #
    # The failure arm yields @() and NOT $null on purpose: `@($null)` is an array
    # of length ONE in PowerShell, so a $null return would make every
    # `.Count -ge 1` guard downstream read as "we have a row" and write a manifest
    # with one blank line in it.
    function Get-SourceManifestRows {
        if (-not $script:SourceManifestTried) {
            $script:SourceManifestTried = $true
            try {
                $script:SourceManifestRows = @(Get-WorkflowSurfaceRows -Root $script:SourceDir)
            } catch {
                Write-Color "note the shipped surface could not be hashed: $($_.Exception.Message)" Yellow
                $script:SourceManifestRows = @()
            }
        }
        return $script:SourceManifestRows
    }

    # Read-HashTable <path> — path -> sha256 for a 3-column TSV (a frozen release
    # table, or an install-manifest body). Rows with fewer than three fields or an
    # empty path are skipped, exactly like the bash join's BEGIN block.
    #
    # An EMPTY result is legitimate and must degrade to "nothing is known to be
    # stock", never to "nothing to do": with no entries, no file can earn
    # replace-stock, so customized-looking files are preserved or reported rather
    # than silently overwritten. That is the same rule the bash side documents
    # around its deliberate avoidance of the NR == FNR idiom.
    function Read-HashTable {
        param([string]$TablePath)
        $table = @{}
        if (-not (Test-Path -LiteralPath $TablePath -PathType Leaf)) { return $table }
        foreach ($line in [System.IO.File]::ReadAllLines($TablePath)) {
            if (-not $line) { continue }
            $f = $line.Split("`t")
            if ($f.Count -ge 3 -and $f[0] -ne "") { $table[$f[0]] = $f[2] }
        }
        return $table
    }

    # --- the classify plan and the state the verdict walk consumes --------
    $script:VerdictMode = $false
    $script:Plan = @()
    $script:PlanOldTableLabel = ""
    $script:InstalledManifestVersion = ""
    $script:InstalledManifestTable = $null
    $script:PreservedFiles = @()
    $script:ReplacedFiles = @()
    # What actually happened to each merged-class file, set by the two
    # Update-mode jq merges below. The upgrade report renders one line per file
    # from these rather than looking for a leftover .bak, which a previous run
    # could also have left behind.
    #
    # FOUR states, not a boolean (v4.1 / U0.8, R1-F2; mirrors install.sh's
    # SETTINGS_MERGE_STATUS / MCP_MERGE_STATUS). Through v4.0 the report said
    # "installed as shipped; nothing to merge" whenever the flag was false --
    # true when the target had no such file, false-and-misleading when the merge
    # was ATTEMPTED AND FAILED. The console shows that failure in red as it
    # happens; the report saved into the backup is what an operator reads days
    # later, and it was claiming the shipped file had been installed when in
    # fact their own file was still sitting there unmerged (settings.json) or
    # had been replaced wholesale (.mcp.json).
    #
    #   shipped           no such file in the target; the shipped one was copied.
    #   merged            merge succeeded; the pre-merge copy is at <file>.bak.
    #   failed-untouched  merge attempted and failed; the operator's file is
    #                     UNCHANGED on disk.
    #   failed-replaced   merge refused (target was not a single JSON object);
    #                     the SHIPPED file was installed over it and the
    #                     operator's is at <file>.bak.
    $script:SettingsMergeStatus = "shipped"
    $script:McpMergeStatus = "shipped"

    # Get-InstalledManifestOldTable — $true when $Target\.claude\install-manifest
    # is one of ours AND usable as a classify old-table. On success sets
    # $script:InstalledManifestTable (path -> hash) and
    # $script:InstalledManifestVersion (the release its header names).
    #
    # Every failure arm is a legitimate tree, not an error: no manifest at all
    # (every pre-v4.1 install), a foreign header, or a body with no valid row. The
    # row check matters — a header-only or truncated file would otherwise classify
    # every shipped file as "not in the old table" and turn a routine Update into a
    # wall of .new litter.
    function Get-InstalledManifestOldTable {
        $manifest = Join-Path $script:Target ".claude\install-manifest"
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { return $false }
        $lines = @()
        try { $lines = [System.IO.File]::ReadAllLines($manifest) } catch { return $false }
        if ($lines.Count -lt 1) { return $false }
        if (-not $lines[0].StartsWith("# claude-workflow-plugin ")) { return $false }

        $table = @{}
        $valid = 0
        foreach ($line in $lines) {
            $f = $line.Split("`t")
            if ($f.Count -lt 3 -or $f[0] -eq "") { continue }
            if (@("workflow", "operator", "merged") -notcontains $f[1]) { continue }
            # -cnotmatch, not -notmatch: the generator writes LOWERCASE hex and PS
            # regex operators are case-INSENSITIVE by default, which would accept
            # a hand-edited uppercase hash the bash side rejects.
            if ($f[2] -cnotmatch '^[0-9a-f]{64}$') { continue }
            $valid++
            $table[$f[0]] = $f[2]
        }
        if ($valid -lt 1) { return $false }
        $script:InstalledManifestTable = $table
        $script:InstalledManifestVersion = $lines[0].Substring("# claude-workflow-plugin ".Length)
        return $true
    }

    # Get-ClassifyPlan — "<path><TAB><class><TAB><verdict>" per SOURCE row, using
    # <OldTable> to tell stock files from customized ones. Mirrors
    # workflow-manifest.sh's classify, verdict for verdict and in the same
    # decision order:
    #
    #   merge           class is `merged` — always; the installer reconciles those
    #                   with jq and never copies them.
    #   copy-new        the path does not exist in the target at all.
    #   skip-current    target hash == source hash; already up to date.
    #   replace-stock   target hash == the old release's hash; untouched stock.
    #   replace-custom  differs from both, class `workflow` — product wins.
    #   preserve-custom differs from both, class `operator` — the operator wins
    #                   (the caller writes .new alongside and reports it).
    #
    # Throws on a row-count mismatch. That structural self-check is the guard
    # that turns a future regression into a loud failure instead of a silently
    # truncated upgrade plan — the same reason the bash side counts its join.
    function Get-ClassifyPlan {
        param([string[]]$SourceRows, [hashtable]$OldTable, [string]$TargetRoot)
        $plan = @()
        foreach ($row in $SourceRows) {
            $f = $row.Split("`t")
            if ($f.Count -lt 3) { continue }
            $path = $f[0]; $class = $f[1]; $srcHash = $f[2]
            if ($class -eq "merged") { $plan += "$path`t$class`tmerge"; continue }
            $tgt = Join-Path $TargetRoot ($path -replace '/', [string][System.IO.Path]::DirectorySeparatorChar)
            if (-not (Test-Path -LiteralPath $tgt -PathType Leaf)) {
                $plan += "$path`t$class`tcopy-new"
                continue
            }
            $tgtHash = Get-FileSha256 $tgt
            if ($tgtHash -eq $srcHash) {
                $verdict = "skip-current"
            } elseif ($OldTable.ContainsKey($path) -and $tgtHash -eq $OldTable[$path]) {
                $verdict = "replace-stock"
            } else {
                # Differs from the shipped version AND from the release the target
                # was installed from (or the path is not in the old table at all):
                # the operator changed it, or it arrived from an unknown release.
                $verdict = "replace-custom"
                if ($class -eq "operator") { $verdict = "preserve-custom" }
            }
            $plan += "$path`t$class`t$verdict"
        }
        if ($plan.Count -ne $SourceRows.Count) {
            throw "internal: classify produced $($plan.Count) row(s) for $($SourceRows.Count) source row(s)"
        }
        return $plan
    }

    # --- plan queries ----------------------------------------------------

    # Get-PlanVerdict <relative-path> — the verdict, or "" when the path is not in
    # the plan (and when there is no plan at all, which is what makes the verdict
    # lookup a no-op for fresh installs, mode 1 and mode 3).
    function Get-PlanVerdict {
        param([string]$Rel)
        foreach ($row in $script:Plan) {
            $f = $row.Split("`t")
            if ($f.Count -ge 3 -and $f[0] -eq $Rel) { return $f[2] }
        }
        return ""
    }

    # Get-PlanCount <verdict> — how many plan rows carry it. Counted from the PLAN
    # rather than from what the copy loops did, so the readout reports the actual
    # classification including the two wholesale-copied directory trees.
    function Get-PlanCount {
        param([string]$Verdict)
        $n = 0
        foreach ($row in $script:Plan) {
            $f = $row.Split("`t")
            if ($f.Count -ge 3 -and $f[2] -eq $Verdict) { $n++ }
        }
        return $n
    }

    # Get-PlanRowCount — rows in the plan; 0 when there is none. An EMPTY plan must
    # never read as "nothing to do": with no rows every path falls through
    # Copy-ByVerdict's unknown-verdict arm and gets COPIED, so skipping the backup
    # on an empty plan would clobber the tree without a snapshot. The probe below
    # requires at least one row for exactly that reason.
    function Get-PlanRowCount {
        return @($script:Plan).Count
    }

    # Get-PlanWriteCount — how many plan rows would put bytes on disk. TWO terms:
    #
    #   1. Verdict rows: copy-new, replace-stock and replace-custom (all three
    #      write the shipped file) plus preserve-custom (writes a <path>.new
    #      sidecar). skip-current writes nothing.
    #   2. `merged`-class rows whose file is ABSENT from the target. classify emits
    #      `merge` for settings.json / .mcp.json unconditionally, because the
    #      installer reconciles them with jq instead of copying — but the two jq
    #      merge sections only own the case where the file EXISTS. When it does
    #      not, the path falls through to a plain copy, and that copy is a write
    #      the first term cannot see.
    #
    # Term 2 exists because the probe's contract is "it fired => this run put no
    # bytes on disk", and that sentence is what the backup decision rests on. An
    # operator who deleted .mcp.json and re-ran the same release was told "no file
    # changes" while the installer recreated the file. Nothing was ever at risk,
    # but an invariant that is only NEARLY true is one a future change can break
    # without failing a test.
    function Get-PlanWriteCount {
        $n = 0
        foreach ($row in $script:Plan) {
            $f = $row.Split("`t")
            if ($f.Count -lt 3) { continue }
            if (@("copy-new", "replace-stock", "replace-custom", "preserve-custom") -contains $f[2]) { $n++ }
        }
        # MERGED-ABSENT-START (load-bearing; the L2 META-TEST deletes the bash
        # counterpart of this block and asserts the probe goes back to firing on a
        # tree that is about to gain a file. Keep both sentinels, and keep the
        # deletion fail-safe: without this loop the count can only get SMALLER —
        # i.e. back to the pre-U0.5 readout, never to a spuriously skipped backup.)
        foreach ($row in $script:Plan) {
            $f = $row.Split("`t")
            if ($f.Count -lt 3 -or $f[1] -ne "merged") { continue }
            $mergedPath = Join-Path $script:Target ($f[0] -replace '/', [string][System.IO.Path]::DirectorySeparatorChar)
            if (-not (Test-Path -LiteralPath $mergedPath -PathType Leaf)) { $n++ }
        }
        # MERGED-ABSENT-END
        return $n
    }

    # Copy-ByVerdict <src> <dst> — verdict-driven placement, the PowerShell mirror
    # of install.sh's place_by_verdict. Reached from Copy-WorkflowFile whenever
    # $script:VerdictMode is on: the v3 -> v4 upgrade flow, and a mode-2 Update
    # classified against the target's own install-manifest. ONE walk for both, so
    # an upgrade and a re-run can never disagree about what is safe to overwrite.
    function Copy-ByVerdict {
        param([string]$Src, [string]$Dst)
        $rel = $Dst
        if ($rel.StartsWith($script:Target, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rel = $rel.Substring($script:Target.Length).TrimStart('\', '/')
        }
        # The plan speaks in forward slashes (it has to: the same rows are read by
        # the bash side), the target paths in backslashes.
        $rel = $rel -replace '\\', '/'
        $verdict = Get-PlanVerdict $rel

        # plugin.json is the version marker the NEXT upgrade's detection reads, so
        # it is copied on every verdict. A customized one is still reported (the
        # original is in the backup).
        if ($rel -eq ".claude-plugin/plugin.json") {
            Copy-Item -LiteralPath $Src -Destination $Dst -Force
            if ($verdict -eq "replace-custom") {
                $script:ReplacedFiles += $rel
                Write-Color "OK   $rel (replaced; yours is in the backup)" Yellow
            } else {
                Write-Color "OK   $rel" Green
            }
            return
        }

        switch ($verdict) {
            "skip-current" {
                Write-Color "same $rel (already current)" Cyan
            }
            "preserve-custom" {
                Copy-Item -LiteralPath $Src -Destination "$Dst.new" -Force
                $script:PreservedFiles += $rel
                Write-Color "keep $rel (yours; shipped version written to $rel.new)" Yellow
            }
            "replace-custom" {
                Copy-Item -LiteralPath $Src -Destination $Dst -Force
                $script:ReplacedFiles += $rel
                Write-Color "OK   $rel (replaced; yours is in the backup)" Yellow
            }
            # copy-new / replace-stock / merge all write the shipped file. `merge`
            # is reachable only when a merged-class file is ABSENT from the target,
            # since the jq merge sections own the exists case.
            "copy-new"      { Copy-Item -LiteralPath $Src -Destination $Dst -Force; Write-Color "OK   $rel" Green }
            "replace-stock" { Copy-Item -LiteralPath $Src -Destination $Dst -Force; Write-Color "OK   $rel" Green }
            "merge"         { Copy-Item -LiteralPath $Src -Destination $Dst -Force; Write-Color "OK   $rel" Green }
            "" {
                # Not in the plan at all. The manifest is supposed to enumerate
                # everything the copy loops touch, so an unlisted path means the
                # two have drifted — copy it and say so.
                Copy-Item -LiteralPath $Src -Destination $Dst -Force
                Write-Color "OK   $rel (not in the shipped manifest; copied)" Yellow
            }
            default {
                Copy-Item -LiteralPath $Src -Destination $Dst -Force
                Write-Color "OK   $rel (unrecognised verdict '$verdict'; copied)" Yellow
            }
        }
    }

    # Copy-ClaudeTree <source-dir> <backup-dir> — a DOTFILE-INCLUSIVE recursive
    # copy of .claude/'s CONTENTS into the backup root.
    #
    # Get-ChildItem -Force is the point: without it the enumeration skips hidden
    # items, and .claude\.qa-tracking\ — every gate record and review artifact in a
    # live install — never reaches the backup. That is the exact bug the bash side
    # fixed by moving from `cp -r dir/*` to `cp -R dir/.`, and the PowerShell
    # spelling of the same mistake is a bare wildcard copy.
    function Copy-ClaudeTree {
        param([string]$SourceTree, [string]$BackupDir)
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
        Get-ChildItem -LiteralPath $SourceTree -Force | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $BackupDir -Recurse -Force
        }
    }

    # Shipped docs subset (v4.1 / U0.8) ------------------------------------
    # TWO files, named individually -- NOT docs\*.md. docs\ in an install target
    # belongs to the operator; the plugin borrows exactly these two filenames in
    # it: CODEX_SETUP.md (how to wire the optional reviewer lane through the
    # Codex CLI) and HOOKS.md (the hook reference the gate messages point at by
    # name, including the denylist hash-migration recovery the v4 upgrade note
    # cites). Class workflow in the surface manifest.
    #
    # DEFINED HERE, ABOVE EVERY BACKUP LEG, so the backup list below and the copy
    # loop far later in this file read the SAME variable. Keep this list,
    # install.sh's $SHIPPED_DOCS, the required-source entries in both installers,
    # and the two docs rows in Get-WorkflowSurfaceRows / workflow-manifest.sh in
    # sync -- packaging-parity.test.sh set-compares all six.
    # BEGIN SHIPPED_DOCS (packaging-parity.test.sh extracts this block; keep the sentinels)
    $ShippedDocs = @("docs/CODEX_SETUP.md", "docs/HOOKS.md")
    # END SHIPPED_DOCS

    # Root-level files any install path may overwrite, and which therefore have
    # to reach that path's backup. Mirrors install.sh's $BACKUP_ROOT_FILES, and
    # $ShippedDocs is the SAME variable the copy loop iterates -- that sharing is
    # the fix for a HIGH data-loss defect QA found in the first cut of U0.8 (the
    # subset was named in six places but no backup leg was extended, so an
    # operator-edited docs/HOOKS.md was overwritten while the readout claimed
    # "yours is in the backup" and the backup held no such file).
    #
    # CLAUDE.md is here despite being outside the shipped surface: the mode-1
    # path replaces it, so a snapshot omitting it would lose operator memory.
    # .claude-plugin\plugin.json is deliberately absent -- the v3 leg backs it up
    # under its flat basename for historical reasons the L2 spec pins.
    $BackupRootFiles = @("CLAUDE.md", ".mcp.json", "LESSONS.md", ".worktreeinclude") + $ShippedDocs

    # Copy-RootFiles <backup-dir> — copy every root-level file the run may
    # overwrite into <backup-dir>, PRESERVING each file's relative path.
    #
    # LAYOUT: MIRRORED, not flat (v4.1 / U0.8) — same decision and same reasoning
    # as install.sh's backup_root_files, and the same rule this change set gave
    # the uninstaller's trash: A ROOT ROW KEEPS ITS RELATIVE PATH, so the four
    # pre-U0.8 bare filenames still land exactly where they always did and only
    # the nested docs rows are new. Flattening docs\HOOKS.md to HOOKS.md would be
    # ambiguous against any root-level HOOKS.md and would make the report's
    # Compare-Object advice point at the wrong tree.
    #
    # Per-file failures are swallowed: a backup that could not capture one file
    # must not abort a run whose caller already decided the tree is
    # snapshot-worthy. Copy-ClaudeTree is the one that is allowed to be fatal.
    function Copy-RootFiles {
        param([string]$BackupDir)
        if (-not $BackupDir) { return }
        # ROOT-BACKUP-START (load-bearing; the bash twin is stripped by the L2
        # META-TEST at installer-v3-upgrade.sh 11d. Keep both sentinels INSIDE
        # the function in both files, so a strip degrades to "no root-level file
        # reaches the backup" -- the pre-U0.8 behaviour -- rather than leaving
        # call sites pointing at a function that no longer exists.)
        foreach ($rootRel in $script:BackupRootFiles) {
            $rootSrc = Join-Path $Target $rootRel
            if (-not (Test-Path -LiteralPath $rootSrc -PathType Leaf)) { continue }
            $rootDst = Join-Path $BackupDir ($rootRel -replace '/', [string][System.IO.Path]::DirectorySeparatorChar)
            $rootParent = Split-Path $rootDst -Parent
            try {
                if (-not (Test-Path -LiteralPath $rootParent)) {
                    New-Item -ItemType Directory -Path $rootParent -Force | Out-Null
                }
                Copy-Item -LiteralPath $rootSrc -Destination $rootDst -Force
            } catch {
                Write-Color "note could not back up $rootRel ($($_.Exception.Message))" Yellow
            }
        }
        # ROOT-BACKUP-END
    }

    # --- version + upgrade detection --------------------------------------

    # The version this run is INSTALLING, read from the source manifest rather
    # than hardcoded — every readout and the install-manifest header interpolate
    # it, so a release bump needs no installer edit.
    #
    # ConvertFrom-Json rather than a jq call: jq's stderr would have to be
    # redirected, and a redirected native stderr under $ErrorActionPreference =
    # 'Stop' is a terminating error on Windows PowerShell 5.1
    # (claude-workflow-plugin-3t1 facet 3). A try/catch here cannot crash.
    $SourceVersion = ""
    try {
        $SourceVersion = (Get-Content -Raw -LiteralPath (Join-Path $SourceDir ".claude-plugin/plugin.json") |
            ConvertFrom-Json).version
    } catch {
        $SourceVersion = ""
    }
    $SourceVersionLabel = if ($SourceVersion) { "$SourceVersion" } else { "unknown" }

    # Get-TargetPluginVersion — the `version` field of the manifest ALREADY
    # installed in the target, or "" when there is none / it is unreadable. Every
    # caller runs before the copy loops overwrite it; once plugin.json has been
    # replaced this function reports the NEW version, which is why the v3 flow
    # captures it during detection.
    function Get-TargetPluginVersion {
        $installed = Join-Path $script:Target ".claude-plugin\plugin.json"
        if (-not (Test-Path -LiteralPath $installed -PathType Leaf)) { return "" }
        try {
            $v = (Get-Content -Raw -LiteralPath $installed | ConvertFrom-Json).version
            if ($null -eq $v) { return "" }
            return "$v"
        } catch {
            return ""
        }
    }

    $script:V3DetectedVersion = ""
    $script:V3Signals = ""

    # Detect-V3Install — $true when the target looks like a 3.x install this run
    # should upgrade. Signals, in decision order:
    #
    #   (a) $Target\.claude-plugin\plugin.json declares a 3.x version. PRIMARY and
    #       sufficient on its own — the installed manifest is the one artifact
    #       that states, on the record, which release wrote the tree.
    #   (b) That version is missing/unreadable/empty AND neither v4 marker is
    #       present (.claude\scripts\review-check.sh, .claude\model-roles). It
    #       reuses the v2 detector's "not just an empty stub" guard, so a fresh or
    #       empty target can never take this branch.
    #
    #       What (b) actually covers is a manifest whose VERSION FIELD is
    #       unreadable or hand-edited — the file is there, the parse gets nothing
    #       out of it. A DELETED manifest is NOT this branch's case in practice:
    #       the v2 detector's signal 2 ("hooks.json present, no
    #       .claude-plugin/plugin.json") fires first on any real installed tree,
    #       and the v2 block above runs BEFORE this one, so a manifest-less
    #       install routes to the v2 redirect for as long as
    #       .claude\hooks\hooks.json survives. (b) sees a deleted manifest only
    #       when hooks.json is gone too. Do not delete v2 signal 2 on the strength
    #       of this branch — they cover different trees.
    function Detect-V3Install {
        $claudeDir = Join-Path $script:Target ".claude"
        $ver = Get-TargetPluginVersion

        if ($ver -like "3.*") {
            $script:V3DetectedVersion = $ver
            $script:V3Signals = ".claude-plugin/plugin.json declares version $ver"
            return $true
        }
        # A readable non-3.x version (4.x, or anything else) is NOT this flow.
        if ($ver) { return $false }
        if (-not (Test-Path -LiteralPath $claudeDir -PathType Container)) { return $false }
        # Either v4 marker means the target is already v4 or newer.
        if ((Test-Path -LiteralPath (Join-Path $claudeDir "scripts\review-check.sh")) -or
            (Test-Path -LiteralPath (Join-Path $claudeDir "model-roles"))) { return $false }
        # "Not just an empty stub": .claude\ has to hold real installed content.
        if ((Test-Path -LiteralPath (Join-Path $claudeDir "agents")) -or
            (Test-Path -LiteralPath (Join-Path $claudeDir "scripts")) -or
            (Test-Path -LiteralPath (Join-Path $claudeDir "settings.json"))) {
            $script:V3DetectedVersion = ""
            $script:V3Signals = "no readable plugin version; no .claude/scripts/review-check.sh and no .claude/model-roles (both v4)"
            return $true
        }
        return $false
    }

    # Detect non-interactive mode (irm | iex pipes; CI runners). When the
    # host UI isn't interactive, Read-Host can hang or throw; we default
    # to the safe path instead. Mirrors install.sh's /dev/tty fallback.
    $NonInteractive = (-not [Environment]::UserInteractive) -or `
                      ($Host.Name -eq "ServerRemoteHost") -or `
                      ($null -eq $Host.UI.RawUI)

    # Git repo check
    $GitDir = Join-Path $Target ".git"
    if (-not (Test-Path $GitDir)) {
        Write-Color "No git repository found." Yellow
        if ($NonInteractive) {
            Write-Color "Non-interactive mode detected. Auto-initializing git (required for Beads)." Yellow
            $InitGit = "y"
        } else {
            $InitGit = Read-Host "Initialize git repository? (required for Beads) (y/n)"
        }
        if ($InitGit -eq "y") {
            Push-Location $Target
            git init
            $GitignoreFile = Join-Path $Target ".gitignore"
            if (-not (Test-Path $GitignoreFile)) {
                # Written through Write-LfFile, NOT `Out-File -Encoding UTF8`
                # (v4.1 / U0.8). Under Windows PowerShell 5.1 that cmdlet means
                # UTF-8 WITH BOM and host-native CRLF, and a BOM on the first
                # line of a .gitignore is a pattern git may not match — so the
                # very first rule, node_modules/, could silently stop working on
                # exactly the platform this file exists for. Same writer the
                # manifest and the merged JSON use; the reasoning is in its
                # header.
                #
                # An explicit string ARRAY rather than a here-string: the join is
                # then LF by construction, independent of the line endings THIS
                # file happens to be checked out with.
                #
                # packaging-parity.test.sh extracts the sentinel-delimited list
                # below and compares it line-for-line against the .gitignore
                # install.sh's heredoc actually PRODUCES. Keep the sentinels on
                # their own lines and keep one single-quoted entry per line.
                # BEGIN GENERATED_GITIGNORE
                Write-LfFile -FilePath $GitignoreFile -Lines @(
                    '# Dependencies'
                    'node_modules/'
                    'vendor/'
                    '.venv/'
                    '__pycache__/'
                    ''
                    '# Build outputs'
                    'dist/'
                    'build/'
                    '*.egg-info/'
                    ''
                    '# Environment'
                    '.env'
                    '.env.local'
                    '*.log'
                    ''
                    '# IDE'
                    '.idea/'
                    '.vscode/'
                    '*.swp'
                    '*.swo'
                    ''
                    '# OS'
                    '.DS_Store'
                    'Thumbs.db'
                    ''
                    '# Claude workflow (session-specific, not committed)'
                    '.claude/.session-start'
                    '.claude/.qa-tracking/'
                    '.claude/.mutation-runs/'
                    '.claude/.mutation-worktrees/'
                    ''
                    '# Claude workflow (installer/uninstaller artifacts, not committed).'
                    '# Every one of these is written by install.sh or uninstall.sh into the'
                    '# project root, and every one of them was previously untracked-and-unignored'
                    '# noise an operator had to notice and exclude by hand:'
                    '#   .claude-backup-*/          mode 1 / mode 2 pre-write snapshot'
                    '#   .claude-v2-backup-*/       v2 -> v3 migration snapshot'
                    '#   .claude-v3-backup-*/       v3 -> v4 migration snapshot (holds upgrade-report.txt)'
                    '#   .claude-uninstall-trash-*/ uninstall.sh''s recoverable trash'
                    '#   *.new                      the upgrade''s operator-file sidecars, written'
                    '#                              next to the file they did NOT overwrite; deleted'
                    '#                              by the operator once reviewed'
                    '#   *.json.bak                 the pre-merge copies of settings.json / .mcp.json'
                    '.claude-backup-*/'
                    '.claude-v2-backup-*/'
                    '.claude-v3-backup-*/'
                    '.claude-uninstall-trash-*/'
                    '*.new'
                    '.claude/settings.json.bak'
                    '.mcp.json.bak'
                )
                # END GENERATED_GITIGNORE
                git add .gitignore 2>$null
            }
            git commit -m "Initial commit" --allow-empty 2>$null
            Pop-Location
            Write-Color "OK Initialized git repository" Green
        } else {
            Write-Color "Cannot proceed without git repository." Red
            exit 1
        }
    }

    # v2 detection (PowerShell installer is minimal: detect + redirect to install.sh) ---
    # Signals match the bash detect_v2_install in install.sh:
    #   1. Agent files lack a `model:` frontmatter field.
    #   2. .claude/hooks/hooks.json present but .claude-plugin/plugin.json absent.
    #   3. No .claude/mcp/ and no .claude/skills/workflow-engine/.
    # We do NOT perform the migration in PowerShell -- it duplicates 100+ lines
    # of logic that install.sh already has and that we maintain in one place.
    # Instead we print a clear redirect and exit.
    $ClaudeDir = Join-Path $Target ".claude"
    $V2Signals = @()
    if (Test-Path $ClaudeDir) {
        $Agents = Get-ChildItem "$ClaudeDir\agents\*.md" -ErrorAction SilentlyContinue
        if ($Agents.Count -gt 0) {
            $MissingModel = 0
            foreach ($a in $Agents) {
                $head = Get-Content $a.FullName -TotalCount 20 -ErrorAction SilentlyContinue
                if (-not ($head -match '^model:')) { $MissingModel++ }
            }
            if ($MissingModel -eq $Agents.Count) {
                $V2Signals += "agents lack 'model:' frontmatter"
            }
        }
        if ((Test-Path "$ClaudeDir\hooks\hooks.json") -and
            (-not (Test-Path (Join-Path $Target ".claude-plugin/plugin.json")))) {
            $V2Signals += "hooks.json present, no .claude-plugin/plugin.json"
        }
        $HasContent = (Test-Path "$ClaudeDir\agents") -or `
                      (Test-Path "$ClaudeDir\scripts") -or `
                      (Test-Path "$ClaudeDir\settings.json")
        if ($HasContent -and `
            (-not (Test-Path "$ClaudeDir\mcp")) -and `
            (-not (Test-Path "$ClaudeDir\skills\workflow-engine"))) {
            $V2Signals += "no .claude/mcp/ and no .claude/skills/workflow-engine/"
        }
    }

    # Show-V2Redirect — print the v2 migration redirect and exit 2. TWO callers:
    # the auto-detected v2 arm immediately below, and -Upgrade on a tree with no
    # readable plugin manifest, which is install.sh's "no v2 signals detected;
    # treating .claude/ as v2 anyway" arm. Both land in the same place because
    # PowerShell implements neither v2 flow.
    function Show-V2Redirect {
        param([string]$SignalText)
        Write-Host ""
        Write-Color "Detected v2 plugin installation at $Target" Cyan
        Write-Host ("  Signals: " + $SignalText)
        Write-Host ""
        Write-Color "The v2 -> v3 upgrade flow is implemented in install.sh, not in PowerShell." Yellow
        Write-Host "Run the bash installer to migrate (it backs up to .claude-v2-backup-<timestamp>/ first):"
        Write-Host ""
        Write-Host "  # via Git Bash (ships with Git for Windows):"
        Write-Host "  bash install.sh --upgrade"
        Write-Host ""
        Write-Host "  # via WSL:"
        Write-Host "  wsl bash install.sh --upgrade"
        Write-Host ""
        Write-Host "  # via curl-pipe in Git Bash:"
        Write-Host "  curl -fsSL https://raw.githubusercontent.com/preql-data/claude-workflow-plugin/main/install.sh | bash -s -- --upgrade"
        Write-Host ""
        # "implemented natively" and not "works natively": the v3 -> v4 flow in
        # this file is verified by inspection and by the L1 parity assertions, not
        # by an executed Windows run. No adjective without an artifact.
        Write-Color "Fresh installs and the v3 -> v4 upgrade are implemented natively in PowerShell; only the v2 migration requires bash." Yellow
        Write-Host "If you want to overwrite the v2 install with a fresh install (losing v2 customizations),"
        Write-Host "remove the .claude/ directory first and re-run this script:"
        Write-Host "  Remove-Item -Recurse $ClaudeDir"
        Write-Host ""
        exit 2
    }

    if ($V2Signals.Count -gt 0) {
        Show-V2Redirect -SignalText ($V2Signals -join "; ")
    }

    # Upgrade detection ladder (v4.1 / U0.7) --------------------------------
    # Mirrors install.sh's, arm for arm. Order is the contract:
    #
    #   1. v2 signals win outright (handled above — that layout predates the
    #      manifest entirely), whether or not -Upgrade was passed.
    #   2. -Upgrade forces A migration; WHICH one is still a detection question.
    #      An installed plugin manifest of any version takes the v3 -> v4 flow; a
    #      target we cannot read at all keeps the legacy "treat .claude/ as v2"
    #      behaviour, which here means the redirect above.
    #   3. Without -Upgrade, Detect-V3Install decides.
    #
    # Anything else falls through to the three existing install modes.
    $V3Upgrade = $false

    if ($Upgrade) {
        if (Test-Path -LiteralPath (Join-Path $Target ".claude-plugin\plugin.json")) {
            $V3Upgrade = $true
            if (Detect-V3Install) {
                Write-Color "Upgrade mode forced (-Upgrade). Running the v3 -> v$SourceVersionLabel upgrade flow." Yellow
                Write-Host "  Signals: $script:V3Signals"
            } else {
                $script:V3DetectedVersion = Get-TargetPluginVersion
                $declared = if ($script:V3DetectedVersion) { $script:V3DetectedVersion } else { "unknown" }
                Write-Color "Upgrade mode forced (-Upgrade). Target declares v$declared; running the upgrade flow anyway." Yellow
                # Deliberately does NOT name the old table: which one this run uses
                # is decided further down (the target's own install-manifest when
                # it has a usable one, else the frozen release table) and the
                # "Classifying the installed tree against ..." line reports it for
                # real.
                Write-Host "  Anything that differs from both the shipped file and the reference table named below is treated as customized (replaced with a report line, or preserved as .new)."
            }
        } elseif (Test-Path $ClaudeDir) {
            Show-V2Redirect -SignalText "no v2 signals and no .claude-plugin/plugin.json; -Upgrade treats .claude/ as v2"
        } else {
            # Nothing installed at all. install.sh's equivalent arm gates its v2
            # backup on an existing .claude/, so it too just installs fresh here.
            Write-Color "Upgrade mode forced (-Upgrade). Nothing is installed at $Target yet; installing fresh." Yellow
        }
    } elseif (Detect-V3Install) {
        $V3Upgrade = $true
        $detected = if ($script:V3DetectedVersion) { $script:V3DetectedVersion } else { "3.x" }
        Write-Color "Detected v$detected plugin installation. Upgrading to v$SourceVersionLabel..." Cyan
        Write-Host "  Signals: $script:V3Signals"
    }

    # Mode selection
    $MergeMode = $false
    $UpdateMode = $false
    $BackupDir = $null

    if ($V3Upgrade) {
        # ---- v3.x -> v4 upgrade flow (v4.1 / U0.7) -----------------------
        # Order is load-bearing:
        #   1. BACK UP. Nothing below is reversible without it.
        #   2. CLASSIFY. Classification hashes the target, so it has to run
        #      before the first write.
        #   3. The copy loops consume the plan through Copy-WorkflowFile ->
        #      Copy-ByVerdict.
        $Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $V3BackupDir = Join-Path $Target ".claude-v3-backup-$Stamp"
        Write-Color "Backing up the installed plugin to $V3BackupDir" Yellow
        if (Test-Path $ClaudeDir) {
            # Here the backup is the ONLY copy of a replaced file, so a failure is
            # FATAL rather than ignored. Upgrading a tree we could not snapshot is
            # exactly the unrecoverable case this flow exists to prevent.
            try {
                Copy-ClaudeTree -SourceTree $ClaudeDir -BackupDir $V3BackupDir
            } catch {
                Write-Color "Could not back up $ClaudeDir - refusing to upgrade in place." Red
                Write-Host "Free the disk space (or fix the permissions) and rerun."
                Write-Host "  reason: $($_.Exception.Message)"
                exit 1
            }
        } else {
            New-Item -ItemType Directory -Path $V3BackupDir -Force | Out-Null
        }
        # Root-level files the upgrade may touch, each at its own relative path --
        # see Copy-RootFiles for the mirrored-layout decision and the data-loss
        # defect that forced it. The four pre-U0.8 names are bare filenames, so
        # they still land flat exactly as before; only the nested docs rows are
        # new.
        Copy-RootFiles -BackupDir $V3BackupDir
        # plugin.json keeps its FLAT basename rather than nesting a second
        # .claude-plugin\ inside what is already a snapshot of .claude\. This is
        # the one deliberate exception to the mirroring rule, and the L2 spec
        # pins it.
        $installedManifestJson = Join-Path $Target ".claude-plugin\plugin.json"
        if (Test-Path -LiteralPath $installedManifestJson -PathType Leaf) {
            Copy-Item -LiteralPath $installedManifestJson -Destination (Join-Path $V3BackupDir "plugin.json") -Force
        }
        Write-Color "OK backup created (includes dotfiles: .qa-tracking/ and friends)" Green

        # $UpdateMode is what routes settings.json and .mcp.json through the
        # key-wise jq merges below instead of a clobbering copy — which is exactly
        # what a `merge` verdict for both merged-class files means.
        $UpdateMode = $true

        # Pick the old table this upgrade classifies against. TWO sources, in
        # preference order (v4.1 / U0.5):
        #
        #   1. $Target\.claude\install-manifest, when the target is NOT a 3.x
        #      install and the manifest parses. It records the exact per-file
        #      hashes THIS tree was installed with, so "stock" and "customized"
        #      are answered from the tree's own history rather than inferred from a
        #      release table that predates it. Reached by -Upgrade on a 4.x
        #      target: without it, every file that changed between v3.5 and the
        #      installed release looks customized, so stock operator files collect
        #      spurious .new sidecars and stock workflow files get reported as
        #      "replaced; yours is in the backup".
        #
        #   2. manifests\v<release>.sha256 — the frozen table for the release a
        #      target was installed from. The ONLY option for a genuine 3.x tree
        #      (no install-manifest existed before v4.1) and the fallback for any
        #      target whose manifest is missing or unreadable.
        #
        # A 3.x version pins source 2 explicitly rather than by accident: if some
        # hand-built 3.x tree ever carried an install-manifest, the frozen table is
        # still the right answer for it, because the v3.5 -> v4 verdicts the L2
        # spec pins are defined against that table.
        $UpgradeOldTable = $null
        $UpgradeOldTableLabel = ""
        if ($script:V3DetectedVersion -and (-not ($script:V3DetectedVersion -like "3.*"))) {
            if (Get-InstalledManifestOldTable) {
                $UpgradeOldTable = $script:InstalledManifestTable
                # $() around every interpolated scope-qualified read: PowerShell
                # stops a bare "$script:Foo.bar" at the dot, which is right here
                # but silently wrong one edit later.
                $UpgradeOldTableLabel = ".claude/install-manifest (v$($script:InstalledManifestVersion))"
            }
        }
        if ($null -eq $UpgradeOldTable) {
            $frozenTable = Join-Path $SourceDir "manifests\v3.5.0.sha256"
            if ($script:V3DetectedVersion) {
                $versioned = Join-Path $SourceDir "manifests\v$($script:V3DetectedVersion).sha256"
                if (Test-Path -LiteralPath $versioned -PathType Leaf) { $frozenTable = $versioned }
            }
            # ONE prerequisite here, not two: this file reimplements the surface
            # generator natively, so there is no workflow-manifest.sh to be
            # missing and the only thing that can be absent is the table. That is
            # why the sentence names the table specifically and install.sh's
            # names whichever of ITS two halves actually failed (v4.1 / U0.8,
            # R1-F3 — install.sh said "has neither" on an OR). Do not "restore
            # parity" by re-adding a generator clause that cannot fire.
            if (-not (Test-Path -LiteralPath $frozenTable -PathType Leaf)) {
                Write-Color "The upgrade flow needs a frozen hash table and this source tree has none." Red
                Write-Host "  old table: $frozenTable (MISSING)"
                Write-Host "Without it, customized files cannot be told from stock ones."
                Write-Host "Your backup is at $V3BackupDir."
                Write-Host "Rerun with -Mode 2 for the flat non-destructive update instead."
                exit 1
            }
            $UpgradeOldTable = Read-HashTable $frozenTable
            $UpgradeOldTableLabel = Split-Path $frozenTable -Leaf
        }

        Write-Color "Classifying the installed tree against $UpgradeOldTableLabel..." Yellow
        $sourceRows = @(Get-SourceManifestRows)
        $planOk = $false
        if ($sourceRows.Count -ge 1) {
            try {
                $script:Plan = @(Get-ClassifyPlan -SourceRows $sourceRows -OldTable $UpgradeOldTable -TargetRoot $Target)
                $planOk = $script:Plan.Count -ge 1
            } catch {
                Write-Host "  reason: $($_.Exception.Message)"
                $planOk = $false
            }
        }
        if (-not $planOk) {
            Write-Color "Could not classify the installed tree; refusing to write a partial upgrade." Red
            Write-Host "Your backup is at $V3BackupDir. Rerun with -Mode 2 to take the flat"
            Write-Host "non-destructive update path instead."
            exit 1
        }
        $script:VerdictMode = $true
        $script:PlanOldTableLabel = $UpgradeOldTableLabel
        Write-Color "OK upgrade plan: $($script:Plan.Count) file(s) classified" Green
    } elseif (Test-Path $ClaudeDir) {
        Write-Color "Existing .claude/ directory found." Yellow

        $ExistingAgents = (Get-ChildItem "$ClaudeDir\agents\*.md" -ErrorAction SilentlyContinue | Measure-Object).Count
        $ExistingScripts = (Get-ChildItem "$ClaudeDir\scripts\*.sh" -ErrorAction SilentlyContinue | Measure-Object).Count

        if ($ExistingAgents -gt 0 -or $ExistingScripts -gt 0) {
            Write-Host "  Found: $ExistingAgents agents, $ExistingScripts scripts"
            Write-Host ""
            Write-Color "Options:" Yellow
            Write-Host "  1) Backup and install fresh"
            Write-Host "  2) Update workflow (keeps CLAUDE.md, merges settings)"
            Write-Host "  3) Merge only (skip existing files)"
            Write-Host "  4) Cancel"
            Write-Host ""

            # Under `irm | iex`, Read-Host can hang or throw. Honour -Mode
            # explicitly; otherwise default to Update (option 2) in
            # non-interactive contexts. Matches install.sh's behaviour.
            if ($Mode) {
                $Choice = $Mode
                Write-Host "Mode set via -Mode: $Choice"
            } elseif ($NonInteractive) {
                $Choice = "2"
                Write-Color "Non-interactive mode detected. Defaulting to Update (option 2)." Yellow
                Write-Color "Pass -Mode 1|2|3 to override." Yellow
            } else {
                $Choice = Read-Host "Choose [1-4]"
            }
            $Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $BackupDir = Join-Path $Target ".claude-backup-$Stamp"

            switch ($Choice) {
                "1" {
                    # Mode 1 is the explicit "back up and install fresh" choice, so
                    # its backup is the POINT of the mode rather than a safety net
                    # for whatever this run happens to write. It therefore keeps its
                    # unconditional backup and its flat overwrite; the no-change
                    # probe below is deliberately mode-2 only.
                    Write-Color "Creating backup at $BackupDir" Yellow
                    Copy-ClaudeTree -SourceTree $ClaudeDir -BackupDir $BackupDir
                    # Root-level files too (v4.1 / U0.8): mode 1 overwrites every
                    # one of them, so its backup -- which is the POINT of the mode
                    # -- has to hold them. Supersedes the CLAUDE.md-only copy that
                    # used to be here; CLAUDE.md is the first entry in the list.
                    Copy-RootFiles -BackupDir $BackupDir
                    Write-Color "OK Backup created" Green
                }
                "2" {
                    Write-Color "Update mode: updating workflow, preserving CLAUDE.md" Yellow
                    $UpdateMode = $true

                    # Verdict-driven Update (v4.1 / U0.4, ps1 mirror U0.7) ------
                    # Through v4.0 this branch plain-copied every shipped file, so
                    # the SECOND run on a tree the installer had already written
                    # silently overwrote anything the operator changed in between —
                    # the very clobber the v3 -> v4 flow exists to prevent, one run
                    # later. $Target\.claude\install-manifest names the release that
                    # wrote the tree and carries its per-file hashes, which is
                    # exactly the old table classification needs, so the Update
                    # reuses the upgrade flow's verdict walk rather than a second
                    # copy of it.
                    #
                    # No usable manifest (every pre-v4.1 install) -> the legacy
                    # plain-copy behaviour, unchanged. The note says so, and points
                    # out that this run writes the manifest the NEXT one will use.
                    # Classification runs BEFORE the backup because it only reads,
                    # and the probe below needs its verdicts to decide.
                    if (Get-InstalledManifestOldTable) {
                        $updateRows = @(Get-SourceManifestRows)
                        $updatePlanOk = $false
                        if ($updateRows.Count -ge 1) {
                            try {
                                $script:Plan = @(Get-ClassifyPlan -SourceRows $updateRows `
                                    -OldTable $script:InstalledManifestTable -TargetRoot $Target)
                                $updatePlanOk = $script:Plan.Count -ge 1
                            } catch {
                                $updatePlanOk = $false
                            }
                        }
                        if ($updatePlanOk) {
                            $script:VerdictMode = $true
                            $script:PlanOldTableLabel = ".claude/install-manifest (v$($script:InstalledManifestVersion))"
                            Write-Color "OK   classified against .claude/install-manifest (v$($script:InstalledManifestVersion)): $($script:Plan.Count) file(s)" Green
                        } else {
                            $script:Plan = @()
                            Write-Color "note could not classify against .claude/install-manifest; updating with plain copies (your tree is backed up below)" Yellow
                        }
                    } else {
                        Write-Color "note no usable .claude/install-manifest in the target; updating with plain copies. This run writes one, so the next update preserves your per-file edits." Yellow
                    }

                    # No-change probe. Re-running the SAME release over an unchanged
                    # tree writes nothing, and a timestamped backup dir per re-run is
                    # noise the operator has to clean up by hand. Skip the backup
                    # only when BOTH hold: the manifest header names the release we
                    # are installing, and the plan carries zero write verdicts. The
                    # merges and the install-manifest rewrite still run either way —
                    # both are idempotent.
                    #
                    # A preserved customization (preserve-custom) counts as a write,
                    # so a tree with one still gets its backup: "wrote nothing" has
                    # to mean nothing, not almost nothing.
                    # NOCHANGE-PROBE-START (load-bearing; the L2 META-TEST rewrites
                    # the initialiser inside the bash counterpart of these sentinels
                    # to force the probe TRUE and asserts the backup assertion flips.
                    # Keep both sentinels, and keep the fail-safe default false:
                    # deleting this block must leave the backup unconditional, never
                    # the other way round.)
                    $UpdateSkipBackup = $false
                    if ($script:VerdictMode -and
                        $script:InstalledManifestVersion -and
                        ($script:InstalledManifestVersion -eq $SourceVersionLabel) -and
                        ((Get-PlanRowCount) -ge 1) -and
                        ((Get-PlanWriteCount) -eq 0)) {
                        $UpdateSkipBackup = $true
                    }
                    # NOCHANGE-PROBE-END

                    if ($UpdateSkipBackup) {
                        # THE EM DASH IS COMPOSED, NOT WRITTEN (R1-F1). This file
                        # carries no byte-order mark, so Windows PowerShell 5.1
                        # decodes it as the ANSI code page: a literal UTF-8 em dash
                        # (E2 80 94) arrives as three cp1252 characters ending in
                        # 0x94 = U+201D, and the PowerShell grammar counts
                        # U+201C/201D/201E as DOUBLE-QUOTE CHARACTERS — so the byte
                        # CLOSES this string and the whole script stops parsing.
                        # Not mojibake: a hard, silent, file-wide parse failure on
                        # the one host this file exists for.
                        #
                        # The sentence must stay BYTE-IDENTICAL to install.sh's
                        # (packaging-parity 6g pins it file-to-file, and the L2
                        # spec asserts the bash text verbatim), so the character is
                        # built at output time and the SOURCE stays pure ASCII.
                        # A BOM would also fix the decode, but a BOM is a byte any
                        # editor or pipeline can strip, and stripping it would
                        # silently restore a whole-script parse failure; ASCII
                        # source cannot be broken that way.
                        Write-Color "note already at $SourceVersionLabel; no file changes $([char]0x2014) skipping backup" Cyan
                        $BackupDir = $null
                    } else {
                        Copy-ClaudeTree -SourceTree $ClaudeDir -BackupDir $BackupDir
                        # Root-level files too (v4.1 / U0.8). This leg took
                        # NOTHING outside .claude\ before, which made it the worst
                        # of the three: a mode-2 Update is what the v4.0 -> v4.1
                        # population actually runs, and classify hands
                        # replace-custom to any target file differing from both
                        # the shipped bytes and the old table -- including paths
                        # the old table never listed, so an operator's own
                        # docs\HOOKS.md qualified.
                        Copy-RootFiles -BackupDir $BackupDir
                        Write-Color "OK Backup created" Green
                    }
                }
                "3" {
                    $MergeMode = $true
                    Write-Color "Merge mode: will skip existing files" Yellow
                }
                default {
                    Write-Host "Cancelled."
                    exit 0
                }
            }
        }
    }

    Write-Host ""
    Write-Color "Creating plugin structure..." Yellow

    foreach ($d in @(
        "$ClaudeDir\agents",
        "$ClaudeDir\skills\workflow-engine",
        "$ClaudeDir\hooks",
        "$ClaudeDir\scripts",
        "$ClaudeDir\commands",
        "$ClaudeDir\rubrics",
        "$ClaudeDir\tests\mutation",
        "$ClaudeDir\tests\mutation\calibration",
        "$ClaudeDir\tests\mutation\lib",
        (Join-Path $Target ".claude-plugin"),
        # docs/ is the OPERATOR's directory; the plugin borrows exactly two
        # filenames in it (see the docs subset copy block below). -Force makes
        # this a no-op for a project that already has one.
        (Join-Path $Target "docs")
    )) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }

    function Copy-WorkflowFile {
        param([string]$Src, [string]$Dst)
        if ($script:MergeMode -and (Test-Path $Dst)) {
            Write-Color ("skip {0} (exists)" -f (Split-Path $Dst -Leaf)) Yellow
            return
        }
        # The verdict-driven flows decide per file. Routing that through
        # Copy-WorkflowFile rather than rewriting each copy loop keeps ONE decision
        # point: every loop below (agents, scripts, commands, rubrics, single
        # config files) gets the verdict treatment for free, and no future loop can
        # forget it. Gating on $script:VerdictMode rather than on the upgrade flag
        # is what lets the mode-2 Update reuse the walk unchanged.
        if ($script:VerdictMode) {
            Copy-ByVerdict -Src $Src -Dst $Dst
            return
        }
        Copy-Item -Path $Src -Destination $Dst -Force
        Write-Color ("OK   {0}" -f (Split-Path $Dst -Leaf)) Green
    }

    # Agents glob copy so newly-shipped agents (grader.md @ v3.2.0,
    # judge.md @ v3.4.0) ride along without an installer edit per release.
    Get-ChildItem (Join-Path $SourceDir ".claude/agents/*.md") -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-WorkflowFile -Src $_.FullName -Dst "$ClaudeDir\agents\$($_.Name)"
    }

    # Copy every hook + helper script. The set has grown across plugin
    # versions (v2 was 5 scripts; v3 is 14). Using a glob keeps the installer
    # in sync automatically as scripts are added/removed in the plugin source.
    Get-ChildItem (Join-Path $SourceDir ".claude/scripts/*.sh") -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-WorkflowFile -Src $_.FullName -Dst "$ClaudeDir\scripts\$($_.Name)"
    }

    # MCP servers -----------------------------------------------------------
    # Copy each MCP server directory wholesale, excluding node_modules / .tmp
    # / *.log. node_modules will be installed by the operator if they want to
    # run the servers locally.
    $SourceMcpDir = Join-Path $SourceDir ".claude/mcp"
    if (Test-Path $SourceMcpDir) {
        $TargetMcpDir = Join-Path $ClaudeDir "mcp"
        New-Item -ItemType Directory -Force -Path $TargetMcpDir | Out-Null
        Get-ChildItem -Path $SourceMcpDir -Directory | ForEach-Object {
            $serverName = $_.Name
            $dstServer = Join-Path $TargetMcpDir $serverName
            New-Item -ItemType Directory -Force -Path $dstServer | Out-Null
            # robocopy: /E = include subdirs (empty too), /XD = exclude dirs,
            # /XF = exclude files, /NFL/NDL/NJH/NJS/NP = quiet output.
            # Exit codes 0-7 are success in robocopy world.
            $rc = & robocopy $_.FullName $dstServer /E /XD node_modules .tmp /XF *.log /NFL /NDL /NJH /NJS /NP
            if ($LASTEXITCODE -gt 7) {
                # Fall back to Copy-Item if robocopy isn't behaving.
                Copy-Item -Path (Join-Path $_.FullName '*') -Destination $dstServer -Recurse -Force -Exclude @('node_modules','.tmp','*.log') -ErrorAction SilentlyContinue
            }
            $global:LASTEXITCODE = 0
            Write-Color ("OK   mcp/{0}" -f $serverName) Green
        }
    }

    # Shared merge-input validity gate (v4.1 / R1-F1) -----------------------
    # `jq empty` is NOT a validity check for a merge input: it exits 0 for an
    # EMPTY file AND for a MULTI-DOCUMENT stream. Both Update-mode merges below
    # slurp with `jq -s` and index .[0] (existing) / .[1] (new) — so a target
    # holding two documents pushes the SHIPPED file out to .[2], silently
    # binding $new to the operator's second document (proven outcome for
    # .mcp.json: a merged config with none of the shipped bd / code-graph
    # servers). The only sound contract is "exactly ONE JSON document, and that
    # document is an object". Keep this jq expression equivalent to install.sh's.
    # BEGIN JSON_SINGLE_OBJECT_JQ (packaging-parity.test.sh extracts this block; keep the sentinels)
    $JsonSingleObjectJq = 'length == 1 and (.[0] | type == "object")'
    # END JSON_SINGLE_OBJECT_JQ

    # Test-JsonSingleObject <path> — $true only when the file holds exactly one
    # JSON document and that document is an object. Reads the expression from
    # script scope, matching this file's existing $script: convention
    # (Copy-WorkflowFile reads $script:MergeMode the same way).
    #
    # THE SCOPED 'Continue' IS THE FIX FOR claude-workflow-plugin-3t1 FACET 3, not
    # a style choice. Windows PowerShell 5.1 turns a native command's stderr into
    # ErrorRecords when that stream is REDIRECTED, and under
    # $ErrorActionPreference = 'Stop' (set globally at the top of this file) those
    # become a TERMINATING NativeCommandError. jq writes to stderr for exactly the
    # malformed inputs this gate exists to reject — so with a plain `2>$null` the
    # corrupt-.mcp.json arm CRASHED the installer instead of falling through to the
    # copy-shipped fallback, and after U0.2 it crashed BOTH merge gates. pwsh 7.2+
    # is unaffected, which is why this survived review.
    #
    # The assignment is FUNCTION-SCOPED: PowerShell creates a local copy of the
    # preference variable, so 'Stop' is back in force the moment this returns. 2>&1
    # merges stderr into the output stream and the whole thing is discarded; only
    # jq's exit code is read.
    function Test-JsonSingleObject {
        param([string]$FilePath)
        $ErrorActionPreference = 'Continue'
        & jq -s -e $script:JsonSingleObjectJq $FilePath 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    }

    # Get-JqScalar <filter> <path> — one-line jq read with stderr contained, for
    # the same reason Test-JsonSingleObject scopes its preference: a malformed
    # input file must produce an empty answer, never a terminating error. Returns
    # "" when jq fails for any reason.
    #
    # The output is collected in FULL and indexed afterwards, deliberately not
    # filtered with `Select-Object -First 1`: that cmdlet stops the upstream
    # pipeline early, which can leave $LASTEXITCODE holding a stale value from an
    # unrelated command — and the exit code is the only thing distinguishing "jq
    # said no" from "jq could not read the file".
    function Get-JqScalar {
        param([string]$Filter, [string]$FilePath)
        $ErrorActionPreference = 'Continue'
        $raw = @(& jq -r $Filter $FilePath 2>&1)
        if ($LASTEXITCODE -ne 0) { return "" }
        $out = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
        if ($out.Count -lt 1) { return "" }
        return "$($out[0])"
    }

    # Root MCP config -------------------------------------------------------
    # Mode 1 (backup-and-install-fresh) and mode 3 (merge/skip-existing) copy
    # as before. Mode 2 (Update) MERGES instead of overwriting so an operator's
    # own MCP servers survive a plugin upgrade: the shipped bd / code-graph
    # entries win on collision (that union IS the v3.5 -> v4 rewrite to the
    # ${CLAUDE_PROJECT_DIR:-.} form, since the shipped entries carry it), the
    # server retired in 3.3.0 (code-context) is deleted outright, and operator
    # top-level keys are untouched because the merge base is $existing.
    #
    # This literal is a DUPLICATE of install.sh's — install.ps1 stays
    # standalone. Keep this jq expression equivalent to install.sh's;
    # packaging-parity.test.sh extracts both and pins them token-for-token.
    # BEGIN MCP_MERGE_JQ (packaging-parity.test.sh extracts this block; keep the sentinels)
    $McpMergeJq = '
        .[0] as $existing |
        .[1] as $new |
        $existing
        | .mcpServers = (($existing.mcpServers // {}) + ($new.mcpServers // {}))
        | del(.mcpServers["code-context"])
    '
    # END MCP_MERGE_JQ

    # Operator-owned servers pass through verbatim — including any bare
    # ${VAR} reference, which Claude Code does NOT expand in a project-scoped
    # .mcp.json (https://code.claude.com/docs/en/mcp — the documented form is
    # ${VAR:-default}). We never rewrite operator config; we name the server so
    # the operator can decide. Emits one server key per line, shipped keys
    # excluded. Keep this jq expression equivalent to install.sh's.
    $McpBareVarJq = '
        .[0] as $merged |
        .[1] as $new |
        ($new.mcpServers // {}) as $shipped |
        ($merged.mcpServers // {}) | to_entries
        | map(select($shipped[.key] == null))
        | map(select([.value | .. | strings] | any(test("\\$\\{[A-Za-z_][A-Za-z0-9_]*\\}"))))
        | .[].key
    '

    $SourceMcpJson = Join-Path $SourceDir ".mcp.json"
    $TargetMcpJson = Join-Path $Target ".mcp.json"
    if (Test-Path $SourceMcpJson) {
        if ($UpdateMode -and (Test-Path $TargetMcpJson)) {
            Copy-Item -Path $TargetMcpJson -Destination "$TargetMcpJson.bak" -Force
            if (Test-JsonSingleObject $TargetMcpJson) {
                Write-Color "Merging .mcp.json (preserving operator-added servers)..." Yellow
                # ARGUMENT ORDER IS THE UNION DIRECTION: existing file FIRST,
                # shipped file SECOND, because the expression binds .[0] as
                # $existing and .[1] as $new. Swapping the two operands would keep
                # this line valid jq and silently reverse the merge — the operator's
                # servers would win over the shipped ones and the
                # ${CLAUDE_PROJECT_DIR:-.} rewrite would never land.
                # packaging-parity.test.sh pins this order file-to-file against
                # install.sh's.
                $mcpMerged = & jq -s $McpMergeJq $TargetMcpJson $SourceMcpJson
                if ($LASTEXITCODE -eq 0 -and $mcpMerged) {
                    # WriteAllText with UTF8-no-BOM, and the lines re-joined with
                    # LF (claude-workflow-plugin-3t1 facets 1 + 2). `Out-File
                    # -Encoding UTF8` writes a BOM under Windows PowerShell 5.1 —
                    # older jq rejects BOM'd JSON, so the NEXT -Mode 2 run would
                    # take the "not valid JSON" arm and replace the operator's
                    # merged config with the shipped one. And `-NoNewline`
                    # concatenated jq's output lines into a single unreadable line,
                    # which is diff-hostile for an operator who commits .mcp.json.
                    Write-LfFile -FilePath $TargetMcpJson -Lines @($mcpMerged)
                    $script:McpMergeStatus = "merged"
                    Write-Color "OK   .mcp.json merged (previous file at .mcp.json.bak)" Green
                    $mcpBareVars = & jq -s -r $McpBareVarJq $TargetMcpJson $SourceMcpJson
                    foreach ($mcpSrv in $mcpBareVars) {
                        if ($mcpSrv) {
                            # Backtick-escaped `$ keeps ${VAR} / ${VAR:-default}
                            # literal. Deliberately NOT the -f format operator:
                            # String.Format would read `{VAR}` as a format item
                            # and throw. Same text as install.sh's note.
                            Write-Color "note .mcp.json server '$mcpSrv' carries a bare `${VAR} reference; project-scoped configs need the `${VAR:-default} form. Left unchanged (operator-owned)." Yellow
                        }
                    }
                } else {
                    $script:McpMergeStatus = "failed-untouched"
                    Write-Color "Could not merge .mcp.json - manual review needed (previous file at .mcp.json.bak)" Red
                }
            } else {
                Copy-Item -Path $SourceMcpJson -Destination $TargetMcpJson -Force
                $script:McpMergeStatus = "failed-replaced"
                Write-Color ".mcp.json was not a single JSON object (empty, multi-document, or malformed) - installed the shipped config (previous file saved to .mcp.json.bak)" Red
            }
        } else {
            Copy-WorkflowFile -Src $SourceMcpJson -Dst $TargetMcpJson
        }
    }

    Copy-WorkflowFile `
        -Src (Join-Path $SourceDir ".claude/hooks/hooks.json") `
        -Dst "$ClaudeDir\hooks\hooks.json"

    Copy-WorkflowFile `
        -Src (Join-Path $SourceDir ".claude/skills/workflow-engine/SKILL.md") `
        -Dst "$ClaudeDir\skills\workflow-engine\SKILL.md"

    Get-ChildItem (Join-Path $SourceDir ".claude/commands/*.md") -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-WorkflowFile -Src $_.FullName -Dst "$ClaudeDir\commands\$($_.Name)"
    }

    # Rubrics (Phase A / v3.2.0) ------------------------------------------
    $SourceRubrics = Join-Path $SourceDir ".claude/rubrics"
    if (Test-Path $SourceRubrics) {
        Get-ChildItem (Join-Path $SourceRubrics "*.md") -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-WorkflowFile -Src $_.FullName -Dst "$ClaudeDir\rubrics\$($_.Name)"
        }
    }

    # Rubric config + review config + model-ranking + model-roles + LESSONS + .worktreeinclude
    foreach ($asset in @(
        @{ Src = ".claude/rubric-config"; Dst = "$ClaudeDir\rubric-config" },
        @{ Src = ".claude/review-config"; Dst = "$ClaudeDir\review-config" },
        @{ Src = ".claude/model-ranking"; Dst = "$ClaudeDir\model-ranking" },
        @{ Src = ".claude/model-roles";   Dst = "$ClaudeDir\model-roles" },
        @{ Src = ".claude/effort-verdict"; Dst = "$ClaudeDir\effort-verdict" },
        @{ Src = "LESSONS.md";            Dst = (Join-Path $Target "LESSONS.md") },
        @{ Src = ".worktreeinclude";       Dst = (Join-Path $Target ".worktreeinclude") }
    )) {
        $SrcPath = Join-Path $SourceDir $asset.Src
        if (Test-Path $SrcPath) {
            Copy-WorkflowFile -Src $SrcPath -Dst $asset.Dst
        }
    }

    # Mutation tier (Phase C / v3.4.0) ------------------------------------
    $SourceMutation = Join-Path $SourceDir ".claude/tests/mutation"
    if (Test-Path $SourceMutation) {
        $TargetMutation = "$ClaudeDir\tests\mutation"
        New-Item -ItemType Directory -Force -Path $TargetMutation | Out-Null
        $rc = & robocopy $SourceMutation $TargetMutation /E /XD runs /XF *.log /NFL /NDL /NJH /NJS /NP
        if ($LASTEXITCODE -gt 7) {
            Copy-Item -Path (Join-Path $SourceMutation '*') -Destination $TargetMutation -Recurse -Force -Exclude @('runs','*.log') -ErrorAction SilentlyContinue
        }
        $global:LASTEXITCODE = 0
        Write-Color "OK   tests/mutation/" Green
    }

    # Shipped docs subset (v4.1 / U0.8) ------------------------------------
    # The list itself is $ShippedDocs, defined far above because every backup leg
    # reads it; see there for what the two files are.
    #
    # THE PRE-COPY GUARD (v4.1 / U0.8, QA cycle 1). docs\ is the ONLY shipped
    # scope where a NEVER-INSTALLED project can already own a file at a path the
    # plugin wants: everything else lives under .claude\ or is a plugin-specific
    # root dotfile. On a fresh install there is no plan, no verdict walk and no
    # backup directory, so a pre-existing docs\HOOKS.md was silently overwritten
    # under a generic "OK   HOOKS.md" line.
    #
    # WHY .bak AND NOT .new: the shipped doc has to win the canonical path (the
    # gate messages point operators at docs/HOOKS.md BY NAME), so the operator's
    # copy is preserved beside it instead. `.new` is the operator-class
    # convention, where the operator's content wins; these are workflow class.
    # `.bak` is what this installer already uses for the pre-merge copies of
    # settings.json and .mcp.json, and the generated .gitignore covers it.
    #
    # Gated on exists-AND-DIFFERS, and skipped under $script:VerdictMode (those
    # paths take a real backup) and $script:MergeMode (mode 3 skips existing
    # files outright). Returns $false when the old bytes could NOT be saved, and
    # the caller then refuses the copy: losing the plugin's doc is recoverable
    # from the source tree, losing the operator's is not.
    function Save-PreExistingDoc {
        param([string]$Src, [string]$Dst)
        $rel = $Dst
        if ($rel.StartsWith($script:Target, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rel = $rel.Substring($script:Target.Length).TrimStart('\', '/') -replace '\\', '/'
        }
        if ($script:VerdictMode) { return $true }
        if ($script:MergeMode) { return $true }
        if (-not (Test-Path -LiteralPath $Dst -PathType Leaf)) { return $true }
        # Get-FileSha256 THROWS by design (a wrong hash would silently overwrite
        # a customized file), and $ErrorActionPreference is 'Stop', so both calls
        # are wrapped. An unreadable file degrades to "differs", which takes the
        # PRESERVING branch -- the safe direction on a destructive decision.
        $alreadyShipped = $false
        try {
            $alreadyShipped = ((Get-FileSha256 $Dst) -eq (Get-FileSha256 $Src))
        } catch {
            $alreadyShipped = $false
        }
        if ($alreadyShipped) { return $true }
        try {
            Copy-Item -LiteralPath $Dst -Destination "$Dst.bak" -Force
            Write-Color "keep $rel was already here and differs; your copy saved as $rel.bak" Yellow
            return $true
        } catch {
            Write-Color "warn $rel was already here and differs, and your copy could NOT be saved to $rel.bak -- not overwriting it" Red
            return $false
        }
    }

    foreach ($shippedDoc in $ShippedDocs) {
        $docSrc = Join-Path $SourceDir $shippedDoc
        if (-not (Test-Path -LiteralPath $docSrc -PathType Leaf)) { continue }
        $docDst = Join-Path $Target $shippedDoc
        $docParent = Split-Path $docDst -Parent
        if (-not (Test-Path -LiteralPath $docParent)) {
            New-Item -ItemType Directory -Path $docParent -Force | Out-Null
        }
        if (Save-PreExistingDoc -Src $docSrc -Dst $docDst) {
            Copy-WorkflowFile -Src $docSrc -Dst $docDst
        }
    }

    Copy-WorkflowFile `
        -Src (Join-Path $SourceDir ".claude-plugin/plugin.json") `
        -Dst (Join-Path $Target ".claude-plugin/plugin.json")

    # Settings.json: merge if Update, copy fresh otherwise -----------------
    $SettingsFile = "$ClaudeDir\settings.json"
    $SourceSettings = Join-Path $SourceDir ".claude/settings.json"

    if (Test-Path $SettingsFile) {
        if ($UpdateMode) {
            Write-Color "Merging settings.json (preserving non-workflow keys)..." Yellow
            Copy-Item -Path $SettingsFile -Destination "$SettingsFile.bak" -Force
            # v4.0.0 (cnz.1): detect a legacy env.CLAUDE_CODE_EFFORT_LEVEL pin
            # in the existing settings before the merge. The env union can only
            # ADD keys, so the explicit del below is what removes it; we print a
            # one-line notice when it was present. Keep this jq expression
            # equivalent to install.sh's.
            # Read through Get-JqScalar: the same WinPS 5.1 stderr-redirect trap as
            # Test-JsonSingleObject (3t1 facet 3). This probe runs BEFORE the
            # validity gate, so a malformed settings.json reaches it first — with a
            # bare `2>$null` that crashed the installer before the manual-review arm
            # could ever be taken.
            $hadEffortEnv = Get-JqScalar -Filter 'if (.env // {} | has("CLAUDE_CODE_EFFORT_LEVEL")) then "yes" else "no" end' -FilePath $SettingsFile
            # v4.1: effortLevel / statusLine are add-if-absent — a settings file
            # of pre-v3.5 lineage gains the shipped values, an operator's own
            # pin survives untouched. "add-if-absent" is keyed on PRESENCE
            # (`has`), never on truthiness (R1-F2): `if $existing.effortLevel`
            # would read an explicit null/false as absent and overwrite it. The
            # permissions clause carried the same latent defect since v4.0.0 and
            # is converted here too. This literal is a DUPLICATE of install.sh's;
            # packaging-parity.test.sh extracts both and pins them
            # token-for-token.
            # BEGIN SETTINGS_MERGE_JQ (packaging-parity.test.sh extracts this block; keep the sentinels)
            $SettingsMergeJq = '
                .[0] as $existing |
                .[1] as $new |
                $existing
                | .hooks = $new.hooks
                | .env = ((($existing.env // {}) + ($new.env // {})) | del(.CLAUDE_CODE_EFFORT_LEVEL))
                | .additionalDirectories = ($new.additionalDirectories // $existing.additionalDirectories)
                | (if ($existing | has("permissions")) then . else .permissions = $new.permissions end)
                | (if ($existing | has("effortLevel")) then . else .effortLevel = $new.effortLevel end)
                | (if ($existing | has("statusLine"))  then . else .statusLine  = $new.statusLine  end)
            '
            # END SETTINGS_MERGE_JQ
            # R1-F1, same class as .mcp.json above: refuse to merge anything that
            # is not exactly one JSON object, or the .[0]/.[1] binding silently
            # reads the operator's second document as the shipped file. Unlike
            # .mcp.json we do NOT install a fresh copy — settings.json is
            # operator-owned, so the file is left untouched (the .bak above is
            # already taken) and the manual-review line names the reason.
            $settingsSkipReason = ""
            if (Test-JsonSingleObject $SettingsFile) {
                # Existing file FIRST, shipped file SECOND — see the .mcp.json merge
                # above for why the operand order IS the union direction.
                $merged = & jq -s $SettingsMergeJq $SettingsFile $SourceSettings
            } else {
                # $merged stays empty, which is what the guard below tests —
                # no need to force $LASTEXITCODE (the jq inside
                # Test-JsonSingleObject has already set it non-zero).
                $merged = $null
                $settingsSkipReason = " (not a single JSON object: empty, multi-document, or malformed)"
            }
            if ($LASTEXITCODE -eq 0 -and $merged) {
                # LF-only, UTF8-no-BOM, jq's line structure preserved — same
                # reasoning as the .mcp.json write site (3t1 facets 1 + 2). A BOM'd
                # settings.json is worse here than for .mcp.json: Claude Code itself
                # reads this file.
                Write-LfFile -FilePath $SettingsFile -Lines @($merged)
                $script:SettingsMergeStatus = "merged"
                Write-Color "OK   settings.json merged" Green
                if ($hadEffortEnv -eq "yes") {
                    Write-Color "note removed legacy env.CLAUDE_CODE_EFFORT_LEVEL (v4: a non-xhigh value deactivates ultracode orchestration; effortLevel is now the floor)" Cyan
                }
            } else {
                $script:SettingsMergeStatus = "failed-untouched"
                Write-Color "Could not merge settings.json$settingsSkipReason - manual review needed; your file is unchanged (copy at .claude\settings.json.bak)" Red
            }
        } elseif ($MergeMode) {
            Write-Color "skip settings.json (exists, merge mode)" Yellow
        } else {
            Copy-Item -Path $SourceSettings -Destination $SettingsFile -Force
            Write-Color "OK   settings.json" Green
        }
    } else {
        Copy-Item -Path $SourceSettings -Destination $SettingsFile -Force
        Write-Color "OK   settings.json" Green
    }

    # Install manifest (v4.1 / U0.3, ps1 mirror U0.7) ------------------------
    # Written on EVERY install path — fresh, modes 1/2/3 and the v3 upgrade —
    # right after the last copy. It records the SOURCE surface this run installed
    # from: one header line naming the version, then the generated
    # path/class/sha256 TSV.
    #
    # Two consumers depend on it and BOTH COMPARE BYTES, so this file carries no
    # timestamp, no hostname and no install path: the next upgrade (bash or
    # PowerShell) reads the header to know which release wrote the tree, and the
    # parity/equivalence specs regenerate the manifest with the BASH generator and
    # diff it against this body. Adding "installed at <date>" here, or letting the
    # writer emit CRLF or a BOM, breaks all of them.
    $installManifestRows = @(Get-SourceManifestRows)
    if ($installManifestRows.Count -ge 1) {
        Write-LfFile -FilePath (Join-Path $ClaudeDir "install-manifest") `
            -Lines (@("# claude-workflow-plugin $SourceVersionLabel") + $installManifestRows)
        Write-Color "OK   .claude/install-manifest ($SourceVersionLabel)" Green
    } else {
        Write-Color "note could not write .claude/install-manifest (the shipped surface could not be hashed in $SourceDir)" Yellow
    }

    # CLAUDE.md (only if missing) -------------------------------------------
    $ClaudeMdFile = Join-Path $Target "CLAUDE.md"
    if (-not (Test-Path $ClaudeMdFile)) {
        @'
# Project Memory

## Overview
<!-- Describe your project -->

## Users & Personas
### Primary User: [Name]
- **Who**: [Description]
- **Goal**: [What they want]

## Critical User Journeys
### Journey 1: [Name]
**Steps**: 1. User... 2. User sees...
**Failure modes**: Invalid input, network error

## Beads Labels Convention
- `qa-pending` - Awaiting QA
- `qa-approved` - QA signed off
- `backend`, `frontend`, `devops` - Domain
'@ | Out-File -FilePath $ClaudeMdFile -Encoding UTF8 -NoNewline
        Write-Color "OK   CLAUDE.md template" Green
    }

    # Beads init / hooks / doctor -------------------------------------------
    Write-Host ""
    Write-Color "Setting up Beads..." Yellow

    Push-Location $Target
    try {
        $BeadsDir = Join-Path $Target ".beads"
        if (-not (Test-Path $BeadsDir)) {
            Write-Host "Initializing Beads..."
            bd init --quiet 2>$null
            Write-Color "OK Beads initialized" Green
        }

        Write-Host "Installing Beads git hooks..."
        bd hooks install 2>$null
        Write-Color "OK Git hooks installed" Green

        Write-Host "Running Beads health check..."
        $DoctorOutput = bd doctor 2>&1
        if ($DoctorOutput -match "error|Error") {
            Write-Color "Some issues detected - run 'bd doctor' for details" Yellow
        } else {
            Write-Color "OK Beads health check passed" Green
        }
    } finally {
        Pop-Location
    }

    # v3 upgrade readout (v4.1 / U0.7) --------------------------------------
    # Plain text on purpose: the same bytes go to the console AND to
    # $V3BackupDir\upgrade-report.txt, and colour escapes in a saved report are
    # noise. Both version numbers come from the two plugin.json files — the
    # installed one was captured during detection, before the copy loops replaced
    # it — so no release number is hardcoded here.
    #
    # Built as a line LIST rather than a here-string: the counts are function
    # calls, and a here-string would need a $() around each one, which is exactly
    # the shape that silently produces "System.Object[]" when a call starts
    # returning a collection.
    function Get-UpgradeReportLines {
        $fromLabel = if ($script:V3DetectedVersion) { "v$($script:V3DetectedVersion)" } else { "an unidentified v3.x install" }
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("Upgrade complete: $fromLabel -> v$SourceVersionLabel")
        $lines.Add("")
        $lines.Add("Target:           $Target")
        $lines.Add("Backup:           $V3BackupDir")
        $lines.Add("Install manifest: $Target\.claude\install-manifest")
        $lines.Add("")
        $lines.Add("Files by upgrade verdict (hash classification, hashed against $($script:PlanOldTableLabel)):")
        $lines.Add(("  copied (new)           {0}" -f (Get-PlanCount "copy-new")))
        $lines.Add(("  replaced (stock)       {0}" -f (Get-PlanCount "replace-stock")))
        $lines.Add(("  already current        {0}" -f (Get-PlanCount "skip-current")))
        $lines.Add(("  replaced (customized)  {0}" -f (Get-PlanCount "replace-custom")))
        $lines.Add(("  preserved (yours)      {0}" -f (Get-PlanCount "preserve-custom")))
        $lines.Add(("  merged key-wise        {0}" -f (Get-PlanCount "merge")))
        $lines.Add("  ---------------------- ---")
        $lines.Add(("  total classified       {0}" -f (Get-PlanRowCount)))
        $lines.Add("")
        $lines.Add("The lists below cover the per-file walk. .claude\mcp\ and .claude\tests\mutation\")
        $lines.Add("are copied wholesale (plugin-owned product, never operator-owned), so their files")
        $lines.Add("are counted above but not listed one by one.")
        $lines.Add("")
        # One line per merged-class file, from its four-state status (R1-F2).
        # The failure sentences are the point: a saved report that says
        # "installed as shipped" about a file the merge could not touch sends an
        # operator looking for a problem that is not there, and away from the one
        # that is. Same four arms and the same sentences as install.sh's.
        # The sentinels below are load-bearing: packaging-parity.test.sh extracts
        # this block from BOTH installers and compares the sentences
        # file-to-file, path separators folded. Keep each sentinel alone on its
        # line, and keep the sentences byte-equal to install.sh's -- an executed
        # L2 META asserts on the bash ones.
        # MERGE-STATUS-LINES-START
        $lines.Add("Merged key-wise instead of overwritten:")
        switch ($script:SettingsMergeStatus) {
            "merged" {
                $lines.Add("  .claude\settings.json  (your pre-upgrade copy: .claude\settings.json.bak)")
            }
            "failed-untouched" {
                $lines.Add("  .claude\settings.json  (MERGE FAILED - your file was left UNCHANGED, not replaced; copy at .claude\settings.json.bak. Merge the shipped keys in by hand.)")
            }
            default {
                $lines.Add("  .claude\settings.json  (installed as shipped; nothing to merge)")
            }
        }
        switch ($script:McpMergeStatus) {
            "merged" {
                $lines.Add("  .mcp.json              (your pre-upgrade copy: .mcp.json.bak)")
            }
            "failed-untouched" {
                $lines.Add("  .mcp.json              (MERGE FAILED - your file was left UNCHANGED, not replaced; copy at .mcp.json.bak. Merge the shipped servers in by hand.)")
            }
            "failed-replaced" {
                $lines.Add("  .mcp.json              (MERGE REFUSED - yours was not a single JSON object, so the SHIPPED config was installed over it; yours is at .mcp.json.bak. Re-add your own servers from there.)")
            }
            default {
                $lines.Add("  .mcp.json              (installed as shipped; nothing to merge)")
            }
        }
        # MERGE-STATUS-LINES-END
        $lines.Add("")
        $lines.Add("Preserved your version, shipped version written alongside as *.new ($(@($script:PreservedFiles).Count)):")
        if (@($script:PreservedFiles).Count -eq 0) {
            $lines.Add("  (none - no operator-owned file differed from the shipped one)")
        } else {
            foreach ($f in $script:PreservedFiles) {
                $lines.Add("  $f")
                $lines.Add("      -> shipped version at $f.new")
            }
        }
        $lines.Add("")
        $lines.Add("Replaced, and yours was customized (your version is in the backup) ($(@($script:ReplacedFiles).Count)):")
        if (@($script:ReplacedFiles).Count -eq 0) {
            $lines.Add("  (none)")
        } else {
            foreach ($f in $script:ReplacedFiles) { $lines.Add("  $f") }
        }
        $lines.Add("")
        $lines.Add("ACTION REQUIRED")
        $lines.Add("")
        $lines.Add("  1. Review each *.new file, merge what you want into your own copy, then")
        $lines.Add("     delete the *.new file. Nothing reads them; they exist so an upgrade never")
        $lines.Add("     silently overwrites something you wrote.")
        $lines.Add("")
        $lines.Add("  2. Pre-v4 approvals on OPEN tasks re-block once, on purpose. The v4")
        $lines.Add("     change-set denylist changed, so the Stop hook now recomputes a different")
        $lines.Add("     change_set_hash: a task still carrying a qa-approved label from before")
        $lines.Add("     this upgrade reports LABEL_WITHOUT_RECORD and has to be re-approved. That")
        $lines.Add("     is the correct fail-closed direction - a stale approval must not release")
        $lines.Add("     work. CLOSED tasks are historical and are never re-blocked. The exact")
        $lines.Add("     recovery commands are in CHANGELOG.md under")
        # Concatenated rather than written literally: the CHANGELOG heading this
        # points at really does carry an em dash, and an operator searching for the
        # section needs the exact title. Same R1-F1 reasoning as the probe readout
        # above — this one is single-quoted, where the cp1252 mis-decode is only
        # mojibake rather than a parse break, but the file-wide rule is "no
        # non-ASCII byte outside a whole-line comment" and one exception is how the
        # rule stops being checkable.
        $lines.Add('     "UPGRADE NOTE ' + [char]0x2014 + ' one-time hash migration".')
        $lines.Add("")
        $lines.Add("  3. If anything looks wrong, your pre-upgrade tree is intact:")
        $lines.Add("       Compare-Object (Get-ChildItem -Recurse '$V3BackupDir') (Get-ChildItem -Recurse '$Target\.claude')")
        return $lines.ToArray()
    }

    # Done ------------------------------------------------------------------
    Write-Host ""
    if ($V3Upgrade) {
        $reportLines = @(Get-UpgradeReportLines)
        foreach ($line in $reportLines) { Write-Host $line }
        $reportPath = Join-Path $V3BackupDir "upgrade-report.txt"
        try {
            Write-LfFile -FilePath $reportPath -Lines $reportLines
            Write-Host ""
            Write-Host "This report: " -NoNewline
            Write-Color $reportPath Cyan
        } catch {
            Write-Host ""
            Write-Color "note could not save the report into $V3BackupDir" Yellow
        }
    } else {
        Write-Color "Installation complete." Green
        Write-Host ""
        Write-Host "Installed to: " -NoNewline
        Write-Color "$Target\.claude\" Cyan
        Write-Host "Manifest:     " -NoNewline
        Write-Color "$Target\.claude-plugin\plugin.json" Cyan
        if ($BackupDir -and (Test-Path $BackupDir)) {
            Write-Host "Backup at:    " -NoNewline
            Write-Color $BackupDir Cyan
        }

        # Verdict-driven Update summary (v4.1 / U0.4, ps1 mirror U0.7). Only a mode-2
        # Update with a usable install-manifest reaches this: the v3 flow prints its
        # own full report in the branch above, and every other path has no plan to
        # summarise. Deliberately short — the per-file `keep` / `OK` lines are already
        # in the scrollback; what an operator cannot reconstruct from those is the
        # count and the list of .new files still waiting for a decision.
        if ($script:VerdictMode) {
            Write-Host ""
            Write-Color "Classified against .claude/install-manifest (v$($script:InstalledManifestVersion)):" Cyan
            Write-Host ("  already current        {0}" -f (Get-PlanCount "skip-current"))
            Write-Host ("  copied (new)           {0}" -f (Get-PlanCount "copy-new"))
            Write-Host ("  replaced (stock)       {0}" -f (Get-PlanCount "replace-stock"))
            Write-Host ("  replaced (customized)  {0}" -f (Get-PlanCount "replace-custom"))
            Write-Host ("  preserved (yours)      {0}" -f (Get-PlanCount "preserve-custom"))
            Write-Host ("  merged key-wise        {0}" -f (Get-PlanCount "merge"))
            if (@($script:PreservedFiles).Count -gt 0) {
                Write-Host ""
                Write-Host "Your version was kept; the shipped version is alongside as *.new:"
                foreach ($preservedFile in $script:PreservedFiles) {
                    Write-Host "  $preservedFile  ->  $preservedFile.new"
                }
                Write-Host "Review each *.new, merge what you want, then delete it."
            }
            if (@($script:ReplacedFiles).Count -gt 0) {
                Write-Host ""
                Write-Host "Replaced, and yours was customized (your version is in the backup):"
                foreach ($replacedFile in $script:ReplacedFiles) { Write-Host "  $replacedFile" }
            }
        }

        # FRESH-INSTALL "what you just got" list (v4.1 / U0.8). The v3 upgrade
        # path prints its own report in the branch above; this one is what a
        # first-time operator sees, so it describes the CURRENT product rather
        # than a release note. Same content as install.sh's, ASCII-only (the
        # R1-F1 rule: no non-ASCII byte outside a whole-line comment).
        #
        # The heading interpolates the MAJOR of the version being installed --
        # no release number is typed here, and a bump needs no edit. When the
        # source plugin.json could not be read, $SourceVersion is empty and the
        # heading degrades to the unnumbered form rather than printing "v".
        #
        # The BRACES in "v${freshMajor}:" are load-bearing, not style: a bare
        # "$freshMajor:" is parsed as a scope/drive-qualified variable reference
        # (the colon is part of the name token), so the heading would come out
        # empty. Do not "simplify" them away.
        Write-Host ""
        $freshMajor = if ($SourceVersion) { ($SourceVersion -split '\.')[0] } else { "" }
        if ($freshMajor) {
            Write-Color "What's new in v${freshMajor}:" Cyan
        } else {
            Write-Color "What's in this release:" Cyan
        }
        Write-Host "  - Tri-model workflow: the orchestrator plans, Opus-class specialists build,"
        Write-Host "    and an optional second-family reviewer lane reads the same diff"
        Write-Host "  - Nobody signs off on their own work: qa-gate.sh approve REFUSES without an"
        Write-Host "    independent review artifact, and the Stop hook re-checks before releasing"
        Write-Host "  - Approvals are bound to a change-set hash, so a stale one cannot release work"
        Write-Host "  - Role-aware model selection (.claude/model-roles) + /workflow-model"
        Write-Host "  - Rubric-graded QA loop and a mutation tier (/mutation-sweep) with an LLM judge"
        Write-Host "  - Two MCP servers: bd-mcp (typed Beads tools), code-graph-mcp (impact_of, dead_code)"
        Write-Host "  - Hash-based re-runs and upgrades: .claude/install-manifest records what was"
        Write-Host "    installed, so your edits are preserved with the shipped copy alongside as *.new"
        Write-Host "  - uninstall.ps1 removes exactly what the installer wrote, into a recoverable trash"
        Write-Host ""
        Write-Host "Full release notes: CHANGELOG.md"
        Write-Host ""
        Write-Color "Requirements:" Yellow
        Write-Host "  - Git Bash (comes with Git for Windows) - the workflow scripts run via bash"
        Write-Host ""
    }
    Write-Color "Usage:" Yellow
    Write-Host "  cd $Target"
    Write-Host "  claude"
    Write-Host ""
    Write-Color "Beads commands:" Yellow
    Write-Host "  bd ready    - Available work"
    Write-Host "  bd blocked  - Blocked issues"
    Write-Host "  bd doctor   - Health check"
    Write-Host ""
    Write-Color "Remember: all code changes require @qa approval." Red
    Write-Host ""
} finally {
    Cleanup-Clone
}
