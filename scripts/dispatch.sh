#!/bin/bash
# dispatch-claude-code.sh — Dispatch a task to Claude Code with auto-callback
#
# Usage:
#   dispatch-claude-code.sh [OPTIONS] -p "your prompt here"
#
# Options:
#   -p, --prompt TEXT           Task prompt (required, or use --prompt-file)
#   --prompt-file FILE          Read prompt from file
#   -n, --name NAME             Task name (for tracking)
#   -g, --group ID              Telegram group ID for result delivery
#   -s, --session KEY           Callback session key
#   -w, --workdir DIR           Working directory for Claude Code
#   --agent-teams               Enable Agent Teams (lead + teammates)
#   --agents-json JSON          Define custom subagents via JSON (--agents flag)
#   --teammate-mode MODE        Agent Teams display mode (auto/in-process/tmux)
#   --permission-mode MODE      Claude Code permission mode
#   --allowed-tools TOOLS       Allowed tools string
#   --disallowed-tools TOOLS    Disallowed tools string
#   --model MODEL               Model override
#   --fallback-model MODEL      Fallback model when primary is overloaded
#   --max-budget-usd AMOUNT     Maximum dollar spend before stopping
#   --max-turns N               Maximum agentic turns
#   --worktree NAME             Run in isolated git worktree
#   --no-session-persistence    Don't save session to disk
#   --append-system-prompt TEXT  Append to system prompt
#   --append-system-prompt-file  Append system prompt from file
#   --mcp-config FILE           Load MCP servers from JSON file
#   --verbose                   Enable verbose logging
#
# The script:
#   1. Writes task metadata to task-meta.json (hook reads this)
#   2. Runs Claude Code via claude_code_run.py
#   3. When Claude Code finishes, Stop/TaskCompleted hook fires automatically
#   4. Hook reads meta, writes results, wakes AGI
#   5. AGI reads results and relays to Telegram group

set -euo pipefail

RESULT_DIR="/home/ubuntu/clawd/data/claude-code-results"
META_FILE="${RESULT_DIR}/task-meta.json"
OUTPUT_FILE="/tmp/claude-code-output.txt"
TASK_OUTPUT="${RESULT_DIR}/task-output.txt"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="${SCRIPT_DIR}/claude_code_run.py"

# Defaults
PROMPT=""
PROMPT_FILE=""
TASK_NAME="adhoc-$(date +%s)"
TELEGRAM_GROUP="-5006066016"  # Default: Claude Code Tasks group
CALLBACK_GROUP=""              # Agent's own group for callback
CALLBACK_DM=""                 # Telegram user ID for DM callback
CALLBACK_ACCOUNT=""            # Telegram bot account for DM callback
CALLBACK_SESSION="${OPENCLAW_SESSION_KEY:-}"
WORKDIR="/home/ubuntu/clawd"
AGENT_TEAMS=""
AGENT_ID=""
AGENTS_JSON=""
TEAMMATE_MODE=""
PERMISSION_MODE=""
ALLOWED_TOOLS=""
DISALLOWED_TOOLS=""
MODEL=""
FALLBACK_MODEL=""
MAX_BUDGET_USD=""
MAX_TURNS=""
WORKTREE=""
NO_SESSION_PERSISTENCE=""
APPEND_SYSTEM_PROMPT=""
APPEND_SYSTEM_PROMPT_FILE=""
MCP_CONFIG=""
VERBOSE=""

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--prompt) PROMPT="$2"; shift 2;;
        --prompt-file) PROMPT_FILE="$2"; shift 2;;
        -n|--name) TASK_NAME="$2"; shift 2;;
        -g|--group) TELEGRAM_GROUP="$2"; shift 2;;
        -s|--session) CALLBACK_SESSION="$2"; shift 2;;
        --callback-group) CALLBACK_GROUP="$2"; shift 2;;
        --callback-dm) CALLBACK_DM="$2"; shift 2;;
        --callback-account) CALLBACK_ACCOUNT="$2"; shift 2;;
        -w|--workdir) WORKDIR="$2"; shift 2;;
        --agent-teams) AGENT_TEAMS="1"; shift;;
        --agent-id) AGENT_ID="$2"; shift 2;;
        --agents-json) AGENTS_JSON="$2"; shift 2;;
        --teammate-mode) TEAMMATE_MODE="$2"; shift 2;;
        --permission-mode) PERMISSION_MODE="$2"; shift 2;;
        --allowed-tools) ALLOWED_TOOLS="$2"; shift 2;;
        --disallowed-tools) DISALLOWED_TOOLS="$2"; shift 2;;
        --model) MODEL="$2"; shift 2;;
        --fallback-model) FALLBACK_MODEL="$2"; shift 2;;
        --max-budget-usd) MAX_BUDGET_USD="$2"; shift 2;;
        --max-turns) MAX_TURNS="$2"; shift 2;;
        --worktree) WORKTREE="$2"; shift 2;;
        --no-session-persistence) NO_SESSION_PERSISTENCE="1"; shift;;
        --append-system-prompt) APPEND_SYSTEM_PROMPT="$2"; shift 2;;
        --append-system-prompt-file) APPEND_SYSTEM_PROMPT_FILE="$2"; shift 2;;
        --mcp-config) MCP_CONFIG="$2"; shift 2;;
        --verbose) VERBOSE="1"; shift;;
        *) echo "Unknown option: $1" >&2; exit 1;;
    esac
