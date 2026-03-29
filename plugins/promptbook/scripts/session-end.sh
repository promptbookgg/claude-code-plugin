#!/bin/bash
# Promptbook — SessionEnd hook (plugin version)
# Finalizes the session: records end time, calculates duration, determines language,
# extracts token usage and file metadata from the transcript.
# Completely silent to avoid terminal chitter.

# Redirect all stderr to log file; never exit non-zero
exec 2>>"${CLAUDE_PLUGIN_DATA:?}/hook-errors.log"

DATA_DIR="${CLAUDE_PLUGIN_DATA}"
SESSIONS_DIR="$DATA_DIR/sessions"
SCRIPTS_DIR="${CLAUDE_PLUGIN_ROOT:?}/scripts"

INPUT=$(cat) || exit 0
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id') || exit 0
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""') || true
EXIT_REASON=$(echo "$INPUT" | jq -r '.reason // "unknown"') || EXIT_REASON="unknown"
SESSION_FILE="$SESSIONS_DIR/$SESSION_ID.json"

# Skip if this session was spawned by our own summary generation
[ "${PROMPTBOOK_SKIP_HOOKS:-}" = "1" ] && exit 0

[ ! -f "$SESSION_FILE" ] && exit 0

# Serialize writes against async prompt/edit hooks still flushing data.
LOCK_DIR="$SESSION_FILE.lock"
LOCK_ATTEMPTS=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  sleep 0.01
  LOCK_ATTEMPTS=$((LOCK_ATTEMPTS + 1))
  if [ $LOCK_ATTEMPTS -ge 500 ]; then
    echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") WARN: lock timeout after 5s, proceeding without lock" >> "$DATA_DIR/submit.log"
    break
  fi
done
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
START_TIME=$(jq -r '.start_time' "$SESSION_FILE")
SESSION_CWD=$(jq -r '.cwd // ""' "$SESSION_FILE")

# Calculate build time in seconds (TZ=UTC ensures consistent parsing)
START_EPOCH=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$START_TIME" +%s 2>/dev/null || date -u -d "$START_TIME" +%s 2>/dev/null)
END_EPOCH=$(date -u +%s)
BUILD_TIME=$(( END_EPOCH - START_EPOCH ))

# Determine primary language from most-used file extension
LANGUAGE=$(jq -r '
  .file_extensions
  | to_entries
  | sort_by(-.value)
  | first
  | .key // "unknown"
' "$SESSION_FILE")

# Map file extensions to language names
case "$LANGUAGE" in
  ts|tsx) LANGUAGE="TypeScript" ;;
  js|jsx) LANGUAGE="JavaScript" ;;
  py) LANGUAGE="Python" ;;
  rs) LANGUAGE="Rust" ;;
  go) LANGUAGE="Go" ;;
  rb) LANGUAGE="Ruby" ;;
  java) LANGUAGE="Java" ;;
  swift) LANGUAGE="Swift" ;;
  kt) LANGUAGE="Kotlin" ;;
  css) LANGUAGE="CSS" ;;
  html) LANGUAGE="HTML" ;;
  sql) LANGUAGE="SQL" ;;
  sh|bash|zsh) LANGUAGE="Shell" ;;
  md) LANGUAGE="Markdown" ;;
  json) LANGUAGE="JSON" ;;
  yaml|yml) LANGUAGE="YAML" ;;
  unknown) LANGUAGE="Unknown" ;;
esac

# Parse transcript for token usage and file metadata
TOTAL_TOKENS=0
INPUT_TOKENS=0
OUTPUT_TOKENS=0
CACHE_CREATION_TOKENS=0
CACHE_READ_TOKENS=0
TRANSCRIPT_DATA=""

