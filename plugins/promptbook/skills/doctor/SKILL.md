---
name: doctor
description: Diagnose Promptbook setup — check config, hooks, API key, and session tracking health
---

# Promptbook Doctor

Run diagnostics to check if Promptbook is set up correctly. Execute each check via Bash and report the results.

## Checks

Run these checks in order and report each result:

### 1. Config file exists
Check if the config file exists at `$CLAUDE_PLUGIN_DATA/config.json` (plugin install) or `~/.promptbook/config.json` (bash install).

```bash
if [ -f "${CLAUDE_PLUGIN_DATA:-/nonexistent}/config.json" ]; then
  echo "PLUGIN_CONFIG"
  cat "${CLAUDE_PLUGIN_DATA}/config.json"
elif [ -f "$HOME/.promptbook/config.json" ]; then
  echo "BASH_CONFIG"
  cat "$HOME/.promptbook/config.json"
else
  echo "NO_CONFIG"
fi
```

If no config file found: tell the user to run `/setup` first.

### 2. API key is valid
Extract the `api_key` from the config file found in step 1 and test it:

```bash
curl -sL -o /dev/null -w "%{http_code}" -X POST "https://promptbook.gg/api/auth/verify-setup" \
  -H "Authorization: Bearer <api_key>"
```

- 200 = valid and verified
- 401 = invalid key — suggest running `/setup` again
- Other = network issue — suggest checking connectivity

### 3. Hooks are registered
Check if hooks are configured. For plugin installs, check `hooks.json` in the plugin directory. For bash installs, check `~/.claude/settings.json`:

```bash
# Check settings.json for Promptbook hooks
if [ -f "$HOME/.claude/settings.json" ]; then
  node -e "
    const s = JSON.parse(require('fs').readFileSync(process.env.HOME + '/.claude/settings.json', 'utf8'));
    const h = s.hooks || {};
    const events = ['SessionStart', 'UserPromptSubmit', 'PostToolUse', 'SessionEnd'];
    for (const e of events) {
      const found = (h[e] || []).some(entry =>
        JSON.stringify(entry).includes('promptbook')
      );
      console.log(e + ': ' + (found ? 'OK' : 'MISSING'));
    }
  "
fi
```

If any hooks are missing: suggest re-running setup.

### 4. jq is available (bash install only)
If the user has a bash install (step 1 found `BASH_CONFIG`), check if `jq` is installed:

```bash
command -v jq &>/dev/null && echo "OK" || echo "MISSING"
```

If missing: warn that hooks may fail silently. Suggest `brew install jq` (macOS) or `apt install jq` (Linux). Note: this dependency will be removed in a future update.

### 5. Last session activity
Check for recent session data files to see if hooks are actually firing:

```bash
# Check for recent session state files
ls -lt ~/.promptbook/sessions/ 2>/dev/null | head -5
# Also check for any JSONL files modified recently
find ~/.claude/projects -name "*.jsonl" -type f -newer ~/.promptbook/config.json 2>/dev/null | head -3
```

If no session files found since config was created: hooks may not be firing.

## Report Format

Present results as a clear diagnostic:

```
Promptbook Doctor
─────────────────
✓ Config:    Found (~/.promptbook/config.json)
✓ API Key:   Valid and verified
✓ Hooks:     All 4 events registered
⚠ jq:        Not installed — hooks may fail silently
✓ Activity:  Last session 2 hours ago

Recommendation: Install jq with `brew install jq` to ensure hooks work correctly.
```

Use ✓ for passing checks, ✗ for failures, ⚠ for warnings.

## Important
- Run all commands via Bash — the user just reads the report.
- Never display the API key.
- If everything passes, tell the user their setup is healthy.
- If checks fail, give specific actionable steps to fix each issue.
