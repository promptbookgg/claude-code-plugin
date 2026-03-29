#!/bin/bash
# Promptbook — UserPromptSubmit hook (plugin version)
# Increments the prompt counter for the active session.
# Runs synchronously (<50ms) — completely silent.

exec 2>>"${CLAUDE_PLUGIN_DATA:?}/hook-errors.log"

SESSIONS_DIR="${CLAUDE_PLUGIN_DATA}/sessions"

INPUT=$(cat) || exit 0
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id') || exit 0
SESSION_FILE="$SESSIONS_DIR/$SESSION_ID.json"

[ ! -f "$SESSION_FILE" ] && exit 0

# Serialize writes because multiple async hook events can land at once.
LOCK_DIR="$SESSION_FILE.lock"
LOCK_ATTEMPTS=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  sleep 0.01
  LOCK_ATTEMPTS=$((LOCK_ATTEMPTS + 1))
  if [ $LOCK_ATTEMPTS -ge 500 ]; then
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") WARN: lock timeout after 5s, proceeding without lock" >> "${CLAUDE_PLUGIN_DATA}/submit.log"
    break
  fi
done
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TMPFILE=$(mktemp)
jq --arg ts "$TIMESTAMP" '.prompt_count += 1 | .prompt_timestamps += [$ts]' "$SESSION_FILE" > "$TMPFILE" && mv "$TMPFILE" "$SESSION_FILE" || true
