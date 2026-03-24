#!/usr/bin/env bash
# harness.sh — Main orchestrator for the long-running agent system
#
# Runs Claude in a loop: first an initializer session to set up the project,
# then repeated coding sessions until all features pass or max sessions reached.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/utils.sh"

# ─── Defaults ───────────────────────────────────────────────────────────────

PROJECT_DIR="./project"
MAX_SESSIONS=50
MODEL="sonnet"
ESCALATION_MODEL="opus"
MCP_CONFIG=""
SKIP_INIT=false
DRY_RUN=false
GOAL=""

# ─── Stall Detection & Auto-Escalation ─────────────────────────────────────

STALL_THRESHOLD=3          # consecutive 0-progress sessions before escalation
SKIP_AFTER_ATTEMPTS=5      # skip a feature after this many total failed attempts

# ─── Usage ──────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] "project goal description"

Orchestrates Claude across multiple sessions to build a project incrementally.

Options:
  -d, --dir <path>        Working directory for the project (default: ./project)
  -m, --max-sessions <n>  Maximum number of coding sessions (default: 50)
  -M, --model <model>     Claude model to use (default: sonnet)
  -E, --escalation-model  Model to escalate to on stall (default: opus)
  --stall-threshold <n>   Sessions with 0 progress before escalation (default: 3)
  --skip-after <n>        Skip feature after n failed attempts (default: 5)
  --mcp-config <path>     MCP config file to pass to Claude
  --skip-init             Skip initializer, resume from existing artifacts
  --dry-run               Show what would be executed without running
  -h, --help              Show this help message

Examples:
  $(basename "$0") "Build a REST API for a todo app with Node.js and Express"
  $(basename "$0") -d ./my-app -m 30 "Build a CLI markdown-to-HTML converter in Python"
  $(basename "$0") --skip-init -d ./my-app "Continue building the app"
  $(basename "$0") -M sonnet -E opus --stall-threshold 3 "Build my project"
EOF
    exit 0
}

# ─── Argument Parsing ───────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dir)
            PROJECT_DIR="$2"
            shift 2
            ;;
        -m|--max-sessions)
            MAX_SESSIONS="$2"
            shift 2
            ;;
        -M|--model)
            MODEL="$2"
            shift 2
            ;;
        -E|--escalation-model)
            ESCALATION_MODEL="$2"
            shift 2
            ;;
        --stall-threshold)
            STALL_THRESHOLD="$2"
            shift 2
            ;;
        --skip-after)
            SKIP_AFTER_ATTEMPTS="$2"
            shift 2
            ;;
        --mcp-config)
            MCP_CONFIG="$2"
            shift 2
            ;;
        --skip-init)
            SKIP_INIT=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            log_error "Unknown option: $1"
            echo "Use --help for usage information."
            exit 1
            ;;
        *)
            if [[ -z "$GOAL" ]]; then
                GOAL="$1"
            else
                log_error "Unexpected argument: $1"
                echo "Goal already set to: $GOAL"
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$GOAL" ]]; then
    log_error "No project goal provided."
    echo "Use --help for usage information."
    exit 1
fi

# ─── Clear Nesting Guard ────────────────────────────────────────────────────
# When harness.sh is launched from within a Claude Code session, the CLAUDECODE
# env var is inherited and blocks nested `claude` invocations. Unset it so
# the harness can spawn its own independent Claude sessions.
unset CLAUDECODE 2>/dev/null || true

# ─── Validate Environment ──────────────────────────────────────────────────

if ! command -v claude &>/dev/null; then
    log_error "Claude CLI not found. Install it first: https://docs.anthropic.com/en/docs/claude-code"
    exit 1
fi

if ! command -v jq &>/dev/null; then
    log_error "jq not found. Install it: brew install jq (macOS) or apt install jq (Linux)"
    exit 1
fi

# Validate Claude CLI supports required flags
if ! claude --help 2>&1 | grep -q -- "--effort"; then
    log_error "Claude CLI does not support --effort flag. Update Claude CLI."
    exit 1
