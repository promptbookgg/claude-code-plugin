#!/bin/bash
# Promptbook — Auto-generate title + summary for a build card.
# Runs in the background after session-end.sh submits the card.
#
# Requires: claude CLI, jq, curl
# Input: BUILD_ID, TRANSCRIPT_PATH, SESSION_CWD, API_KEY, API_URL,
#        PROJECT_NAME, CLAUDE_BIN (optional), COMPACT_LOG_FILE (optional)
#
# Flow:
# 1. Read pre-extracted compact log (or extract from transcript as fallback)
# 2. Pipe to claude --print --model haiku with a summary prompt
# 3. Parse title + summary from response
# 4. PATCH the build card via the API

set -uo pipefail
# No set -e: we handle errors explicitly so failures always get logged

SCRIPTS_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")" && pwd)}/scripts"
# If CLAUDE_PLUGIN_ROOT is set, SCRIPTS_DIR = $CLAUDE_PLUGIN_ROOT/scripts
# Otherwise fall back to the directory this script lives in (bash install compat)
if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
LOG_FILE="${CLAUDE_PLUGIN_DATA:-$HOME/.promptbook}/summary.log"

BUILD_ID="$1"
TRANSCRIPT_PATH="$2"
SESSION_CWD="$3"
API_KEY="$4"
API_URL="$5"
PROJECT_NAME="${6:-}"
CLAUDE_BIN="${7:-}"
COMPACT_LOG_FILE="${8:-}"
PROMPT_COUNT="${9:-1}"
MODEL="${10:-unknown}"
BUILD_TIME="${11:-0}"
TOTAL_TOKENS_RAW="${12:-0}"
TOOL_SUMMARY="${13:-}"
STATUS_API_URL="$API_URL/api/builds/$BUILD_ID/summary-status"

log() {
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | build=$BUILD_ID | $1" >> "$LOG_FILE"
}

update_summary_status() {
  local STATUS="$1"
  local ERROR_CODE="${2:-}"
  local BODY

  if [ -n "$ERROR_CODE" ]; then
    BODY=$(jq -n --arg status "$STATUS" --arg error_code "$ERROR_CODE" '{status: $status, error_code: $error_code}')
  else
    BODY=$(jq -n --arg status "$STATUS" '{status: $status}')
  fi

  curl -s -X POST "$STATUS_API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -d "$BODY" > /dev/null 2>&1 || true
}

# Helper: format seconds into human-readable duration
format_duration() {
  local SECS="$1"
  if [ "$SECS" -lt 60 ]; then
    echo "${SECS}s"
  elif [ "$SECS" -lt 3600 ]; then
    echo "$(( SECS / 60 ))m"
  else
    local H=$(( SECS / 3600 ))
    local M=$(( (SECS % 3600) / 60 ))
    if [ "$M" -gt 0 ]; then echo "${H}h ${M}m"; else echo "${H}h"; fi
  fi
}

# Helper: format token count (e.g., 238082 → "238K")
format_tokens() {
  local TOK="$1"
  if [ "$TOK" -ge 1000000 ]; then
    echo "$(( TOK / 1000000 )).$(( (TOK % 1000000) / 100000 ))M"
  elif [ "$TOK" -ge 1000 ]; then
    echo "$(( TOK / 1000 ))K"
  else
    echo "$TOK"
  fi
}