if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  TRANSCRIPT_DATA=$(python3 "$SCRIPTS_DIR/parse-transcript.py" "$TRANSCRIPT_PATH" "$SESSION_CWD" 2>>"$DATA_DIR/parse-errors.log" || echo "")
  if [ -n "$TRANSCRIPT_DATA" ] && echo "$TRANSCRIPT_DATA" | jq -e '.total_tokens' > /dev/null 2>&1; then
    TOTAL_TOKENS=$(echo "$TRANSCRIPT_DATA" | jq -r '.total_tokens')
    INPUT_TOKENS=$(echo "$TRANSCRIPT_DATA" | jq -r '.input_tokens')
    OUTPUT_TOKENS=$(echo "$TRANSCRIPT_DATA" | jq -r '.output_tokens')
    CACHE_CREATION_TOKENS=$(echo "$TRANSCRIPT_DATA" | jq -r '.cache_creation_input_tokens // 0')
    CACHE_READ_TOKENS=$(echo "$TRANSCRIPT_DATA" | jq -r '.cache_read_input_tokens // 0')
  fi
fi

# Finalize session with all data
TMPFILE=$(mktemp)
HAS_TOKENS=false
HAS_METADATA=false
FILES_TOUCHED='[]'
TOOL_SUMMARY='{}'
SOURCE_METADATA='null'

COMPACT_LOG=""
TRANSCRIPT_MODEL=""
if [ -n "$TRANSCRIPT_DATA" ]; then
  TRANSCRIPT_MODEL=$(echo "$TRANSCRIPT_DATA" | jq -r '.model // ""' 2>/dev/null || echo "")
  if echo "$TRANSCRIPT_DATA" | jq -e '.total_tokens != null' > /dev/null 2>&1; then
    HAS_TOKENS=true
  fi
  if echo "$TRANSCRIPT_DATA" | jq -e '.source_metadata != null' > /dev/null 2>&1; then
    HAS_METADATA=true
    FILES_TOUCHED=$(echo "$TRANSCRIPT_DATA" | jq -c '.files_touched // []')
    TOOL_SUMMARY=$(echo "$TRANSCRIPT_DATA" | jq -c '.tool_usage_summary // {}')
    SOURCE_METADATA=$(echo "$TRANSCRIPT_DATA" | jq -c '.source_metadata')
  fi
  COMPACT_LOG=$(echo "$TRANSCRIPT_DATA" | jq -r '.compact_log // ""')
fi

# Write compact log to a file so the detached summary process can read it
COMPACT_LOG_FILE=""
if [ -n "$COMPACT_LOG" ]; then
  COMPACT_LOG_FILE="$SESSIONS_DIR/$SESSION_ID.compact.txt"
  printf '%s' "$COMPACT_LOG" > "$COMPACT_LOG_FILE"
fi

# If session-start missed the model, use the one from the transcript
FIX_MODEL="false"
CURRENT_MODEL=$(jq -r '.model // "unknown"' "$SESSION_FILE")
if [ "$CURRENT_MODEL" = "unknown" ] && [ -n "$TRANSCRIPT_MODEL" ]; then
  FIX_MODEL="true"
fi

jq --arg end_time "$END_TIME" \
   --argjson build_time "$BUILD_TIME" \
   --arg language "$LANGUAGE" \
   --arg exit_reason "$EXIT_REASON" \
   --argjson has_tokens "$HAS_TOKENS" \
   --argjson total_tokens "$TOTAL_TOKENS" \
   --argjson input_tokens "$INPUT_TOKENS" \
   --argjson output_tokens "$OUTPUT_TOKENS" \
   --argjson cache_creation_tokens "$CACHE_CREATION_TOKENS" \
   --argjson cache_read_tokens "$CACHE_READ_TOKENS" \
   --argjson has_metadata "$HAS_METADATA" \
   --argjson files_touched "$FILES_TOUCHED" \
   --argjson tool_usage_summary "$TOOL_SUMMARY" \
   --argjson source_metadata "$SOURCE_METADATA" \
   --argjson fix_model "$FIX_MODEL" \
   --arg transcript_model "$TRANSCRIPT_MODEL" \
  '
    .end_time = $end_time
    | .build_time_seconds = $build_time
    | .language = $language
    | .exit_reason = $exit_reason
    | .status = "completed"
    | if $fix_model then .model = $transcript_model else . end
    | if $has_tokens then
        .total_tokens = $total_tokens
        | .input_tokens = $input_tokens
        | .output_tokens = $output_tokens
        | .cache_creation_input_tokens = $cache_creation_tokens
        | .cache_read_input_tokens = $cache_read_tokens
      else
        .
      end
    | if $has_metadata then
        .files_touched = $files_touched
        | .tool_usage_summary = $tool_usage_summary
        | .source_metadata = $source_metadata
      else
        .
      end
  ' \
  "$SESSION_FILE" > "$TMPFILE" && mv "$TMPFILE" "$SESSION_FILE"

