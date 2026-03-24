#!/bin/bash
# Promptbook — SessionStart hook (plugin version)
# Creates a new session tracking file when a Claude Code session begins.
# Reads JSON from stdin with: session_id, model, cwd, hook_event_name

set -euo pipefail

DATA_DIR="${CLAUDE_PLUGIN_DATA:?CLAUDE_PLUGIN_DATA not set}"
SESSIONS_DIR="$DATA_DIR/sessions"
mkdir -p "$SESSIONS_DIR"

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
MODEL=$(echo "$INPUT" | jq -r '
  if (.model | type?) == "string" then
    .model
  elif (.model | type?) == "object" then
    .model.id // .model.name // .model.display_name // .model.model // empty
  else
    .model_name // .modelName // .session_model // .sessionModel // empty
  end
')
if [ -z "$MODEL" ] || [ "$MODEL" = "null" ]; then
  MODEL="unknown"
  {
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") WARN: SessionStart missing model field"
    echo "$INPUT" | jq -c '{hook_event_name, session_id, cwd, top_level_keys: (keys | sort)}'
  } >> "$DATA_DIR/hook-errors.log"
fi
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Derive project name from cwd.
# If this is a git worktree (`.git` is a file, not a directory), resolve
# the parent repo name instead of using the auto-generated worktree name.
PROJECT_NAME=$(basename "$CWD")
GIT_PATH="$CWD/.git"
if [ -f "$GIT_PATH" ] 2>/dev/null; then
  GITDIR=$(sed -n 's/^gitdir: //p' "$GIT_PATH" 2>/dev/null || true)
  if [ -n "$GITDIR" ]; then
    PARENT_REPO=$(echo "$GITDIR" | sed 's|/\.git/worktrees/.*$||')
    if [ -n "$PARENT_REPO" ] && [ -d "$PARENT_REPO" ]; then
      PROJECT_NAME=$(basename "$PARENT_REPO")
    fi
  fi
fi

SESSION_FILE="$SESSIONS_DIR/$SESSION_ID.json"

jq -n \
  --arg session_id "$SESSION_ID" \
  --arg project_name "$PROJECT_NAME" \
  --arg model "$MODEL" \
  --arg ai_tool "claude-code" \
  --arg start_time "$TIMESTAMP" \
  --arg cwd "$CWD" \
  '{
    session_id: $session_id,
    project_name: $project_name,
    model: $model,
    ai_tool: $ai_tool,
    start_time: $start_time,
    end_time: null,
    build_time_seconds: null,
    prompt_count: 0,
    lines_changed: 0,
    cwd: $cwd,
    file_extensions: {},
    status: "active"
  }' > "$SESSION_FILE"

# --- Session context injection ---
# Fetch recent session summaries from Promptbook API and print to stdout.
# Claude Code injects stdout from SessionStart hooks as conversation context.
# Fails silently — if the API is unreachable, Claude Code works normally.
CONFIG_FILE="$DATA_DIR/config.json"
if [ -f "$CONFIG_FILE" ]; then
  API_KEY=$(jq -r '.api_key // ""' "$CONFIG_FILE")
  API_URL=$(jq -r '.api_url // ""' "$CONFIG_FILE")

  if [ -n "$API_KEY" ] && [ -n "$API_URL" ]; then
    CONTEXT=$(curl -s --max-time 2 --connect-timeout 1 -f \
      -H "Authorization: Bearer $API_KEY" \
      "$API_URL/api/hooks/session-context?project_name=$(printf '%s' "$PROJECT_NAME" | jq -sRr @uri)" \
      2>/dev/null) || CONTEXT=""

    # Only print if we got a non-empty, valid-looking response (starts with ##)
    if [ -n "$CONTEXT" ] && echo "$CONTEXT" | head -1 | grep -q '^##'; then
      printf '%s\n' "## Promptbook — here is what was built recently on $PROJECT_NAME"
      printf '%s\n' ""
      echo "$CONTEXT" | tail -n +2
    fi
  fi
fi
