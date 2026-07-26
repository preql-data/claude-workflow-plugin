# Claude Workflow Plugin v3 - Windows installer (PowerShell)
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
#   irm https://.../install.ps1 | iex                   # auto-clones repo

param(
    [string]$Path = ".",
    [string]$RepoUrl = $env:CLAUDE_WORKFLOW_REPO,
    [string]$RepoBranch = $env:CLAUDE_WORKFLOW_BRANCH,
    # Explicit mode override for non-interactive runs (irm | iex). Valid
    # values: "1" (backup+fresh), "2" (update), "3" (merge). Empty means
    # prompt interactively or default to Update under irm-pipe.
    [ValidateSet("", "1", "2", "3")]
    [string]$Mode = ""
)

$ErrorActionPreference = "Stop"

if (-not $RepoUrl)    { $RepoUrl = "https://github.com/preql-data/claude-workflow-plugin.git" }
if (-not $RepoBranch) { $RepoBranch = "main" }

$MinBdVersion = [Version]"0.47"

function Write-Color {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
}

# Resolve target path ---------------------------------------------------------
if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
$Target = (Resolve-Path $Path).Path

Write-Host ""
Write-Color "Claude Workflow Plugin v3" Cyan
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
        ".claude/hooks/hooks.json",
        ".claude/skills/workflow-engine/SKILL.md",
        ".claude/settings.json",
        ".claude-plugin/plugin.json",
        ".claude/commands/workflow-model.md"
    )
    foreach ($r in $Required) {
        if (-not (Test-Path (Join-Path $SourceDir $r))) {
            Write-Color "Plugin source missing: $r" Red
            Write-Host "(Looked in $SourceDir.) Aborting."
            exit 1
        }
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
                @"
node_modules/
.venv/
__pycache__/
dist/
build/
.env
.env.local
*.log
.idea/
.vscode/
.DS_Store
.claude/.session-start
.claude/.qa-tracking/
"@ | Out-File -FilePath $GitignoreFile -Encoding UTF8
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

    if ($V2Signals.Count -gt 0) {
        Write-Host ""
        Write-Color "Detected v2 plugin installation at $Target" Cyan
        Write-Host ("  Signals: " + ($V2Signals -join "; "))
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
        Write-Color "Fresh installs work natively in PowerShell; only the migration requires bash." Yellow
        Write-Host "If you want to overwrite the v2 install with a fresh v3 (losing v2 customizations),"
        Write-Host "remove the .claude/ directory first and re-run this script:"
        Write-Host "  Remove-Item -Recurse $ClaudeDir"
        Write-Host ""
        exit 2
    }

    # Mode selection
    $MergeMode = $false
    $UpdateMode = $false
    $BackupDir = $null

    if (Test-Path $ClaudeDir) {
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
                    Write-Color "Creating backup at $BackupDir" Yellow
                    Copy-Item -Path $ClaudeDir -Destination $BackupDir -Recurse
                    if (Test-Path (Join-Path $Target "CLAUDE.md")) {
                        Copy-Item -Path (Join-Path $Target "CLAUDE.md") -Destination $BackupDir
                    }
                    Write-Color "OK Backup created" Green
                }
                "2" {
                    Copy-Item -Path $ClaudeDir -Destination $BackupDir -Recurse
                    Write-Color "OK Backup created" Green
                    $UpdateMode = $true
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
        (Join-Path $Target ".claude-plugin")
    )) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }

    function Copy-WorkflowFile {
        param([string]$Src, [string]$Dst)
        if ($script:MergeMode -and (Test-Path $Dst)) {
            Write-Color ("skip {0} (exists)" -f (Split-Path $Dst -Leaf)) Yellow
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
    function Test-JsonSingleObject {
        param([string]$FilePath)
        & jq -s -e $script:JsonSingleObjectJq $FilePath 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
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
                $mcpMerged = & jq -s $McpMergeJq $TargetMcpJson $SourceMcpJson
                if ($LASTEXITCODE -eq 0 -and $mcpMerged) {
                    $mcpMerged | Out-File -FilePath $TargetMcpJson -Encoding UTF8 -NoNewline
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
                    Write-Color "Could not merge .mcp.json - manual review needed (previous file at .mcp.json.bak)" Red
                }
            } else {
                Copy-Item -Path $SourceMcpJson -Destination $TargetMcpJson -Force
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
            $hadEffortEnv = (& jq -r 'if (.env // {} | has("CLAUDE_CODE_EFFORT_LEVEL")) then "yes" else "no" end' $SettingsFile 2>$null)
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
                $merged = & jq -s $SettingsMergeJq $SettingsFile $SourceSettings
            } else {
                # $merged stays empty, which is what the guard below tests —
                # no need to force $LASTEXITCODE (the jq inside
                # Test-JsonSingleObject has already set it non-zero).
                $merged = $null
                $settingsSkipReason = " (not a single JSON object: empty, multi-document, or malformed)"
            }
            if ($LASTEXITCODE -eq 0 -and $merged) {
                $merged | Out-File -FilePath $SettingsFile -Encoding UTF8 -NoNewline
                Write-Color "OK   settings.json merged" Green
                if ($hadEffortEnv -eq "yes") {
                    Write-Color "note removed legacy env.CLAUDE_CODE_EFFORT_LEVEL (v4: a non-xhigh value deactivates ultracode orchestration; effortLevel is now the floor)" Cyan
                }
            } else {
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

    # Done ------------------------------------------------------------------
    Write-Host ""
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
    Write-Host ""
    Write-Color "What's new in v3:" Cyan
    Write-Host "  - Plugin manifest (.claude-plugin/plugin.json) — see it for the version"
    Write-Host "  - Model pinning per agent + /workflow-model upgrade command"
    Write-Host "  - MAX_THINKING_TOKENS at 64000 + extended-thinking instruction in every agent"
    Write-Host "  - Parent-folder access via additionalDirectories ('../')"
    Write-Host "  - SessionStart warns on stale model + old bd"
    Write-Host "  - Single-source-of-truth installer (no embedded duplication)"
    Write-Host "  - uninstall.ps1 for clean removal"
    Write-Host ""
    Write-Color "Requirements:" Yellow
    Write-Host "  - Git Bash (comes with Git for Windows) - the workflow scripts run via bash"
    Write-Host ""
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