done

# ---- Resolve prompt (--prompt-file takes precedence if both given) ----
if [ -n "$PROMPT_FILE" ]; then
    if [ ! -f "$PROMPT_FILE" ]; then
        echo "Error: prompt file not found: $PROMPT_FILE" >&2
        exit 1
    fi
    PROMPT="$(cat "$PROMPT_FILE")"
fi

if [ -z "$PROMPT" ]; then
    echo "Error: --prompt or --prompt-file is required" >&2
    exit 1
fi

# ---- Auto-detect callback from workspace config ----
if [ -z "$CALLBACK_GROUP" ] && [ -z "$CALLBACK_DM" ]; then
    for SEARCH_DIR in "$(pwd)" "$WORKDIR" "${OPENCLAW_AGENT_DIR:-}"; do
        CALLBACK_CONFIG="${SEARCH_DIR}/dispatch-callback.json"
        if [ -f "$CALLBACK_CONFIG" ] 2>/dev/null; then
            CB_TYPE=$(jq -r '.type // ""' "$CALLBACK_CONFIG" 2>/dev/null || echo "")
            case "$CB_TYPE" in
                group)
                    CALLBACK_GROUP=$(jq -r '.group // ""' "$CALLBACK_CONFIG" 2>/dev/null || echo "")
                    [ -n "$CALLBACK_GROUP" ] && echo "📡 Auto-detected callback: group $CALLBACK_GROUP (from $CALLBACK_CONFIG)"
                    ;;
                dm)
                    CALLBACK_DM=$(jq -r '.dm // ""' "$CALLBACK_CONFIG" 2>/dev/null || echo "")
                    CALLBACK_ACCOUNT=$(jq -r '.account // ""' "$CALLBACK_CONFIG" 2>/dev/null || echo "")
                    [ -n "$CALLBACK_DM" ] && echo "📡 Auto-detected callback: DM $CALLBACK_DM via ${CALLBACK_ACCOUNT:-default} (from $CALLBACK_CONFIG)"
                    ;;
            esac
            break
        fi
    done
fi

# ---- Agent Teams: build structured --agents JSON if no custom agents-json given ----
if [ -n "$AGENT_TEAMS" ] && [ -z "$AGENTS_JSON" ]; then
    # Default Agent Teams: define a structured Testing Agent via --agents JSON
    # This replaces the old approach of injecting instructions into the prompt
    AGENTS_JSON='{
  "testing-agent": {
    "description": "Dedicated testing agent. Use proactively to write and run tests for all code changes.",
    "prompt": "You are a Testing Agent. Your responsibilities:\n1. Write comprehensive unit tests for every module\n2. Run all tests and ensure they pass\n3. Check edge cases and error handling\n4. Report test results clearly\n5. If tests fail, communicate failures to the lead for fixes.\n\nAlways run tests after writing them. Never mark work as done until all tests pass.",
    "tools": ["Read", "Edit", "Write", "Bash", "Glob", "Grep"],
    "model": "sonnet"
  }
}'
    # Still add a lighter prompt hint for the lead (no longer the full injection)
    PROMPT="${PROMPT}

Note: A dedicated Testing Agent is available via --agents. Delegate test writing and execution to it. All tests must pass before the task is complete."
fi

# ---- 1. Write task metadata ----
mkdir -p "$RESULT_DIR"

jq -n \
    --arg name "$TASK_NAME" \
    --arg group "$TELEGRAM_GROUP" \
    --arg callback_group "$CALLBACK_GROUP" \
    --arg callback_dm "$CALLBACK_DM" \
    --arg callback_account "$CALLBACK_ACCOUNT" \
    --arg session "$CALLBACK_SESSION" \
    --arg prompt "$PROMPT" \
    --arg workdir "$WORKDIR" \
    --arg ts "$(date -Iseconds)" \
    --arg agent_teams "${AGENT_TEAMS:-0}" \
    --arg agent_id "$AGENT_ID" \
    --arg model "${MODEL:-}" \
    --arg fallback_model "${FALLBACK_MODEL:-}" \
    --arg max_budget "${MAX_BUDGET_USD:-}" \
    --arg max_turns "${MAX_TURNS:-}" \
    --arg worktree "${WORKTREE:-}" \
    '{task_name: $name, telegram_group: $group, callback_group: $callback_group, callback_dm: $callback_dm, callback_account: $callback_account, callback_session: $session, prompt: $prompt, workdir: $workdir, started_at: $ts, agent_teams: ($agent_teams == "1"), agent_id: $agent_id, model: $model, fallback_model: $fallback_model, max_budget_usd: $max_budget, max_turns: $max_turns, worktree: $worktree, status: "running"}' \
    > "$META_FILE"

