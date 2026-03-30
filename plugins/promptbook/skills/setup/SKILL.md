---
name: setup
description: Set up Promptbook — connect your account to start tracking builds
---

# Promptbook Setup

Help the user connect their Promptbook account using the device-code auth flow. Run all commands yourself via Bash — the user just waits for the browser sign-in.

## Privacy note
Only aggregate stats (prompt count, tokens, build time, lines changed) are sent to Promptbook servers. No source code or prompt content is ever sent to promptbook.gg. To generate a title and summary for each build, the plugin calls Claude Haiku via the user's own Claude credentials — this data goes to Anthropic (same as normal Claude Code usage), never to Promptbook.

## Steps

1. **Create a setup session** by calling the API. Run this via Bash:
   ```bash
   curl -sL -X POST "https://promptbook.gg/api/auth/setup-session"
   ```
   Parse the JSON response to extract three values: `token`, `device_code`, and `setup_url`.

2. **Open the browser** for the user to sign in. Use the `setup_url` value from step 1:
   ```bash
   open "<setup_url value>"   # macOS
   xdg-open "<setup_url value>"  # Linux
   ```
   Tell the user: "Opening promptbook.gg — sign in or create an account to continue."
   If the browser can't be opened, show them the URL to open manually.

3. **Poll for authorization** — check every 2 seconds using the `token` value from step 1:
   ```bash
   curl -sL "https://promptbook.gg/api/auth/setup-session/<token value>/status"
   ```
   Parse the JSON response and check whether the `status` field equals `"authorized"`. Use a unique variable name like `poll_result` or `auth_status` to avoid colliding with shell built-ins (do NOT use a variable named `status`). Timeout after 5 minutes.

4. **Exchange the device code for an API key** using the `device_code` value from step 1. Use double quotes so the variable interpolates:
   ```bash
   curl -sL -X POST "https://promptbook.gg/api/auth/setup-session/exchange" \
     -H "Content-Type: application/json" \
     -d "{\"device_code\": \"<device_code value>\"}"
   ```
   Parse the JSON response to extract `api_key`.

5. **Save the config** to `~/.promptbook/config.json`. This is the canonical config location shared by both plugin and bash installs:
   ```bash
   mkdir -p "$HOME/.promptbook"
   cat > "$HOME/.promptbook/config.json" << 'JSONEOF'
   {
     "api_key": "<api_key from step 4>",
     "api_url": "https://promptbook.gg",
     "auto_summary": true
   }
   JSONEOF
   chmod 600 "$HOME/.promptbook/config.json"
   ```

6. **Verify setup** with the server using the api_key from step 4:
   ```bash
   curl -sL -X POST "https://promptbook.gg/api/auth/verify-setup" \
     -H "Authorization: Bearer <api_key value>"
   ```

7. **Confirm completion.** Tell the user:
   - "You're all set! Tracking starts on your **next** Claude Code session."
   - "Here's how it works: when you start a new session, the plugin automatically tracks your prompts, tokens, build time, and lines changed. When the session ends, it creates a build on promptbook.gg with a link you can share."
   - "This current session won't be tracked — start a new one to see it in action."
   - "Run `/setup` again anytime to reconnect or switch accounts."

8. **Offer history backfill.** After setup is complete, ask the user: "Want me to scan your Claude Code history for past sessions? I can find builds from the last 90 days and upload them to your profile."

   If they say yes, first find the backfill script. Check these paths in order:
   - `~/.promptbook/hooks/backfill-history.js` (bash install)
   - The plugin's own scripts directory (find it with: `find ~/.claude -path "*/promptbook/scripts/backfill-history.js" -type f 2>/dev/null | head -1`)

   If neither exists, download it:
   ```bash
   mkdir -p ~/.promptbook/hooks/lib
   for f in backfill-history.js lib/io.js lib/transcript.js lib/language.js lib/summary.js; do
     curl -sfL "https://promptbook.gg/hooks/$f" -o "$HOME/.promptbook/hooks/$f"
   done
   ```

   Then run it:
   ```bash
   node <path-to-backfill-history.js> \
     --days 90 \
     --api-url "https://promptbook.gg" \
     --api-key "<api_key from step 4>" \
     --generate-summaries
   ```
   The script scans local JSONL transcripts and uploads aggregate stats (never code or prompts). It outputs a batch ID on stdout.
   If the batch ID is returned, tell the user: "Sessions uploaded! Review and import them at https://promptbook.gg/setup/history"
   If the user declines, that's fine — they can always run it later.

## Important
- Run all curl commands via Bash, not by asking the user to do anything.
- The entire flow should be automated — the user just waits for the browser sign-in.
- If any step fails, give a clear error message and suggest running `/setup` again.
- Never display the API key to the user.