fi
if ! claude --help 2>&1 | grep -q -- "--output-format"; then
    log_error "Claude CLI does not support --output-format flag. Update Claude CLI."
    exit 1
fi

# ─── Resolve Paths ──────────────────────────────────────────────────────────

PROJECT_DIR="$(cd "$(dirname "$PROJECT_DIR")" 2>/dev/null && pwd)/$(basename "$PROJECT_DIR")" || {
    # Parent doesn't exist yet, that's OK — we'll create it
    PROJECT_DIR="$(pwd)/$PROJECT_DIR"
}
HARNESS_LOG="$PROJECT_DIR/harness-log.txt"
FEATURES_FILE="$PROJECT_DIR/features.json"

# ─── Prepare Prompt Files ──────────────────────────────────────────────────

# Render a prompt template by replacing placeholders
render_prompt() {
    local template_file="$1"
    local output
    output=$(cat "$template_file")
    output="${output//\{\{GOAL\}\}/$GOAL}"
    output="${output//\{\{PROJECT_DIR\}\}/$PROJECT_DIR}"
    echo "$output"
}

# ─── Dry Run ────────────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == true ]]; then
    log_header "DRY RUN"
    echo "Goal:              $GOAL"
    echo "Project dir:       $PROJECT_DIR"
    echo "Max sessions:      $MAX_SESSIONS"
    echo "Model:             $MODEL"
    echo "Escalation model:  $ESCALATION_MODEL"
    echo "Stall threshold:   $STALL_THRESHOLD sessions"
    echo "Skip after:        $SKIP_AFTER_ATTEMPTS attempts"
    echo "MCP config:        ${MCP_CONFIG:-none}"
    echo "Skip init:         $SKIP_INIT"
    echo ""

    if [[ "$SKIP_INIT" == false ]]; then
        echo "Step 1: Would run initializer session"
        echo "  Prompt: $SCRIPT_DIR/prompts/initializer.md"
        echo "  Creates: init.sh, features.json, claude-progress.txt, .git/"
        echo ""
    fi

    echo "Step 2: Would loop up to $MAX_SESSIONS coding sessions"
    echo "  Prompt: $SCRIPT_DIR/prompts/coding.md"
    echo "  Each session: pick 1 feature → implement → test → update artifacts → commit"
    echo ""

    echo "Claude command that would be used:"
    echo "  claude -p <prompt> --model $MODEL --output-format stream-json --dangerously-skip-permissions"
    if [[ -n "$MCP_CONFIG" ]]; then
        echo "  --mcp-config $MCP_CONFIG"
    fi

    exit 0
fi

# ─── Create Project Directory ──────────────────────────────────────────────

mkdir -p "$PROJECT_DIR"

log_header "Long-Running Agent Harness"
echo "Goal:         $GOAL"
echo "Project dir:  $PROJECT_DIR"
echo "Max sessions: $MAX_SESSIONS"
echo "Model:        $MODEL"
echo ""

# Initialize harness log (append on resume, create on fresh start)
if [[ "$SKIP_INIT" == true && -f "$HARNESS_LOG" ]]; then
    echo "" >> "$HARNESS_LOG"
    echo "=== Resumed: $(date -u '+%Y-%m-%dT%H:%M:%SZ') Model: $MODEL ===" >> "$HARNESS_LOG"
else
    echo "=== Harness Log ===" > "$HARNESS_LOG"
    echo "Goal: $GOAL" >> "$HARNESS_LOG"
    echo "Started: $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$HARNESS_LOG"
    echo "Model: $MODEL" >> "$HARNESS_LOG"
fi

# ─── Build Extra Args ──────────────────────────────────────────────────────

EXTRA_ARGS=()
REASONING_EFFORT="medium"   # default for normal coding sessions
if [[ -n "$MCP_CONFIG" ]]; then
    EXTRA_ARGS+=(--mcp-config "$MCP_CONFIG")
fi

# ─── Phase 1: Initializer ──────────────────────────────────────────────────