echo "📋 Task metadata written: $META_FILE"
echo "   Task: $TASK_NAME"
echo "   Group: ${TELEGRAM_GROUP:-none}"
echo "   Agent Teams: ${AGENT_TEAMS:-no}"
[ -n "$MAX_BUDGET_USD" ] && echo "   Budget: \$${MAX_BUDGET_USD}"
[ -n "$MAX_TURNS" ] && echo "   Max Turns: ${MAX_TURNS}"
[ -n "$FALLBACK_MODEL" ] && echo "   Fallback Model: ${FALLBACK_MODEL}"
[ -n "$WORKTREE" ] && echo "   Worktree: ${WORKTREE}"
[ -n "$MODEL" ] && echo "   Model: ${MODEL}"

# ---- 2. Clear previous output ----
> "$OUTPUT_FILE"
> "$TASK_OUTPUT"

# ---- 3. Build runner command ----
# Write prompt to a temp file to avoid shell escaping issues with complex prompts
PROMPT_TMPFILE="$(mktemp /tmp/dispatch-prompt-XXXXXX.txt)"
printf '%s' "$PROMPT" > "$PROMPT_TMPFILE"
trap 'rm -f "$PROMPT_TMPFILE"' EXIT

CMD=(python3 "$RUNNER" --prompt-file "$PROMPT_TMPFILE" --cwd "$WORKDIR")

if [ -n "$AGENT_TEAMS" ]; then
    CMD+=(--agent-teams)
fi
if [ -n "$AGENTS_JSON" ]; then
    CMD+=(--agents-json "$AGENTS_JSON")
fi
if [ -n "$TEAMMATE_MODE" ]; then
    CMD+=(--teammate-mode "$TEAMMATE_MODE")
fi
if [ -n "$PERMISSION_MODE" ]; then
    CMD+=(--permission-mode "$PERMISSION_MODE")
fi
if [ -n "$ALLOWED_TOOLS" ]; then
    CMD+=(--allowedTools "$ALLOWED_TOOLS")
fi
if [ -n "$DISALLOWED_TOOLS" ]; then
    CMD+=(--disallowedTools "$DISALLOWED_TOOLS")
fi
if [ -n "$MODEL" ]; then
    CMD+=(--model "$MODEL")
fi
if [ -n "$FALLBACK_MODEL" ]; then
    CMD+=(--fallback-model "$FALLBACK_MODEL")
fi
if [ -n "$MAX_BUDGET_USD" ]; then
    CMD+=(--max-budget-usd "$MAX_BUDGET_USD")
fi
if [ -n "$MAX_TURNS" ]; then
    CMD+=(--max-turns "$MAX_TURNS")
fi
if [ -n "$WORKTREE" ]; then
    CMD+=(--worktree "$WORKTREE")
fi
if [ -n "$NO_SESSION_PERSISTENCE" ]; then
    CMD+=(--no-session-persistence)
fi
if [ -n "$APPEND_SYSTEM_PROMPT" ]; then
    CMD+=(--append-system-prompt "$APPEND_SYSTEM_PROMPT")
fi
if [ -n "$APPEND_SYSTEM_PROMPT_FILE" ]; then
    CMD+=(--append-system-prompt-file "$APPEND_SYSTEM_PROMPT_FILE")
fi
if [ -n "$MCP_CONFIG" ]; then
    CMD+=(--mcp-config "$MCP_CONFIG")
fi
if [ -n "$VERBOSE" ]; then
    CMD+=(--verbose)
fi

# ---- 4. Set environment ----
export OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-477d47934e5f6b02bfb823ba681bb743eae55479b7d260e8}"
export OPENCLAW_GATEWAY="${OPENCLAW_GATEWAY:-http://127.0.0.1:18789}"

# ---- 5. Run Claude Code (output tee'd for hook) ----
echo "🚀 Launching Claude Code..."
echo "   Command: ${CMD[*]}"
echo ""

# Use tee to capture output while also displaying it
"${CMD[@]}" 2>&1 | tee "$TASK_OUTPUT"
EXIT_CODE=${PIPESTATUS[0]}

echo ""
echo "✅ Claude Code exited with code: $EXIT_CODE"
echo "   Hook should have fired automatically."
echo "   Results: ${RESULT_DIR}/latest.json"

# Update meta with completion
if [ -f "$META_FILE" ]; then
    jq --arg code "$EXIT_CODE" --arg ts "$(date -Iseconds)" \
        '. + {exit_code: ($code | tonumber), completed_at: $ts, status: "done"}' \
        "$META_FILE" > "${META_FILE}.tmp" && mv "${META_FILE}.tmp" "$META_FILE"
fi

exit $EXIT_CODE