# Helper: publish card with a deterministic fallback summary (when Haiku fails)
publish_with_fallback() {
  local SUMMARY_STATUS="${1:-patch_failed}"
  local ERROR_CODE="${2:-}"
  update_summary_status "$SUMMARY_STATUS" "$ERROR_CODE"

  local DURATION
  DURATION=$(format_duration "$BUILD_TIME")
  local TOKENS
  TOKENS=$(format_tokens "$TOTAL_TOKENS_RAW")

  # Determine work style from the dominant tool
  local DOMINANT_TOOL=""
  if [ -n "$TOOL_SUMMARY" ]; then
    DOMINANT_TOOL=$(echo "$TOOL_SUMMARY" | cut -d',' -f1 | awk '{print $2}')
  fi

  local WORK_STYLE="" WORK_VERB="" WORK_DESC=""
  case "$DOMINANT_TOOL" in
    Edit)   WORK_STYLE="refactor";       WORK_VERB="Refactored";     WORK_DESC="with heavy editing and code changes" ;;
    Write)  WORK_STYLE="build";          WORK_VERB="Built";          WORK_DESC="creating new files and components" ;;
    Read)   WORK_STYLE="exploration";    WORK_VERB="Explored";       WORK_DESC="reading and analyzing the codebase" ;;
    Grep)   WORK_STYLE="investigation";  WORK_VERB="Investigated";   WORK_DESC="searching and tracing code patterns" ;;
    Bash)   WORK_STYLE="debugging";      WORK_VERB="Debugged";       WORK_DESC="running commands and testing" ;;
    Agent)  WORK_STYLE="orchestration";  WORK_VERB="Orchestrated";   WORK_DESC="delegating across sub-agents" ;;
    Glob)   WORK_STYLE="exploration";    WORK_VERB="Explored";       WORK_DESC="scanning and navigating the codebase" ;;
    *)      WORK_STYLE="session";        WORK_VERB="Worked on";      WORK_DESC="" ;;
  esac

  # Build title: combine verdict-like classification with work style
  local FALLBACK_TITLE
  if [ "$PROMPT_COUNT" = "0" ]; then
    if [ -n "$WORK_STYLE" ] && [ "$WORK_STYLE" != "session" ]; then
      FALLBACK_TITLE="Agent ${WORK_STYLE} of ${PROJECT_NAME}"
    else
      FALLBACK_TITLE="Autonomous session on ${PROJECT_NAME}"
    fi
  elif [ "$PROMPT_COUNT" = "1" ]; then
    FALLBACK_TITLE="One-shot ${WORK_STYLE} on ${PROJECT_NAME}"
  elif [ "$PROMPT_COUNT" -ge 40 ]; then
    FALLBACK_TITLE="Marathon ${WORK_STYLE} on ${PROJECT_NAME}"
  elif [ "$PROMPT_COUNT" -le 4 ] && [ "$BUILD_TIME" -lt 300 ]; then
    FALLBACK_TITLE="Quick ${WORK_STYLE} on ${PROJECT_NAME}"
  elif [ "$PROMPT_COUNT" -ge 8 ] && [ "$BUILD_TIME" -ge 1200 ]; then
    FALLBACK_TITLE="${WORK_VERB} ${PROJECT_NAME}"
  else
    FALLBACK_TITLE="${WORK_VERB} ${PROJECT_NAME}"
  fi

  # Build summary: narrative style instead of raw data dump
  local FALLBACK_SUMMARY
  if [ "$PROMPT_COUNT" = "0" ]; then
    if [ -n "$WORK_DESC" ]; then
      FALLBACK_SUMMARY="Autonomous ${DURATION} agent session ${WORK_DESC}. ${TOKENS} tokens processed using ${MODEL}."
    else
      FALLBACK_SUMMARY="Autonomous ${DURATION} agent session using ${MODEL}. ${TOKENS} tokens processed."
    fi
  else
    if [ -n "$WORK_DESC" ]; then
      FALLBACK_SUMMARY="${DURATION} session ${WORK_DESC}. ${TOKENS} tokens across ${PROMPT_COUNT} prompts using ${MODEL}."
    else
      FALLBACK_SUMMARY="${DURATION} coding session using ${MODEL}. ${TOKENS} tokens across ${PROMPT_COUNT} prompts."
    fi
  fi

  log "FALLBACK: publishing with deterministic summary: title=\"$FALLBACK_TITLE\""
  local BODY
  BODY=$(jq -n --arg title "$FALLBACK_TITLE" --arg summary "$FALLBACK_SUMMARY" '{title: $title, summary: $summary, status: "published"}')
  local RESP
  RESP=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X PATCH "$API_URL/api/builds/$BUILD_ID" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -d "$BODY")
  local STATUS
  STATUS=$(echo "$RESP" | tail -1 | sed 's/HTTP_STATUS://')
  if [ "$STATUS" = "200" ]; then
    log "PUBLISHED: fallback summary applied"
  else
    log "PATCH FAIL (HTTP $STATUS): $(echo "$RESP" | sed '$d')"
  fi
}

