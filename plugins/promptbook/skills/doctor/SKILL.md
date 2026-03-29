---
name: doctor
description: Diagnose Promptbook setup — check config, hooks, API key, and session tracking health
---

# Promptbook Doctor

Run diagnostics to check if Promptbook is set up correctly. Execute each check via Bash and report the results.

## Checks

Run these checks in order and report each result:

### 1. Config file exists

```bash
if [ -f "$HOME/.promptbook/config.json" ]; then
  echo "CONFIG_FOUND"
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

### 3. Last session activity
Check for recent session data files to see if hooks are actually firing:

```bash
ls -lt ~/.promptbook/sessions/ 2>/dev/null | head -5
```

If no session files found: hooks may not be firing. Suggest starting a new Claude Code session.

## Report Format

Present results as a clear diagnostic:

```
Promptbook Doctor
─────────────────
✓ Config:    Found (~/.promptbook/config.json)
✓ API Key:   Valid and verified
✓ Activity:  Last session 2 hours ago
```

Use ✓ for passing checks, ✗ for failures, ⚠ for warnings.

## Important
- Run all commands via Bash — the user just reads the report.
- Never display the API key.
- If everything passes, tell the user their setup is healthy.
- If checks fail, give specific actionable steps to fix each issue.