if [[ "$SKIP_INIT" == false ]]; then
    log_header "Phase 1: Initializer Session"

    if validate_artifacts "$PROJECT_DIR" 2>/dev/null; then
        log_warn "Artifacts already exist in $PROJECT_DIR"
        log_warn "Use --skip-init to resume, or remove the directory to start fresh."
        exit 1
    fi

    # Render the initializer prompt
    INIT_PROMPT_FILE=$(mktemp)
    render_prompt "$SCRIPT_DIR/prompts/initializer.md" > "$INIT_PROMPT_FILE"

    INIT_START=$(date +%s)

    # Phase 1 uses the strongest model with max effort and extended timeout.
    # The initializer does the most critical architectural work: goal analysis,
    # feature decomposition (20-200 features), scaffold creation.
    # Poor planning here cascades into every subsequent session.
    INIT_MODEL="$ESCALATION_MODEL"
    export SESSION_TIMEOUT=3600   # 1 hour wall-clock for planning
    export IDLE_TIMEOUT=600       # 10 min idle (planning involves long thinking)

    log_info "Starting initializer session... (model: $INIT_MODEL, effort: max, timeout: 1h)"

    # ── Phase 1 stall watchdog: warn user at 30 min ──
    (
        sleep 1800  # 30 minutes
        if kill -0 $$ 2>/dev/null; then  # harness still running = init not done
            notify_user "Harness: Phase 1 Slow" \
                "Initializer running >30min. May be stuck. Check terminal." \
                "critical"
            log_warn "Phase 1 has been running for 30 minutes — check for issues"
        fi
    ) &
    INIT_WATCHDOG_PID=$!

    init_exit=0
    run_claude_session "$INIT_PROMPT_FILE" "$PROJECT_DIR" "$INIT_MODEL" --effort max ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} || init_exit=$?
    rm -f "$INIT_PROMPT_FILE"

    # Kill the 30-min watchdog (init finished before 30 min)
    kill "$INIT_WATCHDOG_PID" 2>/dev/null || true
    wait "$INIT_WATCHDOG_PID" 2>/dev/null || true

    INIT_END=$(date +%s)
    INIT_DURATION=$(( INIT_END - INIT_START ))

    if [[ $init_exit -ne 0 ]]; then
        log_error "Initializer session failed (exit code: $init_exit, duration: ${INIT_DURATION}s)"
        log_session "$HARNESS_LOG" 0 0 0 "$INIT_DURATION" "$init_exit"
        notify_user "Harness: Phase 1 Failed" \
            "Initializer failed after ${INIT_DURATION}s (exit $init_exit). Check terminal." \
            "critical"
        exit 1
    fi

    # Validate init.sh safety — block dangerous patterns before they waste hours
    if [[ -f "$PROJECT_DIR/init.sh" ]]; then
        if grep -qE '&\s*$' "$PROJECT_DIR/init.sh" && ! grep -qE '>/dev/null.*&|&>/dev/null' "$PROJECT_DIR/init.sh"; then
            log_error "init.sh contains background processes without output redirection."
            log_error "This WILL block Claude's Bash tool. Fix: remove '&' or add '> /dev/null 2>&1 &'"
            notify_user "Harness: Dangerous init.sh" \
                "init.sh has background processes that will hang. Fix before continuing." \
                "critical"
            exit 1
        fi
    fi

    # Validate that artifacts were created
    if ! validate_artifacts "$PROJECT_DIR"; then
        log_error "Initializer session completed but artifacts are missing."
        log_error "Expected: init.sh, features.json, claude-progress.txt, .git/"
        notify_user "Harness: Phase 1 Incomplete" \
            "Initializer finished but artifacts missing. Check terminal." \
            "critical"
        exit 1
    fi

    # Check initial feature count
    read -r passed total <<< "$(check_features_progress "$FEATURES_FILE")"
    log_success "Initializer complete. Features: $passed/$total $(progress_bar "$passed" "$total")"
    log_session "$HARNESS_LOG" 0 "$passed" "$total" "$INIT_DURATION" 0
    notify_user "Harness: Phase 1 Done" \
        "Initializer complete in ${INIT_DURATION}s. $total features planned. Starting coding loop." \
        "normal"

