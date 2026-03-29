#!/bin/bash
# Promptbook — PostToolUse hook (matcher: Edit|Write|NotebookEdit) (plugin version)
# Counts lines changed and tracks file extensions for language detection.
# Runs synchronously (<50ms) — completely silent.

exec 2>>"${CLAUDE_PLUGIN_DATA:?}/hook-errors.log"

SESSIONS_DIR="${CLAUDE_PLUGIN_DATA}/sessions"

INPUT=$(cat) || exit 0
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id') || exit 0
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""') || exit 0
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

LINES=0
FILE_EXT=""

if [ "$TOOL_NAME" = "Write" ]; then
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // ""')
  if [ -n "$CONTENT" ]; then
    LINES=$(echo "$CONTENT" | wc -l | tr -d ' ')
  fi
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
elif [ "$TOOL_NAME" = "Edit" ]; then
  NEW_STRING=$(echo "$INPUT" | jq -r '.tool_input.new_string // ""')
  OLD_STRING=$(echo "$INPUT" | jq -r '.tool_input.old_string // ""')
  if [ -n "$NEW_STRING" ]; then
    NEW_LINES=$(echo "$NEW_STRING" | wc -l | tr -d ' ')
    OLD_LINES=0
    if [ -n "$OLD_STRING" ]; then
      OLD_LINES=$(echo "$OLD_STRING" | wc -l | tr -d ' ')
    fi
    LINES=$(( NEW_LINES > OLD_LINES ? NEW_LINES - OLD_LINES : OLD_LINES - NEW_LINES ))
    if [ "$LINES" -eq 0 ] && [ -n "$NEW_STRING" ]; then
      LINES=1
    fi
  fi
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
elif [ "$TOOL_NAME" = "NotebookEdit" ]; then
  LINES=1
  NEW_SOURCE=$(echo "$INPUT" | jq -r '.tool_input.new_source // ""')
  if [ -n "$NEW_SOURCE" ]; then
    LINES=$(echo "$NEW_SOURCE" | wc -l | tr -d ' ')
    if [ "$LINES" -eq 0 ]; then LINES=1; fi
  fi
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.notebook_path // .tool_input.file_path // ""')
fi

# Extract file extension
if [ -n "$FILE_PATH" ]; then
  FILE_EXT="${FILE_PATH##*.}"
fi

# Update session file
TMPFILE=$(mktemp)
if [ -n "$FILE_EXT" ] && [ "$FILE_EXT" != "$FILE_PATH" ]; then
  jq --argjson lines "$LINES" --arg ext "$FILE_EXT" \
    '.lines_changed += $lines | .file_extensions[$ext] = ((.file_extensions[$ext] // 0) + 1)' \
    "$SESSION_FILE" > "$TMPFILE" && mv "$TMPFILE" "$SESSION_FILE" || true
else
  jq --argjson lines "$LINES" \
    '.lines_changed += $lines' \
    "$SESSION_FILE" > "$TMPFILE" && mv "$TMPFILE" "$SESSION_FILE" || true
fi
