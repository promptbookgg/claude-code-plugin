#!/usr/bin/env node
/**
 * Promptbook — SessionStart hook.
 * Creates a new session tracking file and injects recent session context.
 *
 * Input (stdin JSON): { session_id, model, cwd, hook_event_name }
 * Output (stdout): Recent session summaries (injected as Claude Code context)
 * Output (stderr): Notification message (shown in terminal)
 */
'use strict';

const fs = require('fs');
const path = require('path');
const { getDataDir, readStdin, readConfig, appendLog } = require('./lib/io');
const { deriveProjectName } = require('./lib/language');

const DATA_DIR = getDataDir();

async function main() {
  const input = readStdin();
  if (!input || !input.session_id) return;

  const sessionsDir = path.join(DATA_DIR, 'sessions');
  fs.mkdirSync(sessionsDir, { recursive: true });

  const sessionId = input.session_id;

  // Extract model — try multiple field paths (Claude Code format varies)
  let model = 'unknown';
  if (typeof input.model === 'string' && input.model) {
    model = input.model;
  } else if (input.model && typeof input.model === 'object') {
    model = input.model.id || input.model.name || input.model.display_name || input.model.model || 'unknown';
  } else {
    model = input.model_name || input.modelName || input.session_model || input.sessionModel || 'unknown';
  }
  if (!model || model === 'null') {
    model = 'unknown';
    appendLog(DATA_DIR, 'hook-errors.log', `WARN: SessionStart missing model field. Keys: ${Object.keys(input).sort().join(',')}`);
  }

  const cwd = input.cwd || '';
  const timestamp = new Date().toISOString();
  const projectName = deriveProjectName(cwd);

  // Write session file
  const session = {
    session_id: sessionId,
    project_name: projectName,
    model,
    ai_tool: 'claude-code',
    start_time: timestamp,
    end_time: null,
    build_time_seconds: null,
    prompt_count: 0,
    lines_changed: 0,
    cwd,
    file_extensions: {},
    status: 'active',
  };

  const sessionFile = path.join(sessionsDir, `${sessionId}.json`);
  fs.writeFileSync(sessionFile, JSON.stringify(session, null, 2), 'utf8');

  // --- Session context injection ---
  // Fetch recent session summaries from Promptbook API and print to stdout.
  // Claude Code injects stdout from SessionStart hooks as conversation context.
  // Fails silently — if the API is unreachable, Claude Code works normally.
  const config = readConfig(DATA_DIR);
  if (config && config.api_key && config.api_url) {
    const encodedProject = encodeURIComponent(projectName);
    const url = `${config.api_url}/api/hooks/session-context?project_name=${encodedProject}`;

    try {
      const res = await fetch(url, {
        headers: { Authorization: `Bearer ${config.api_key}` },
        signal: AbortSignal.timeout(2000),
      });

      if (res.ok) {
        const context = await res.text();
        if (context) {
          const firstLine = context.split('\n')[0];
          if (firstLine && firstLine.startsWith('##')) {
            // stdout: injected as conversation context by Claude Code
            process.stdout.write(`## Promptbook — here is what was built recently on ${projectName}\n\n`);
            const rest = context.split('\n').slice(1).join('\n');
            process.stdout.write(rest + '\n');

            // stderr: visible notification (not injected as context)
            const sessionCount = (context.match(/^### /gm) || []).length;
            process.stderr.write(`[promptbook] ${sessionCount} recent session(s) loaded as context\n`);
          }
        }
      }
    } catch {
      // Silent failure — Claude Code works normally without context
    }
  }
}

main().catch(err => {
  appendLog(DATA_DIR, 'hook-errors.log', `UNCAUGHT session-start: ${err.message}`);
});