else
    log_info "Skipping initializer (--skip-init)"
    if ! validate_artifacts "$PROJECT_DIR"; then
        log_error "Cannot skip init: artifacts are missing in $PROJECT_DIR"
        exit 1
    fi
    read -r passed total <<< "$(check_features_progress "$FEATURES_FILE")"
    log_info "Resuming with $passed/$total features passing"
fi

# ─── Helper: Get Current Target Feature Priority ─────────────────────────

get_target_feature_priority() {
    local features_file="$1"
    jq -r '
        [.features[] | select(.passes == false)]
        | sort_by(.priority // 999, .id)
        | .[0].priority // 999
    ' "$features_file" 2>/dev/null || echo 999
}

get_target_feature_id() {
    local features_file="$1"
    jq -r '
        [.features[] | select(.passes == false)]
        | sort_by(.priority // 999, .id)
        | .[0].id // "unknown"
    ' "$features_file" 2>/dev/null || echo "unknown"
}

# ─── Helper: Dynamic Timeout Based on Feature Priority ────────────────────

compute_session_timeout() {
    local priority="$1"
    case "$priority" in
        1) echo 1800 ;;    # 30 min for simple features
        2) echo 3600 ;;    # 60 min for medium features
        3) echo 5400 ;;    # 90 min for complex features
        *)  echo 7200 ;;   # 120 min for hard/edge features
    esac
}

# ─── Helper: Skip Feature in features.json ────────────────────────────────

skip_feature() {
    local features_file="$1"
    local feature_id="$2"

    # Record skip in a sidecar file
    local skip_file="${features_file%.json}.skipped.json"
    if [[ ! -f "$skip_file" ]]; then
        echo '{}' > "$skip_file"
    fi
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    jq --arg id "$feature_id" --arg ts "$timestamp" \
        '.[$id] = {skipped_at: $ts}' "$skip_file" > "${skip_file}.tmp" \
        && mv "${skip_file}.tmp" "$skip_file"

    # Mark as passes: true with a skip marker in features.json so harness moves on
    # We use a temp file to safely edit
    jq --arg id "$feature_id" '
        .features = [.features[] |
            if .id == $id then .passes = true | .skipped = true
            else . end
        ]
    ' "$features_file" > "${features_file}.tmp" \
        && mv "${features_file}.tmp" "$features_file"

    log_warn "Skipped $feature_id — marked as passes:true (skipped) to unblock progress"
}

# ─── Helper: Count Attempts for a Feature in Progress Log ─────────────────

count_feature_attempts() {
    local progress_file="$1"
    local feature_id="$2"
    if [[ ! -f "$progress_file" ]]; then
        echo 0
        return
    fi
    local count
    count=$(grep -c -E "FAILED.*${feature_id}|${feature_id}.*FAILED|Session.*${feature_id}" "$progress_file" 2>/dev/null) || count=0
    echo "$count"
}

# ─── Pre-flight Safety Check ──────────────────────────────────────────────

if [[ -f "$SCRIPT_DIR/lib/preflight.sh" ]]; then
    log_info "Running pre-flight checks..."
    if ! bash "$SCRIPT_DIR/lib/preflight.sh" "$PROJECT_DIR"; then
        log_error "Pre-flight check failed. Fix issues above before continuing."
        notify_user "Harness: Pre-flight Failed" \
            "Safety issues found in project. Check terminal." \
            "critical"
        exit 1
    fi
    log_success "Pre-flight checks passed."
fi

# ─── Phase 2: Coding Loop ──────────────────────────────────────────────────

log_header "Phase 2: Coding Sessions"

SESSION=1
CONSECUTIVE_FAILURES=0
MAX_CONSECUTIVE_FAILURES=5
BACKOFF_BASE=30  # seconds

# Stall detection state
STALL_COUNT=0
PREV_PASSED=0
INITIAL_MODEL="$MODEL"
read -r PREV_PASSED _ <<< "$(check_features_progress "$FEATURES_FILE")"

