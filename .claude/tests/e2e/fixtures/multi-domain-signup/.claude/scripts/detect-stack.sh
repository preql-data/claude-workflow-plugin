#!/bin/bash
# detect-stack.sh - Polyglot project framework detection (F8/J17, Phase 4).
#
# Inspects the project root for well-known manifest files and emits a JSON
# document describing the detected runner + the test/lint/type commands.
#
# Override files (precedence over auto-detection):
#   .claude/test-cmd   single-line shell command for tests
#   .claude/lint-cmd   single-line shell command for lint
#   .claude/type-cmd   single-line shell command for type-check
#
# Output (JSON):
#   {
#     "runner": "npm" | "pytest" | "go" | "cargo" | "maven" | "gradle"
#               | "phpunit" | "rake" | "swift" | "dotnet" | "make" | "none",
#     "test_cmd": "...",
#     "lint_cmd": "...",
#     "type_cmd": "...",
#     "manifest": "<file detected>",
#     "overrides": {"test":bool, "lint":bool, "type":bool},
#     "observations": "..."
#   }
#
# When no runner is detected, all *_cmd fields are "" and runner is "none".
# A `none` runner is the cue for the Stop hook to skip technical checks
# without reporting a failure.

set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
OVERRIDE_DIR="$PROJECT_DIR/.claude"

