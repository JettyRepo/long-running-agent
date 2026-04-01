#!/usr/bin/env bash
# utils.sh — Shared utility functions for the long-running agent harness

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# ─── User Notification ────────────────────────────────────────────────────
# Cross-platform: macOS (osascript + say), Linux (notify-send), fallback (bell)

notify_user() {
    local title="$1"
    local message="$2"
    local urgency="${3:-normal}"  # normal | critical

    # Sanitize for osascript: remove chars that break AppleScript strings
    local safe_title="${title//\!/}"
    local safe_message="${message//\!/}"

    # macOS
    if command -v osascript &>/dev/null; then
        osascript -e "display notification \"$safe_message\" with title \"$safe_title\" sound name \"Glass\"" 2>/dev/null || true
        if [[ "$urgency" == "critical" ]]; then
            say -v Samantha "Harness alert: $safe_message" &>/dev/null &
        fi
    # Linux
    elif command -v notify-send &>/dev/null; then
        notify-send -u "$urgency" "$title" "$message" 2>/dev/null || true
    fi

    # Terminal bell (always)
    printf '\a'
}

log_header() {
    echo ""
    echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  $*${NC}"
    echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""
}

# Parse features.json and return "passed/total" counts
# Usage: check_features_progress /path/to/features.json
# Output: "passed total" (space-separated)
check_features_progress() {
    local features_file="$1"

    if [[ ! -f "$features_file" ]]; then
        echo "0 0"
        return 1
    fi

    local total passed
    total=$(jq '[.features[]] | length' "$features_file" 2>/dev/null || echo 0)
    passed=$(jq '[.features[] | select(.passes == true)] | length' "$features_file" 2>/dev/null || echo 0)

    echo "$passed $total"
}

# Append a session summary to the harness-level log
# Usage: log_session <log_file> <session_num> <passed> <total> <duration_secs> <exit_code>
log_session() {
    local log_file="$1"
    local session_num="$2"
    local passed="$3"
    local total="$4"
    local duration="$5"
    local exit_code="$6"

    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local status="success"
    if [[ "$exit_code" -ne 0 ]]; then
        status="error (exit $exit_code)"
    fi

    cat >> "$log_file" <<EOF

--- Session $session_num [$timestamp] ---
Status: $status
Duration: ${duration}s
Features: $passed/$total passing
EOF
}