while [[ $SESSION -le $MAX_SESSIONS ]]; do
    # Check progress before starting
    read -r passed total <<< "$(check_features_progress "$FEATURES_FILE")"

    if [[ "$total" -gt 0 && "$passed" -ge "$total" ]]; then
        log_header "ALL FEATURES PASSING!"
        log_success "All $total features are passing after $((SESSION - 1)) coding sessions."
        echo "completed" >> "$HARNESS_LOG"
        notify_user "Harness: Project Complete!" \
            "All $total features passing after $((SESSION - 1)) sessions." \
            "normal"
        break
    fi

    remaining=$(( total - passed ))
    target_id=$(get_target_feature_id "$FEATURES_FILE")
    target_pri=$(get_target_feature_priority "$FEATURES_FILE")

    log_header "Coding Session $SESSION / $MAX_SESSIONS"
    echo "Progress: $(progress_bar "$passed" "$total")  ($remaining remaining)"
    echo "Target:   $target_id (priority $target_pri)"
    echo "Model:    $MODEL"
    echo ""

    # ── Skip feature if too many attempts ──
    PROGRESS_FILE="$PROJECT_DIR/claude-progress.txt"
    attempts=$(count_feature_attempts "$PROGRESS_FILE" "$target_id")
    if [[ "$attempts" -ge "$SKIP_AFTER_ATTEMPTS" ]]; then
        log_warn "$target_id has $attempts failed attempts (threshold: $SKIP_AFTER_ATTEMPTS)"
        skip_feature "$FEATURES_FILE" "$target_id"
        echo "--- Session $SESSION [$(date -u '+%Y-%m-%dT%H:%M:%SZ')] --- SKIPPED $target_id after $attempts attempts" >> "$HARNESS_LOG"
        SESSION=$(( SESSION + 1 ))
        continue
    fi

    # ── Dynamic timeout and model based on session ──
    if [[ "$SESSION" -eq 1 ]]; then
        # First coding session uses strongest model — it sets up the foundation
        # (package refactors, core models) that all subsequent sessions depend on.
        SESSION_MODEL="$ESCALATION_MODEL"
        SESSION_EFFORT="high"
        export SESSION_TIMEOUT=3600  # 1 hour for first coding session
        export IDLE_TIMEOUT=600      # 10 min idle (complex setup)
        log_info "Session 1: $SESSION_MODEL, effort $SESSION_EFFORT, timeout 1h"
    else
        SESSION_MODEL="$MODEL"
        SESSION_EFFORT="$REASONING_EFFORT"
        export SESSION_TIMEOUT=$(compute_session_timeout "$target_pri")
        export IDLE_TIMEOUT=300  # 5 min idle → kill stuck sessions faster
        log_info "Timeout: ${SESSION_TIMEOUT}s (priority $target_pri)"
    fi

    # Render the coding prompt
    CODING_PROMPT_FILE=$(mktemp)
    render_prompt "$SCRIPT_DIR/prompts/coding.md" > "$CODING_PROMPT_FILE"

    SESSION_START=$(date +%s)

    log_info "Model: $SESSION_MODEL, Effort: $SESSION_EFFORT"
    session_exit=0
    run_claude_session "$CODING_PROMPT_FILE" "$PROJECT_DIR" "$SESSION_MODEL" --effort "$SESSION_EFFORT" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} || session_exit=$?
    rm -f "$CODING_PROMPT_FILE"

    SESSION_END=$(date +%s)
    SESSION_DURATION=$(( SESSION_END - SESSION_START ))

    # Re-read progress after session
    read -r passed total <<< "$(check_features_progress "$FEATURES_FILE")"

    if [[ $session_exit -ne 0 ]]; then
        log_warn "Session $SESSION exited with code $session_exit (duration: ${SESSION_DURATION}s)"
        CONSECUTIVE_FAILURES=$(( CONSECUTIVE_FAILURES + 1 ))

        # If session failed very quickly (<10s), it's likely a rate limit or API error
        if [[ $SESSION_DURATION -lt 10 ]]; then
            wait_time=$(( BACKOFF_BASE * CONSECUTIVE_FAILURES ))
            if [[ $wait_time -gt 300 ]]; then
                wait_time=300  # cap at 5 minutes
            fi
            log_warn "Session failed in <10s — likely rate limited. Waiting ${wait_time}s before retry..."
            sleep "$wait_time"
        fi

        # Bail out after too many consecutive failures
        if [[ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]]; then
            log_error "$MAX_CONSECUTIVE_FAILURES consecutive failures. Stopping to avoid wasting sessions."
            log_error "Check API rate limits or errors, then resume with --skip-init."
            log_session "$HARNESS_LOG" "$SESSION" "$passed" "$total" "$SESSION_DURATION" "$session_exit"
            notify_user "Harness: Stopped" \
                "$MAX_CONSECUTIVE_FAILURES consecutive failures. $passed/$total done. Check terminal." \
                "critical"
            break
        fi
    else
        CONSECUTIVE_FAILURES=0
    fi

    # ── Stall Detection & Auto-Escalation ──
    if [[ "$passed" -le "$PREV_PASSED" ]]; then
        STALL_COUNT=$(( STALL_COUNT + 1 ))
        log_warn "No progress: stall count $STALL_COUNT/$STALL_THRESHOLD (stuck on $target_id)"

        if [[ $STALL_COUNT -ge $STALL_THRESHOLD ]]; then
            if [[ "$MODEL" != "$ESCALATION_MODEL" ]]; then
                log_warn "Stalled for $STALL_COUNT sessions. Escalating: $MODEL → $ESCALATION_MODEL, effort: medium → high"
                MODEL="$ESCALATION_MODEL"
                REASONING_EFFORT="high"
                echo "--- Escalated to $MODEL (effort: high) after $STALL_COUNT stalled sessions on $target_id ---" >> "$HARNESS_LOG"
                STALL_COUNT=0
            else
                log_warn "Already on $ESCALATION_MODEL and still stalled. Will skip $target_id after $SKIP_AFTER_ATTEMPTS total attempts."
            fi
        fi
    else
        # Progress made — reset stall counter; downgrade model if we escalated and feature cleared
        if [[ "$MODEL" != "$INITIAL_MODEL" && $STALL_COUNT -eq 0 ]]; then
            log_info "Progress resumed. Downgrading: $MODEL → $INITIAL_MODEL, effort: high → medium"
            MODEL="$INITIAL_MODEL"
            REASONING_EFFORT="medium"
            echo "--- Downgraded to $MODEL (effort: medium) after progress resumed ---" >> "$HARNESS_LOG"
        fi
        STALL_COUNT=0
    fi
    PREV_PASSED=$passed

    log_info "Session $SESSION complete in ${SESSION_DURATION}s. Features: $passed/$total $(progress_bar "$passed" "$total")"
    log_session "$HARNESS_LOG" "$SESSION" "$passed" "$total" "$SESSION_DURATION" "$session_exit"

    SESSION=$(( SESSION + 1 ))
