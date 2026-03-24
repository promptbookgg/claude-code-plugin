# Promptbook — Claude Code Plugin

Build better. See your progress. Post the proof.

Every Claude Code session becomes a shareable Build Card on [promptbook.gg](https://promptbook.gg) — verified stats, no self-reporting.

## Install

```
/plugin marketplace add promptbookgg/claude-code-plugin
/plugin install promptbook
```

Then run `/promptbook:setup` to connect your account.

## What it tracks

- Prompt count
- Token usage (input, output, cache)
- Build time
- Lines changed
- Primary language

That's it. No source code. No prompt content. Only aggregate stats are sent to Promptbook.

## How it works

The plugin registers four Claude Code hooks:

| Event | What it does |
|---|---|
| **SessionStart** | Creates a session file, loads recent context |
| **UserPromptSubmit** | Counts prompts |
| **PostToolUse** | Counts lines changed, tracks file types |
| **SessionEnd** | Finalizes stats, submits to promptbook.gg |

After each session, you'll see a link to your Build Card. Customize the title, summary, and screenshot on the web — then share it.

## Privacy

Only aggregate stats leave your machine. The plugin also generates a short title and summary for each card by calling Claude Haiku through your own Claude credentials — this goes to Anthropic (same as any Claude Code usage), never to Promptbook.

You can audit everything: the hooks are right here in this repo.

## Alternative install

If you prefer a one-command setup without the plugin system:

```bash
bash <(curl -sL promptbook.gg/setup.sh)
```

## Links

- [promptbook.gg](https://promptbook.gg) — the product
- [Discover feed](https://promptbook.gg) — see what others are building
- [Setup guide](https://promptbook.gg/setup) — browser-based setup flow
