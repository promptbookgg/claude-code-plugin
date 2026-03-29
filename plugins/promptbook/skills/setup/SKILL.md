---
name: setup
description: Set up Promptbook — connect your account to start tracking builds
disable-model-invocation: true
---

# Promptbook Setup

Help the user connect their Promptbook account using the device-code auth flow. Run all commands yourself via Bash — the user just waits for the browser sign-in.

## Privacy note
Only aggregate stats (prompt count, tokens, build time, lines changed) are sent to Promptbook servers. No source code or prompt content is ever sent to promptbook.gg. To generate a title and summary for each Build Card, the plugin calls Claude Haiku via the user's own Claude credentials — this data goes to Anthropic (same as normal Claude Code usage), never to Promptbook.

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
   Wait until the response JSON has `status` equal to `"authorized"` (timeout after 5 minutes).

4. **Exchange the device code for an API key** using the `device_code` value from step 1. Use double quotes so the variable interpolates:
   ```bash
   curl -sL -X POST "https://promptbook.gg/api/auth/setup-session/exchange" \
     -H "Content-Type: application/json" \
     -d "{\"device_code\": \"<device_code value>\"}"
   ```
   Parse the JSON response to extract `api_key`.

5. **Save the config** to the plugin's persistent data directory. The environment variable `CLAUDE_PLUGIN_DATA` contains the path. Write to `$CLAUDE_PLUGIN_DATA/config.json`:
   ```json
   {
     "api_key": "<api_key from step 4>",
     "api_url": "https://promptbook.gg",
     "auto_summary": true
   }
   ```
   Set file permissions to 600 (user read/write only).

6. **Verify setup** with the server using the api_key from step 4:
   ```bash
   curl -sL -X POST "https://promptbook.gg/api/auth/verify-setup" \
     -H "Authorization: Bearer <api_key value>"
   ```

7. **Confirm completion.** Tell the user:
   - "You're all set. Every Claude Code session will now automatically create a Build Card on promptbook.gg."
   - "You'll see a link after each session ends."
   - "Run `/promptbook:setup` again anytime to reconnect or switch accounts."

## Important
- Run all curl commands via Bash, not by asking the user to do anything.
- The entire flow should be automated — the user just waits for the browser sign-in.
- If any step fails, give a clear error message and suggest running `/promptbook:setup` again.
- Never display the API key to the user.