done

# ─── Final Summary ──────────────────────────────────────────────────────────

read -r passed total <<< "$(check_features_progress "$FEATURES_FILE")"

log_header "Final Summary"
echo "Features passing: $passed / $total  $(progress_bar "$passed" "$total")"
echo "Sessions used:    $((SESSION - 1))"
echo "Final model:      $MODEL (started as $INITIAL_MODEL)"
escalation_count=$(grep -c "^--- Escalated" "$HARNESS_LOG" 2>/dev/null || echo 0)
skip_count=$(grep -c "SKIPPED" "$HARNESS_LOG" 2>/dev/null || echo 0)
if [[ "$escalation_count" -gt 0 ]]; then
    echo "Escalations:      $escalation_count"
fi
if [[ "$skip_count" -gt 0 ]]; then
    echo "Features skipped: $skip_count"
fi
echo "Harness log:      $HARNESS_LOG"
echo "Project dir:      $PROJECT_DIR"

if [[ "$passed" -ge "$total" && "$total" -gt 0 ]]; then
    log_success "Project complete!"
    exit 0
else
    log_warn "Project incomplete. $((total - passed)) features remaining."
    log_warn "Re-run with: $(basename "$0") --skip-init -d \"$PROJECT_DIR\" \"$GOAL\""
    exit 1
fi