read_override() {
    local f="$OVERRIDE_DIR/$1"
    [ -s "$f" ] || return 1
    head -1 "$f" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# ---------------------------------------------------------------------------
# Auto-detect runner. We pick the FIRST manifest matched in priority order.
# Rationale: in monorepos with both package.json (npm scripts) and a
# pyproject.toml, the conventional outer test-cmd is npm-style for the
# repo root; the user can override per-task via .claude/test-cmd.

RUNNER="none"
MANIFEST=""
TEST_CMD=""
LINT_CMD=""
TYPE_CMD=""

if [ -f "$PROJECT_DIR/package.json" ]; then
    RUNNER="npm"
    MANIFEST="package.json"
    # Determine which scripts exist - empty TEST_CMD if no test script.
    if jq -e '.scripts.test' "$PROJECT_DIR/package.json" >/dev/null 2>&1; then
        TEST_CMD="npm test --prefix \"$PROJECT_DIR\""
    fi
    if jq -e '.scripts.lint' "$PROJECT_DIR/package.json" >/dev/null 2>&1; then
        LINT_CMD="npm run lint --prefix \"$PROJECT_DIR\""
    fi
    # Type check: prefer `typecheck`, fall back to `type-check`, then bare `tsc --noEmit`.
    if jq -e '.scripts.typecheck' "$PROJECT_DIR/package.json" >/dev/null 2>&1; then
        TYPE_CMD="npm run typecheck --prefix \"$PROJECT_DIR\""
    elif jq -e '.scripts."type-check"' "$PROJECT_DIR/package.json" >/dev/null 2>&1; then
        TYPE_CMD="npm run type-check --prefix \"$PROJECT_DIR\""
    elif [ -f "$PROJECT_DIR/tsconfig.json" ]; then
        TYPE_CMD="npx --no-install tsc --noEmit -p \"$PROJECT_DIR/tsconfig.json\""
    fi
elif [ -f "$PROJECT_DIR/pyproject.toml" ] || [ -f "$PROJECT_DIR/setup.py" ] || [ -f "$PROJECT_DIR/setup.cfg" ]; then
    RUNNER="pytest"
    if [ -f "$PROJECT_DIR/pyproject.toml" ]; then
        MANIFEST="pyproject.toml"
    elif [ -f "$PROJECT_DIR/setup.py" ]; then
        MANIFEST="setup.py"
    else
        MANIFEST="setup.cfg"
    fi
    TEST_CMD="cd \"$PROJECT_DIR\" && python -m pytest"
    # Lint: ruff > flake8 > pylint, in that order of preference.
    if command -v ruff >/dev/null 2>&1; then
        LINT_CMD="cd \"$PROJECT_DIR\" && ruff check ."
    elif command -v flake8 >/dev/null 2>&1; then
        LINT_CMD="cd \"$PROJECT_DIR\" && flake8 ."
    elif command -v pylint >/dev/null 2>&1; then
        LINT_CMD="cd \"$PROJECT_DIR\" && pylint **/*.py"
    fi
    # Type: mypy > pyright.
    if command -v mypy >/dev/null 2>&1; then
        TYPE_CMD="cd \"$PROJECT_DIR\" && mypy ."
    elif command -v pyright >/dev/null 2>&1; then
        TYPE_CMD="cd \"$PROJECT_DIR\" && pyright"
    fi
elif [ -f "$PROJECT_DIR/go.mod" ]; then
    RUNNER="go"
    MANIFEST="go.mod"
    TEST_CMD="cd \"$PROJECT_DIR\" && go test ./..."
    if command -v golangci-lint >/dev/null 2>&1; then
        LINT_CMD="cd \"$PROJECT_DIR\" && golangci-lint run"
    else
        LINT_CMD="cd \"$PROJECT_DIR\" && go vet ./..."
    fi
    TYPE_CMD="cd \"$PROJECT_DIR\" && go build ./..."
elif [ -f "$PROJECT_DIR/Cargo.toml" ]; then
    RUNNER="cargo"
    MANIFEST="Cargo.toml"
    TEST_CMD="cd \"$PROJECT_DIR\" && cargo test"
    LINT_CMD="cd \"$PROJECT_DIR\" && cargo clippy -- -D warnings"
    TYPE_CMD="cd \"$PROJECT_DIR\" && cargo check"
elif [ -f "$PROJECT_DIR/pom.xml" ]; then
    RUNNER="maven"
    MANIFEST="pom.xml"
    TEST_CMD="cd \"$PROJECT_DIR\" && mvn test"
    LINT_CMD="cd \"$PROJECT_DIR\" && mvn checkstyle:check"
    TYPE_CMD="cd \"$PROJECT_DIR\" && mvn compile"
elif [ -f "$PROJECT_DIR/build.gradle" ] || [ -f "$PROJECT_DIR/build.gradle.kts" ]; then
    RUNNER="gradle"
    if [ -f "$PROJECT_DIR/build.gradle" ]; then
        MANIFEST="build.gradle"
    else
        MANIFEST="build.gradle.kts"
    fi
    if [ -x "$PROJECT_DIR/gradlew" ]; then
        TEST_CMD="cd \"$PROJECT_DIR\" && ./gradlew test"
        LINT_CMD="cd \"$PROJECT_DIR\" && ./gradlew check"
        TYPE_CMD="cd \"$PROJECT_DIR\" && ./gradlew compileJava"
    else
        TEST_CMD="cd \"$PROJECT_DIR\" && gradle test"
        LINT_CMD="cd \"$PROJECT_DIR\" && gradle check"
        TYPE_CMD="cd \"$PROJECT_DIR\" && gradle compileJava"
    fi
elif [ -f "$PROJECT_DIR/composer.json" ]; then
    RUNNER="phpunit"
    MANIFEST="composer.json"
    if [ -x "$PROJECT_DIR/vendor/bin/phpunit" ]; then
        TEST_CMD="cd \"$PROJECT_DIR\" && vendor/bin/phpunit"
    else
        TEST_CMD="cd \"$PROJECT_DIR\" && phpunit"
    fi
    if [ -x "$PROJECT_DIR/vendor/bin/phpcs" ]; then
        LINT_CMD="cd \"$PROJECT_DIR\" && vendor/bin/phpcs"
    fi
    if [ -x "$PROJECT_DIR/vendor/bin/phpstan" ]; then
        TYPE_CMD="cd \"$PROJECT_DIR\" && vendor/bin/phpstan analyse"
    fi
elif [ -f "$PROJECT_DIR/Gemfile" ]; then
    RUNNER="rake"
    MANIFEST="Gemfile"
    TEST_CMD="cd \"$PROJECT_DIR\" && bundle exec rake test"
    if grep -qi 'rubocop' "$PROJECT_DIR/Gemfile" 2>/dev/null; then
        LINT_CMD="cd \"$PROJECT_DIR\" && bundle exec rubocop"
    fi
elif [ -f "$PROJECT_DIR/Package.swift" ]; then
    RUNNER="swift"
    MANIFEST="Package.swift"
    TEST_CMD="cd \"$PROJECT_DIR\" && swift test"
    TYPE_CMD="cd \"$PROJECT_DIR\" && swift build"
elif ls "$PROJECT_DIR"/*.csproj >/dev/null 2>&1 || ls "$PROJECT_DIR"/*.sln >/dev/null 2>&1; then
    RUNNER="dotnet"
    MANIFEST=$(find "$PROJECT_DIR" -maxdepth 1 \( -name '*.csproj' -o -name '*.sln' \) -type f 2>/dev/null | head -1 | xargs basename 2>/dev/null || echo "dotnet")
    TEST_CMD="cd \"$PROJECT_DIR\" && dotnet test"
    TYPE_CMD="cd \"$PROJECT_DIR\" && dotnet build"
elif [ -f "$PROJECT_DIR/Makefile" ]; then
    # Last-resort detection: a Makefile with `test` or `check` target.
    RUNNER="make"
    MANIFEST="Makefile"
    if grep -qE '^test:' "$PROJECT_DIR/Makefile" 2>/dev/null; then
        TEST_CMD="cd \"$PROJECT_DIR\" && make test"
    elif grep -qE '^check:' "$PROJECT_DIR/Makefile" 2>/dev/null; then
        TEST_CMD="cd \"$PROJECT_DIR\" && make check"
    fi
    if grep -qE '^lint:' "$PROJECT_DIR/Makefile" 2>/dev/null; then
        LINT_CMD="cd \"$PROJECT_DIR\" && make lint"
    fi
fi

# ---------------------------------------------------------------------------
# Apply overrides. Tracked so the Stop hook can surface "you are using an
# override" in the block reason.

OVERRIDE_TEST=false; OVERRIDE_LINT=false; OVERRIDE_TYPE=false
if v=$(read_override "test-cmd" 2>/dev/null); then
    TEST_CMD="$v"
    OVERRIDE_TEST=true
fi
if v=$(read_override "lint-cmd" 2>/dev/null); then
    LINT_CMD="$v"
    OVERRIDE_LINT=true
fi
if v=$(read_override "type-cmd" 2>/dev/null); then
    TYPE_CMD="$v"
    OVERRIDE_TYPE=true
fi

# ---------------------------------------------------------------------------
# Emit JSON.

OBSERVATIONS="runner=$RUNNER manifest=${MANIFEST:-none}"
[ "$OVERRIDE_TEST" = true ] && OBSERVATIONS="$OBSERVATIONS test_cmd=override"
[ "$OVERRIDE_LINT" = true ] && OBSERVATIONS="$OBSERVATIONS lint_cmd=override"
[ "$OVERRIDE_TYPE" = true ] && OBSERVATIONS="$OBSERVATIONS type_cmd=override"

jq -n \
    --arg runner "$RUNNER" \
    --arg test_cmd "$TEST_CMD" \
    --arg lint_cmd "$LINT_CMD" \
    --arg type_cmd "$TYPE_CMD" \
    --arg manifest "$MANIFEST" \
    --argjson ot "$OVERRIDE_TEST" \
    --argjson ol "$OVERRIDE_LINT" \
    --argjson oy "$OVERRIDE_TYPE" \
    --arg obs "$OBSERVATIONS" \
    '{runner:$runner, test_cmd:$test_cmd, lint_cmd:$lint_cmd, type_cmd:$type_cmd,
      manifest:$manifest, overrides:{test:$ot, lint:$ol, type:$oy},
      observations:$obs}'