# Skip submission for sessions with no user interaction, very short duration,
# AND negligible token usage. These are tooling artifacts (instant closes, stale sessions).
PROMPT_COUNT=$(jq -r '.prompt_count // 0' "$SESSION_FILE")
if [ "$PROMPT_COUNT" = "0" ] && [ "$BUILD_TIME" -lt 10 ] && [ "$TOTAL_TOKENS" -lt 1000 ]; then
  rm -f "$COMPACT_LOG_FILE"
  exit 0
fi

# Resolve full path to claude CLI now (synchronously), so the detached
# background process doesn't depend on PATH being set correctly.
CLAUDE_BIN=$(command -v claude 2>/dev/null || echo "")

# Auto-submit to Promptbook if config exists
# Detach the entire submission into a background process so Claude Code
# can kill this hook immediately without interrupting the network calls.
CONFIG_FILE="$DATA_DIR/config.json"
if [ -f "$CONFIG_FILE" ]; then
  API_KEY="${PROMPTBOOK_API_KEY:-$(jq -r '.api_key // ""' "$CONFIG_FILE")}"
  API_URL="${PROMPTBOOK_API_URL:-$(jq -r '.api_url // ""' "$CONFIG_FILE")}"
  AUTO_SUMMARY=$(jq -r '.auto_summary // "true"' "$CONFIG_FILE")

  if [ -n "$API_KEY" ] && [ -n "$API_URL" ]; then
    PROJECT_NAME=$(jq -r '.project_name // ""' "$SESSION_FILE")

    MODEL_FOR_SUMMARY=$(jq -r '.model // "unknown"' "$SESSION_FILE")
    TOOL_SUMMARY=$(jq -r '
      .source_metadata.tool_usage_summary // .tool_usage_summary // {}
      | to_entries
      | sort_by(-.value)
      | [limit(3; .[])]
      | map("\(.value) \(.key)")
      | join(", ")
    ' "$SESSION_FILE" 2>/dev/null || echo "")

    nohup bash -c '
      API_KEY="$1"; API_URL="$2"; SESSION_FILE="$3"; SESSION_ID="$4"
      AUTO_SUMMARY="$5"; SCRIPTS_DIR="$6"; TRANSCRIPT_PATH="$7"
      SESSION_CWD="$8"; PROJECT_NAME="$9"; CLAUDE_BIN="${10}"
      COMPACT_LOG_FILE="${11}"; PROMPT_COUNT="${12}"
      MODEL="${13}"; BUILD_TIME="${14}"; TOTAL_TOKENS="${15}"
      TOOL_SUMMARY="${16}"; DATA_DIR="${17}"
      LOG_FILE="$DATA_DIR/submit.log"

      PAYLOAD_FILE=$(mktemp)
      jq "del(.files_touched, .source_metadata.files_touched, .compact_log)" "$SESSION_FILE" > "$PAYLOAD_FILE" 2>/dev/null || cp "$SESSION_FILE" "$PAYLOAD_FILE"

      PLUGIN_VERSION=$(jq -r ".version // \"\"" "$SCRIPTS_DIR/../.claude-plugin/plugin.json" 2>/dev/null || echo "")
      RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST "$API_URL/api/builds" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $API_KEY" \
        -H "X-Hooks-Hash: $PLUGIN_VERSION" \
        -d @"$PAYLOAD_FILE" 2>/dev/null)
      HTTP_STATUS=$(echo "$RESPONSE" | tail -1 | sed "s/HTTP_STATUS://")
      BODY=$(echo "$RESPONSE" | sed "\$d")
      rm -f "$PAYLOAD_FILE"

      {
        echo "--- $(date -u +"%Y-%m-%dT%H:%M:%SZ") | session=$SESSION_ID ---"
        if [ "$HTTP_STATUS" = "201" ]; then
          echo "OK: $BODY"
        else
          echo "FAIL (HTTP $HTTP_STATUS): $BODY"
        fi
      } >> "$LOG_FILE" 2>&1

      if [ "$HTTP_STATUS" = "201" ]; then
        BUILD_ID=$(echo "$BODY" | jq -r ".id // \"\"")

        if [ -n "$BUILD_ID" ]; then
          SITE_URL=$(echo "$API_URL" | sed "s|/api.*||; s|/$||")
          echo "OPEN: $SITE_URL/build/$BUILD_ID" >> "$LOG_FILE"
          printf "\n  \033[32m✓\033[0m Progress recorded → \033[4m%s/build/%s\033[0m\n\n" "$SITE_URL" "$BUILD_ID" >/dev/tty 2>/dev/null || true
        fi

        # Check if server says hooks are outdated
        UPDATE_AVAILABLE=$(echo "$BODY" | jq -r ".update_available // false" 2>/dev/null)
        if [ "$UPDATE_AVAILABLE" = "true" ]; then
          printf "  \033[33m↑\033[0m Promptbook update available — run: \033[4m/plugin update promptbook\033[0m\n\n" >/dev/tty 2>/dev/null || true
        fi

        # Determine if we have a summary source
        HAS_SUMMARY_SOURCE=false
        if [ -n "$COMPACT_LOG_FILE" ] && [ -f "$COMPACT_LOG_FILE" ]; then
          HAS_SUMMARY_SOURCE=true
        elif [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
          HAS_SUMMARY_SOURCE=true
        fi

        if [ "$AUTO_SUMMARY" = "true" ] && [ -n "$BUILD_ID" ] && [ "$HAS_SUMMARY_SOURCE" = "true" ]; then
          PROMPTBOOK_SKIP_HOOKS=1 bash "$SCRIPTS_DIR/generate-summary.sh" "$BUILD_ID" "$TRANSCRIPT_PATH" "$SESSION_CWD" "$API_KEY" "$API_URL" "$PROJECT_NAME" "$CLAUDE_BIN" "$COMPACT_LOG_FILE" "$PROMPT_COUNT" "$MODEL" "$BUILD_TIME" "$TOTAL_TOKENS" "$TOOL_SUMMARY"
        elif [ "$AUTO_SUMMARY" = "true" ] && [ -n "$BUILD_ID" ]; then
          PROMPTBOOK_SKIP_HOOKS=1 bash "$SCRIPTS_DIR/generate-summary.sh" "$BUILD_ID" "" "$SESSION_CWD" "$API_KEY" "$API_URL" "$PROJECT_NAME" "$CLAUDE_BIN" "" "$PROMPT_COUNT" "$MODEL" "$BUILD_TIME" "$TOTAL_TOKENS" "$TOOL_SUMMARY"
          rm -f "$COMPACT_LOG_FILE"
        elif [ -n "$BUILD_ID" ]; then
          PROMPTBOOK_SKIP_HOOKS=1 bash "$SCRIPTS_DIR/generate-summary.sh" "$BUILD_ID" "" "$SESSION_CWD" "$API_KEY" "$API_URL" "$PROJECT_NAME" "" "" "$PROMPT_COUNT" "$MODEL" "$BUILD_TIME" "$TOTAL_TOKENS" "$TOOL_SUMMARY"
          rm -f "$COMPACT_LOG_FILE"
        fi
      else
        rm -f "$COMPACT_LOG_FILE"
      fi
    ' _ "$API_KEY" "$API_URL" "$SESSION_FILE" "$SESSION_ID" \
        "$AUTO_SUMMARY" "$SCRIPTS_DIR" "$TRANSCRIPT_PATH" \
        "$SESSION_CWD" "$PROJECT_NAME" "$CLAUDE_BIN" \
        "$COMPACT_LOG_FILE" "$PROMPT_COUNT" \
        "$MODEL_FOR_SUMMARY" "$BUILD_TIME" "$TOTAL_TOKENS" \
        "$TOOL_SUMMARY" "$DATA_DIR" \
      >> "$DATA_DIR/submit.log" 2>&1 &
    disown
  else
    rm -f "$COMPACT_LOG_FILE"
  fi
else
  rm -f "$COMPACT_LOG_FILE"
fi
