#!/usr/bin/env bash
# preflight.sh — Run before coding loop to catch known hazards
# Called from harness.sh before Phase 2 starts
#
# Returns 0 if safe, 1 if issues found (with warnings printed)

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

PROJECT_DIR="${1:-.}"
ISSUES=0

# ── 1. init.sh: background processes without output redirection ──
if [[ -f "$PROJECT_DIR/init.sh" ]]; then
    if grep -nE '&\s*$' "$PROJECT_DIR/init.sh" 2>/dev/null | grep -vq '>/dev/null\|&>/dev/null'; then
        log_error "init.sh has background processes without output redirection (will hang Claude)"
        grep -nE '&\s*$' "$PROJECT_DIR/init.sh" | grep -v '>/dev/null' | while read -r line; do
            echo "  $line"
        done
        ISSUES=1
    fi
fi

# ── 2. Test files: subprocess.run without timeout ──
BAD_TESTS=$(grep -rlE "subprocess\.run\(" "$PROJECT_DIR/tests/" 2>/dev/null | while read -r f; do
    if grep -l "subprocess\.run" "$f" | xargs grep -L "timeout" 2>/dev/null; then
        echo "$f"
    fi
done || true)

if [[ -n "$BAD_TESTS" ]]; then
    log_warn "Test files with subprocess.run() missing timeout= (may hang in loop):"
    echo "$BAD_TESTS" | while read -r f; do
        echo "  $f"
    done
    # Warning only, don't block
fi

# ── 3. features.json: valid JSON ──
if [[ -f "$PROJECT_DIR/features.json" ]]; then
    if ! jq . "$PROJECT_DIR/features.json" > /dev/null 2>&1; then
        log_error "features.json is not valid JSON"
        ISSUES=1
    fi
fi

# ── 4. Large test files that might be slow ──
if [[ -d "$PROJECT_DIR/tests" ]]; then
    LARGE_TESTS=$(find "$PROJECT_DIR/tests" -name "*.py" -size +50k 2>/dev/null || true)
    if [[ -n "$LARGE_TESTS" ]]; then
        log_warn "Large test files (>50KB, may be slow):"
        echo "$LARGE_TESTS" | while read -r f; do
            echo "  $(basename "$f"): $(du -h "$f" | cut -f1)"
        done
    fi
fi

exit $ISSUES