# Resolve claude CLI: use pre-resolved path, fall back to PATH lookup
if [ -n "$CLAUDE_BIN" ] && [ -x "$CLAUDE_BIN" ]; then
  CLAUDE_CMD="$CLAUDE_BIN"
elif command -v claude &> /dev/null; then
  CLAUDE_CMD="claude"
else
  log "SKIP: claude CLI not found (resolved='$CLAUDE_BIN', PATH lookup failed)"
  publish_with_fallback "skipped_no_claude" "no_claude_cli"
  exit 0
fi

# Read compact log: prefer pre-extracted file, fall back to transcript parsing
COMPACT_LOG=""
if [ -n "$COMPACT_LOG_FILE" ] && [ -f "$COMPACT_LOG_FILE" ]; then
  COMPACT_LOG=$(cat "$COMPACT_LOG_FILE")
  rm -f "$COMPACT_LOG_FILE"
  log "SOURCE: pre-extracted compact log file"
elif [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  COMPACT_LOG=$(python3 "$SCRIPTS_DIR/parse-transcript.py" --compact-log "$TRANSCRIPT_PATH" "$SESSION_CWD" 2>/dev/null || echo "")
  log "SOURCE: transcript fallback"
fi

if [ -z "$COMPACT_LOG" ]; then
  log "SKIP: empty compact log"
  publish_with_fallback "skipped_empty_log" "empty_compact_log"
  exit 0
fi

# Truncate compact log to ~4000 chars to stay well within Haiku's context window
if [ ${#COMPACT_LOG} -gt 4000 ]; then
  ORIGINAL_LEN=${#COMPACT_LOG}
  COMPACT_LOG="${COMPACT_LOG:0:4000}
... (truncated)"
  log "TRUNCATED: compact log was $ORIGINAL_LEN chars, trimmed to 4000"
fi

# Sanitize project name to prevent prompt injection
PROJECT_NAME=$(echo "$PROJECT_NAME" | tr -cd 'a-zA-Z0-9 _.-')

# Build the prompt — use an alternate template for autonomous (0-prompt) sessions
if [ "$PROMPT_COUNT" = "0" ]; then
PROMPT="You are writing a title and summary for an autonomous agent Build Card — a shareable card showing what an AI agent accomplished without human prompts. This appears in a public community feed.

Project: ${PROJECT_NAME}

Agent session log (no user prompts — the agent ran autonomously):

${COMPACT_LOG}

Title rules:
- 50-80 characters, aim for 8-12 words, sentence case
- Frame as agent work: \"Agent investigated...\", \"Autonomous refactor of...\", \"Agent debugged and fixed...\"
- If the log shows file reads/searches but no edits, frame as research: \"Agent analyzed...\", \"Explored and mapped...\"
- If the log is very sparse, use the project name: \"Autonomous session on ${PROJECT_NAME}\"
- Be specific about WHAT the agent did based on the log evidence
- No quotes.

Summary rules:
- Under 120 characters (~20 words). One sentence. Start with a verb. Past tense.
- What the agent accomplished, not what it did. Outcome over process.
- The \"Session conclusion\" section shows what was completed — prioritize that over early activity
- If the log is sparse, write a minimal honest summary — e.g., \"Explored the codebase and analyzed project structure.\"
- NEVER leave the title or summary blank
- NEVER invent features or changes that aren't evidenced in the session log

Privacy (strict):
- NEVER include: file paths, database table names, endpoint URLs, function names, internal architecture details, credentials, API keys, or code
- Describe what was done in plain language without exposing implementation internals

Format (exact):
TITLE: <title>
SUMMARY: <summary>"
else
PROMPT="You are writing a title and summary for a Build Card — a shareable card showing what a developer built in a coding session. This appears in a public community feed.

Project: ${PROJECT_NAME}

Session log:

${COMPACT_LOG}

Title rules:
- 50-80 characters, aim for 8-12 words, sentence case
- Start with an action verb (Built, Shipped, Rewrote, Added, Designed, Implemented) or name the artifact directly
- Describe the OUTCOME — what changed for users or the product, not the technical implementation
- Be specific: \"Built a real-time notification system with read tracking\" not \"Added notifications\"
- Sound like something you'd share with a friend, not a commit message. No quotes.

Summary rules:
- Under 120 characters (~20 words). One sentence. Start with a verb. Past tense.
- What shipped, not what happened. Outcome over process.
- The \"Session conclusion\" section shows what was completed — prioritize that over early session activity
- Ground every claim in evidence from the session log
- No marketing language, no superlatives, no filler

Sparse session handling:
- If the session log has concrete activity (file edits, tool usage, assistant actions), describe what happened specifically
- If the session log is very thin (few lines, no file edits), write a conservative summary grounded in whatever evidence exists — e.g., \"Explored the codebase and planned the approach for [feature]\" or \"Investigated [area] and prototyped initial changes\"
- NEVER leave the title or summary blank — a brief, honest summary is always better than nothing
- NEVER invent features or changes that aren't evidenced in the session log

Privacy (strict):
- NEVER include: file paths, database table names, endpoint URLs, function names, internal architecture details, credentials, API keys, or code
- Describe what was done in plain language without exposing implementation internals
- Focus on what was accomplished, not tools or process

Format (exact):
TITLE: <title>
SUMMARY: <summary>"
fi

# Call claude CLI
# Log input size for cost estimation (~4 chars/token for Haiku pricing)
PROMPT_CHARS=${#PROMPT}
log "START: calling $CLAUDE_CMD --print --model haiku | prompt_chars=$PROMPT_CHARS compact_log_chars=${#COMPACT_LOG}"
RESPONSE=$(echo "$PROMPT" | PROMPTBOOK_SKIP_HOOKS=1 "$CLAUDE_CMD" --print --model haiku 2>&1 || true)

if [ -z "$RESPONSE" ]; then
  log "FAIL: empty response from claude"
  publish_with_fallback "patch_failed" "empty_claude_response"
  exit 0
fi

RESPONSE_CHARS=${#RESPONSE}
log "RAW: $(echo "$RESPONSE" | head -3)"
log "HAIKU_COST_EST: input_chars=$PROMPT_CHARS output_chars=$RESPONSE_CHARS est_input_tokens=$((PROMPT_CHARS / 4)) est_output_tokens=$((RESPONSE_CHARS / 4))"

# Parse title and summary from response
TITLE=$(echo "$RESPONSE" | grep -i "^TITLE:" | head -1 | sed 's/^TITLE:[[:space:]]*//' || true)
SUMMARY=$(echo "$RESPONSE" | grep -i "^SUMMARY:" | head -1 | sed 's/^SUMMARY:[[:space:]]*//' || true)

if [ -z "$TITLE" ] && [ -z "$SUMMARY" ]; then
  log "FAIL: could not parse title/summary from response: $(echo "$RESPONSE" | head -3)"
  publish_with_fallback "patch_failed" "unparseable_claude_response"
  exit 0
fi

log "OK: title=\"$TITLE\""

# PATCH the build card — also auto-publish now that we have a summary
PATCH_BODY=$(jq -n --arg title "$TITLE" --arg summary "$SUMMARY" '{title: $title, summary: $summary, status: "published"}')

PATCH_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X PATCH "$API_URL/api/builds/$BUILD_ID" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d "$PATCH_BODY")

HTTP_STATUS=$(echo "$PATCH_RESPONSE" | tail -1 | sed 's/HTTP_STATUS://')

if [ "$HTTP_STATUS" = "200" ]; then
  update_summary_status "generated"
  log "PUBLISHED: title + summary applied, card is now public"
else
  BODY=$(echo "$PATCH_RESPONSE" | sed '$d')
  update_summary_status "patch_failed" "patch_http_$HTTP_STATUS"
  log "PATCH FAIL (HTTP $HTTP_STATUS): $BODY"
fi