# Run a Claude session with the appropriate flags
# Usage: run_claude_session <prompt_file> <project_dir> <model> [extra_args...]
#
# A1: tmpfile + tail -f (no FIFO backpressure)
# A2: single jq per line (5→1 fork reduction)
# A3: process group kill via kill -- -PGID (clean child cleanup)
#
run_claude_session() {
    local prompt_file="$1"
    local project_dir="$2"
    local model="$3"
    shift 3
    local extra_args=()
    if [[ $# -gt 0 ]]; then
        extra_args=("$@")
    fi

    local prompt_content
    prompt_content=$(cat "$prompt_file")

    local cmd=(
        claude
        -p "$prompt_content"
        --model "$model"
        --verbose
        --output-format stream-json
        --dangerously-skip-permissions
    )

    # Add any extra args (e.g., --mcp-config)
    if [[ ${#extra_args[@]} -gt 0 ]]; then
        cmd+=("${extra_args[@]}")
    fi

    log_info "Running Claude session in $project_dir"
    log_info "Model: $model"
    log_info "Prompt: $prompt_file"

    local prev_dir
    prev_dir=$(pwd)
    cd "$project_dir"

    # --- Timeout Configuration ---
    local SESSION_TIMEOUT="${SESSION_TIMEOUT:-3600}"   # 60 min max wall-clock time
    local IDLE_TIMEOUT="${IDLE_TIMEOUT:-3600}"          # 60 min max with no output

    # Activity tracking for idle watchdog
    local activity_file
    activity_file=$(mktemp)
    touch "$activity_file"

    # --- A1: tmpfile replaces FIFO (no backpressure) ---
    local output_tmpfile
    output_tmpfile=$(mktemp)

    # --- A3: Variables for process group cleanup ---
    local claude_pid=""
    local claude_pgid=""
    local watchdog_pid=""
    local tail_pid=""

    # Trap to clean up on unexpected exit (SIGINT, SIGTERM, ERR)
    _session_cleanup() {
        local _wpid="${watchdog_pid:-}"
        local _tpid="${tail_pid:-}"
        local _cpid="${claude_pid:-}"
        local _cpgid="${claude_pgid:-}"

        # Kill watchdog
        if [[ -n "$_wpid" ]]; then
            kill "$_wpid" 2>/dev/null || true
            wait "$_wpid" 2>/dev/null || true
        fi

        # Kill tail reader
        if [[ -n "$_tpid" ]]; then
            kill "$_tpid" 2>/dev/null || true
            wait "$_tpid" 2>/dev/null || true
        fi

        # A3: Kill entire process group (catches gradle/node/etc.)
        if [[ -n "$_cpgid" ]] && [[ "$_cpgid" != "0" ]]; then
            kill -TERM -- "-$_cpgid" 2>/dev/null || true
            sleep 1
            kill -KILL -- "-$_cpgid" 2>/dev/null || true
        elif [[ -n "$_cpid" ]]; then
            kill "$_cpid" 2>/dev/null || true
        fi

        [[ -n "$_cpid" ]] && wait "$_cpid" 2>/dev/null || true

        rm -f "${output_tmpfile:-}" "${activity_file:-}"
    }
    trap _session_cleanup EXIT

    # --- Real-time session log for monitor ---
    local session_log="$project_dir/.harness-live.jsonl"
    : > "$session_log"  # truncate

    # --- C: State file for monitor (overwritten each event) ---
    local state_file="$project_dir/.harness-state.json"
    echo '{}' > "$state_file"

    # State tracking
    local _st_thinking="" _st_tool="" _st_detail="" _st_result="" _st_err="false"

    _write_state() {
        jq -n \
            --arg thinking "${_st_thinking:0:500}" \
            --arg tool "$_st_tool" \
            --arg detail "${_st_detail:0:200}" \
            --arg result "${_st_result:0:300}" \
            --arg error "$_st_err" \
            '{thinking:$thinking,tool:$tool,detail:$detail,result:$result,error:$error}' \
            > "${state_file}.tmp" 2>/dev/null && mv "${state_file}.tmp" "$state_file" || true
    }

    # --- A1+A3: Start Claude with output to tmpfile, in new process group ---
    set -m  # enable job control for process groups
    "${cmd[@]}" > "$output_tmpfile" 2>&1 &
    claude_pid=$!
    # Get process group ID (macOS + Linux compatible)
    claude_pgid=$(ps -o pgid= -p "$claude_pid" 2>/dev/null | tr -d ' ' || echo "")
    set +m  # restore

    log_info "Claude PID: $claude_pid, PGID: ${claude_pgid:-unknown}"

    # --- B: Write tmpfile path for monitor direct reading ---
    echo "$output_tmpfile" > "$project_dir/.harness-tmpfile"

    # --- Watchdog: checked every 15s (was 60s) ---
    (
        local start_time
        start_time=$(date +%s)
        while kill -0 "$claude_pid" 2>/dev/null; do
            sleep 15
            local now
            now=$(date +%s)

            # Check hard wall-clock timeout
            local elapsed=$(( now - start_time ))
            if [[ $elapsed -gt $SESSION_TIMEOUT ]]; then
                echo -e "${YELLOW}[WARN]${NC} Watchdog: session exceeded ${SESSION_TIMEOUT}s wall-clock limit, killing PGID=${claude_pgid}" >&2
                if [[ -n "$claude_pgid" ]] && [[ "$claude_pgid" != "0" ]]; then
                    kill -TERM -- "-$claude_pgid" 2>/dev/null || true
                    sleep 1
                    kill -KILL -- "-$claude_pgid" 2>/dev/null || true
                else
                    kill "$claude_pid" 2>/dev/null || true
                fi
                break
            fi

            # Check idle timeout (no output for IDLE_TIMEOUT seconds)
            if [[ -f "$activity_file" ]]; then
                local last_mod idle_secs
                last_mod=$(stat -f %m "$activity_file" 2>/dev/null \
                        || stat -c %Y "$activity_file" 2>/dev/null \
                        || echo 0)
                idle_secs=$(( now - last_mod ))
                if [[ $idle_secs -gt $IDLE_TIMEOUT ]]; then
                    echo -e "${YELLOW}[WARN]${NC} Watchdog: no output for ${idle_secs}s (limit: ${IDLE_TIMEOUT}s), killing PGID=${claude_pgid}" >&2
                    if [[ -n "$claude_pgid" ]] && [[ "$claude_pgid" != "0" ]]; then
                        kill -TERM -- "-$claude_pgid" 2>/dev/null || true
                        sleep 1
                        kill -KILL -- "-$claude_pgid" 2>/dev/null || true
                    else
                        kill "$claude_pid" 2>/dev/null || true
                    fi
                    break
                fi
            fi
        done
    ) &
    watchdog_pid=$!

    # --- A1: Read via tail -f (no backpressure on Claude) ---
    local exit_code=0
    tail -f "$output_tmpfile" &
    tail_pid=$!

    # Parse stream-json from tmpfile: poll until Claude exits
    local last_pos=0
    while kill -0 "$claude_pid" 2>/dev/null || [[ $(wc -c < "$output_tmpfile") -gt $last_pos ]]; do
        local current_size
        current_size=$(wc -c < "$output_tmpfile")

        if [[ $current_size -le $last_pos ]]; then
            sleep 0.5
            continue
        fi

        # Read new lines since last_pos
        while IFS= read -r line; do
            touch "$activity_file"  # record activity for watchdog

            # Fast-path: skip non-JSON lines
            if [[ "$line" != *'"type"'* ]]; then
                continue
            fi

            local ts
            ts=$(date '+%H:%M:%S')

            # Single jq: extract ALL fields including tool inputs and tool results
            local parsed
            parsed=$(echo "$line" | jq -r '
                .type as $t |
                if $t == "assistant" then
                    [
                        $t,
                        ([.message.content[]? | select(.type == "text") | .text] | join(" ") | .[0:200]),
                        ([.message.content[]? | select(.type == "tool_use") | .name] | join(",")),
                        (.message.usage.input_tokens // 0 | tostring),
                        (.message.usage.output_tokens // 0 | tostring),
                        "",
                        ([.message.content[]? | select(.type == "thinking") | .thinking] | join(" ") | .[0:500]),
                        ([.message.content[]? | select(.type == "tool_use") |
                            .name as $n |
                            if $n == "Bash" then ($n + ": " + (.input.command // "" | .[0:120]))
                            elif $n == "Read" then ($n + ": " + (.input.file_path // ""))
                            elif $n == "Edit" then ($n + ": " + (.input.file_path // ""))
                            elif $n == "Write" then ($n + ": " + (.input.file_path // ""))
                            elif $n == "Grep" then ($n + ": " + (.input.pattern // "") + " in " + (.input.path // "."))
                            elif $n == "Glob" then ($n + ": " + (.input.pattern // ""))
                            else $n
                            end
                        ] | join(" | ") | .[0:250]),
                        ""
                    ]
                elif $t == "user" then
                    [
                        $t,
                        ([.message.content[]? | select(.type == "tool_result") |
                            (.content // "") | tostring | .[0:300]
                        ] | join("\n") | .[0:400]),
                        ([.message.content[]? | select(.type == "tool_result") |
                            if .is_error == true then "true" else "false" end
                        ] | join(",") | .[0:20]),
                        "0", "0", "", "", "", ""
                    ]
                elif $t == "result" then
                    [
                        $t, "", "",
                        (.usage.input_tokens // 0 | tostring),
                        (.usage.output_tokens // 0 | tostring),
                        (.is_error // false | tostring),
                        "", "", ""
                    ]
                else
                    [$t, "", "", "0", "0", "", "", "", ""]
                end | @tsv
            ' 2>/dev/null || true)

            if [[ -z "$parsed" ]]; then continue; fi

            local msg_type text tool_names input_tokens output_tokens is_error thinking tool_detail result_content
            IFS=$'\t' read -r msg_type text tool_names input_tokens output_tokens is_error thinking tool_detail result_content <<< "$parsed"

            # Sanitize numerics
            [[ "${input_tokens:-}" =~ ^[0-9]+$ ]] || input_tokens=0
            [[ "${output_tokens:-}" =~ ^[0-9]+$ ]] || output_tokens=0

            case "$msg_type" in
                assistant)
                    # Write rich JSONL entry
                    jq -n --arg ts "$ts" --arg text "${text:0:150}" \
                        --arg tools "${tool_names:-}" --arg thinking "${thinking:0:500}" \
                        --arg detail "${tool_detail:0:250}" \
                        --argjson in "$input_tokens" --argjson out "$output_tokens" \
                        '{ts:$ts,type:"assistant",input_tokens:$in,output_tokens:$out,tools:$tools,detail:$detail,text:$text,thinking:$thinking}' \
                        >> "$session_log"

                    # Update state (C)
                    [[ -n "$thinking" ]] && _st_thinking="$thinking"
                    [[ -n "$tool_names" ]] && _st_tool="$tool_names"
                    [[ -n "$tool_detail" ]] && _st_detail="$tool_detail"
                    _write_state

                    # Console output
                    if [[ -n "$thinking" ]]; then
                        echo -e "${BOLD}[Think]${NC} ${thinking:0:120}"
                    fi
                    if [[ -n "$text" ]]; then
                        echo -e "${BLUE}[Claude]${NC} ${text:0:200}"
                    fi
                    if [[ -n "$tool_detail" ]]; then
                        echo -e "${YELLOW}[Tool]${NC} $tool_detail"
                    elif [[ -n "$tool_names" ]]; then
                        echo -e "${YELLOW}[Tool]${NC} $tool_names"
                    fi
                    ;;
                user)
                    # Tool result — write to live log + update state
                    local result_snippet="${text:0:300}"
                    local result_err="false"
                    [[ "${tool_names:-}" == *"true"* ]] && result_err="true"

                    jq -n --arg ts "$ts" --arg result "${result_snippet:0:300}" \
                        --arg error "$result_err" \
                        '{ts:$ts,type:"tool_result",result:$result,error:$error}' \
                        >> "$session_log"

                    # Update state (C)
                    _st_result="${result_snippet:0:300}"
                    _st_err="$result_err"
                    _write_state

                    # Show errors in console
                    if [[ "$result_err" == "true" ]]; then
                        echo -e "${RED}[Error]${NC} ${result_snippet:0:100}"
                    fi
                    ;;
                result)
                    local safe_err="false"
                    [[ "${is_error:-}" == "true" ]] && safe_err="true"
                    jq -n --arg ts "$ts" \
                        --argjson in "$input_tokens" --argjson out "$output_tokens" \
                        --argjson err "$safe_err" \
                        '{ts:$ts,type:"result",is_error:$err,input_tokens:$in,output_tokens:$out}' \
                        >> "$session_log"

                    if [[ "$is_error" == "true" ]]; then
                        log_error "Session ended with error"
                    else
                        log_info "Session completed successfully."
                    fi
                    ;;
                *)
                    if [[ -n "$msg_type" ]]; then
                        jq -n --arg ts "$ts" --arg type "$msg_type" \
                            '{ts:$ts,type:$type}' >> "$session_log"
                    fi
                    ;;
            esac
        done < <(tail -c +"$((last_pos + 1))" "$output_tmpfile" 2>/dev/null)

        last_pos=$current_size
        sleep 0.3
    done

    # Save output for rate limit detection (before cleanup removes tmpfile)
    tail -200 "$output_tmpfile" > "$project_dir/.harness-last-output.txt" 2>/dev/null || true

    # Process remaining output after Claude exits
    local final_size
    final_size=$(wc -c < "$output_tmpfile")
    if [[ $final_size -gt $last_pos ]]; then
        while IFS= read -r line; do
            if [[ "$line" != *'"type"'* ]]; then continue; fi
            local ts
            ts=$(date '+%H:%M:%S')
            local parsed
            parsed=$(echo "$line" | jq -r '
                .type as $t |
                if $t == "result" then
                    [$t, "", "", (.usage.input_tokens // 0 | tostring), (.usage.output_tokens // 0 | tostring), (.is_error // false | tostring)]
                else
                    [$t, "", "", "0", "0", ""]
                end | @tsv
            ' 2>/dev/null || true)
            if [[ -n "$parsed" ]]; then
                local msg_type text tool_names input_tokens output_tokens is_error
                IFS=$'\t' read -r msg_type text tool_names input_tokens output_tokens is_error <<< "$parsed"
                [[ "${input_tokens:-}" =~ ^[0-9]+$ ]] || input_tokens=0
                [[ "${output_tokens:-}" =~ ^[0-9]+$ ]] || output_tokens=0
                if [[ "$msg_type" == "result" ]]; then
                    local safe_err="false"
                    [[ "${is_error:-}" == "true" ]] && safe_err="true"
                    jq -n --arg ts "$ts" \
                        --argjson in "$input_tokens" --argjson out "$output_tokens" \
                        --argjson err "$safe_err" \
                        '{ts:$ts,type:"result",is_error:$err,input_tokens:$in,output_tokens:$out}' \
                        >> "$session_log"
                    if [[ "$is_error" == "true" ]]; then
                        log_error "Session ended with error"
                    else
                        log_info "Session completed successfully."
                    fi
                fi
            fi
        done < <(tail -c +"$((last_pos + 1))" "$output_tmpfile" 2>/dev/null)
    fi

    # --- Cleanup ---
    # Kill tail reader
    kill "$tail_pid" 2>/dev/null || true
    wait "$tail_pid" 2>/dev/null || true

    # A3: Kill entire process group
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    if [[ -n "$claude_pgid" ]] && [[ "$claude_pgid" != "0" ]]; then
        kill -TERM -- "-$claude_pgid" 2>/dev/null || true
        sleep 1
        kill -KILL -- "-$claude_pgid" 2>/dev/null || true
    else
        kill "$claude_pid" 2>/dev/null || true
    fi
    wait "$claude_pid" 2>/dev/null && exit_code=0 || exit_code=$?
    rm -f "$output_tmpfile" "$activity_file"

    # Remove the EXIT trap so it doesn't fire again
    trap - EXIT

    cd "$prev_dir"
    return $exit_code
}

# Validate that required artifacts exist in the project directory
# Usage: validate_artifacts <project_dir>
# Returns 0 if all artifacts exist, 1 otherwise
validate_artifacts() {
    local project_dir="$1"
    local missing=0

    for artifact in init.sh features.json claude-progress.txt; do
        if [[ ! -f "$project_dir/$artifact" ]]; then
            log_warn "Missing artifact: $artifact"
            missing=1
        fi
    done

    if [[ ! -d "$project_dir/.git" ]]; then
        log_warn "Missing git repository in $project_dir"
        missing=1
    fi

    return $missing
}

# ─── Rate Limit Detection & Auto-Wait ────────────────────────────────────

# Detect rate limit from Claude session output
# Usage: detect_rate_limit <output_file> <project_dir>
# Returns 0 if rate limit detected (writes .harness-ratelimit.json), 1 otherwise
detect_rate_limit() {
    local output_file="$1"
    local project_dir="$2"
    local rl_file="$project_dir/.harness-ratelimit.json"

    rm -f "$rl_file"

    if [[ ! -f "$output_file" || ! -s "$output_file" ]]; then
        return 1
    fi

    # Search for rate limit indicators in the output
    local rl_content=""
    rl_content=$(grep -iE 'rate.limit|rate_limit|429|quota.*exceed|overloaded|too many requests|capacity|try again|usage.limit|billing|credit|throttl' "$output_file" 2>/dev/null | tail -10 || true)

    if [[ -z "$rl_content" ]]; then
        return 1
    fi

    local now_ts
    now_ts=$(date +%s)
    local wait_seconds=0
    local parse_source="none"

    # Pattern 1: "retry-after: N" or "retry after N" (seconds)
    local retry_secs
    retry_secs=$(echo "$rl_content" | grep -oiE 'retry[- _]?after[: ]+([0-9]+)' | grep -oE '[0-9]+' | head -1 || true)
    if [[ -n "$retry_secs" ]] && (( retry_secs > 0 )); then
        wait_seconds=$(( retry_secs + 60 ))
        parse_source="retry-after"
    fi

    # Pattern 2: ISO 8601 timestamp (e.g., 2026-03-31T12:30:00Z)
    if [[ $wait_seconds -eq 0 ]]; then
        local iso_time
        iso_time=$(echo "$rl_content" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[Z]?' | head -1 || true)
        if [[ -n "$iso_time" ]]; then
            local clean_time="${iso_time%Z}"
            local target_ts=0
            # macOS date
            target_ts=$(date -j -f '%Y-%m-%dT%H:%M:%S' "$clean_time" +%s 2>/dev/null || true)
            # Linux date fallback
            if [[ -z "$target_ts" || "$target_ts" == "0" ]]; then
                target_ts=$(date -d "$iso_time" +%s 2>/dev/null || echo 0)
            fi
            if (( target_ts > now_ts )); then
                wait_seconds=$(( target_ts - now_ts + 60 ))
                parse_source="ISO-timestamp"
            fi
        fi
    fi

    # Pattern 3: "in N minutes" / "N minute(s)"
    if [[ $wait_seconds -eq 0 ]]; then
        local mins
        mins=$(echo "$rl_content" | grep -oiE '([0-9]+)\s*minute' | grep -oE '[0-9]+' | head -1 || true)
        if [[ -n "$mins" ]] && (( mins > 0 )); then
            wait_seconds=$(( mins * 60 + 60 ))
            parse_source="minutes-ref"
        fi
    fi

    # Pattern 4: "N seconds" (standalone)
    if [[ $wait_seconds -eq 0 ]]; then
        local secs
        secs=$(echo "$rl_content" | grep -oiE '([0-9]+)\s*second' | grep -oE '[0-9]+' | head -1 || true)
        if [[ -n "$secs" ]] && (( secs > 10 )); then
            wait_seconds=$(( secs + 60 ))
            parse_source="seconds-ref"
        fi
    fi

    # Pattern 5: "at HH:MM" or "until HH:MM:SS" time reference
    if [[ $wait_seconds -eq 0 ]]; then
        local time_ref
        time_ref=$(echo "$rl_content" | grep -oE '(at |until )[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?' | grep -oE '[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?' | head -1 || true)
        if [[ -n "$time_ref" ]]; then
            local target_ts=0
            if [[ "$time_ref" == *:*:* ]]; then
                target_ts=$(date -j -f '%H:%M:%S' "$time_ref" +%s 2>/dev/null || echo 0)
            else
                target_ts=$(date -j -f '%H:%M' "$time_ref" +%s 2>/dev/null || echo 0)
            fi
            if (( target_ts > now_ts )); then
                wait_seconds=$(( target_ts - now_ts + 60 ))
                parse_source="time-of-day"
            fi
        fi
    fi

    # Fallback: rate limit detected but can't parse specific time
    if [[ $wait_seconds -eq 0 ]]; then
        wait_seconds=360  # 6 min (typical 5 min reset + 1 min buffer)
        parse_source="fallback"
    fi

    # Safety cap: max 30 minutes to avoid absurd waits from parse errors
    if (( wait_seconds > 1800 )); then
        wait_seconds=1800
    fi

    local resume_ts=$(( now_ts + wait_seconds ))
    local resume_at
    resume_at=$(date -r "$resume_ts" '+%H:%M:%S' 2>/dev/null \
             || date -d "@$resume_ts" '+%H:%M:%S' 2>/dev/null \
             || echo "unknown")

    jq -n \
        --arg detected_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg resume_at "$resume_at" \
        --argjson wait_seconds "$wait_seconds" \
        --argjson resume_ts "$resume_ts" \
        --arg parse_source "$parse_source" \
        --arg raw_message "${rl_content:0:500}" \
        '{rate_limited:true, detected_at:$detected_at, resume_at:$resume_at,
          wait_seconds:$wait_seconds, resume_ts:$resume_ts,
          parse_source:$parse_source, raw_message:$raw_message}' \
        > "$rl_file"

    log_info "Rate limit detected (source: $parse_source, wait: ${wait_seconds}s, resume: ~$resume_at)"
    return 0
}

# Wait for rate limit to expire with countdown display
# Usage: rate_limit_wait <wait_seconds> <project_dir>
rate_limit_wait() {
    local wait_seconds="$1"
    local project_dir="$2"

    local resume_ts=$(( $(date +%s) + wait_seconds ))
    local resume_time
    resume_time=$(date -r "$resume_ts" '+%H:%M:%S' 2>/dev/null \
               || date -d "@$resume_ts" '+%H:%M:%S' 2>/dev/null \
               || echo "unknown")

    log_warn "Rate limited — auto-waiting ${wait_seconds}s (resume ~$resume_time)"
    notify_user "Harness: Rate Limited" \
        "Auto-waiting ${wait_seconds}s. Resume at ~$resume_time." \
        "normal"

    # Write state for monitor
    local rl_file="$project_dir/.harness-ratelimit.json"
    jq -n \
        --argjson resume_ts "$resume_ts" \
        --argjson wait_seconds "$wait_seconds" \
        --arg resume_at "$resume_time" \
        '{waiting:true, resume_ts:$resume_ts, wait_seconds:$wait_seconds, resume_at:$resume_at}' \
        > "$rl_file" 2>/dev/null || true

    # Countdown loop
    local remaining=$wait_seconds
    while (( remaining > 0 )); do
        printf "\r${YELLOW}[RATE LIMIT]${NC} Resuming in %02dm %02ds (at ~%s)  " \
            $(( remaining / 60 )) $(( remaining % 60 )) "$resume_time"

        # Update state file for monitor every 30s
        if (( remaining % 30 == 0 )); then
            jq -n \
                --argjson resume_ts "$resume_ts" \
                --argjson remaining "$remaining" \
                --arg resume_at "$resume_time" \
                '{waiting:true, resume_ts:$resume_ts, remaining:$remaining, resume_at:$resume_at}' \
                > "$rl_file" 2>/dev/null || true
        fi

        if (( remaining > 60 )); then
            sleep 30
            remaining=$(( remaining - 30 ))
        elif (( remaining > 10 )); then
            sleep 10
            remaining=$(( remaining - 10 ))
        else
            sleep 1
            remaining=$(( remaining - 1 ))
        fi
    done
    printf "\r${GREEN}[RATE LIMIT]${NC} Wait complete — resuming session.                                 \n"

    rm -f "$rl_file"

    notify_user "Harness: Resuming" \
        "Rate limit expired. Resuming coding session." \
        "normal"
}

# Get a human-readable progress bar
# Usage: progress_bar <current> <total> [width]
progress_bar() {
    local current="$1"
    local total="$2"
    local width="${3:-40}"

    if [[ "$total" -eq 0 ]]; then
        echo "[$(printf '%*s' "$width" | tr ' ' '-')]  0/0"
        return
    fi

    local filled=$(( current * width / total ))
    local empty=$(( width - filled ))

    printf '[%s%s] %d/%d' \
        "$(printf '%*s' "$filled" | tr ' ' '#')" \
        "$(printf '%*s' "$empty" | tr ' ' '-')" \
        "$current" "$total"
}
