#!/usr/bin/env node
/**
 * Promptbook — SessionEnd hook.
 * Finalizes the session: records end time, calculates duration, determines language,
 * extracts token usage and file metadata from the transcript.
 * Spawns submit.js as a detached background process for API submission.
 * Completely silent to avoid terminal chatter.
 */
'use strict';

const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const { getDataDir, readStdin, readConfig, acquireLock, releaseLock, atomicWrite, appendLog } = require('./lib/io');
const { getPrimaryLanguage } = require('./lib/language');
const { parseTranscript } = require('./lib/transcript');

const DATA_DIR = getDataDir();
const SCRIPTS_DIR = process.env.CLAUDE_PLUGIN_ROOT
  ? path.join(process.env.CLAUDE_PLUGIN_ROOT, 'scripts')
  : __dirname;

try {
  // Skip if this session was spawned by our own summary generation
  if (process.env.PROMPTBOOK_SKIP_HOOKS === '1') process.exit(0);

  const input = readStdin();
  if (!input || !input.session_id) process.exit(0);

  const sessionsDir = path.join(DATA_DIR, 'sessions');
  const sessionFile = path.join(sessionsDir, `${input.session_id}.json`);

  if (!fs.existsSync(sessionFile)) process.exit(0);

  const transcriptPath = input.transcript_path || '';
  const exitReason = input.reason || 'unknown';

  // Serialize writes against async prompt/edit hooks still flushing data
  acquireLock(sessionFile);
  try {
    const session = JSON.parse(fs.readFileSync(sessionFile, 'utf8'));

    const endTime = new Date().toISOString();
    const startEpoch = new Date(session.start_time).getTime();
    const endEpoch = Date.now();
    const buildTime = Math.round((endEpoch - startEpoch) / 1000);

    // Determine primary language from file extensions
    const language = getPrimaryLanguage(session.file_extensions);

    // Parse transcript for token usage and file metadata
    let transcriptData = null;
    if (transcriptPath && fs.existsSync(transcriptPath)) {
      try {
        transcriptData = parseTranscript(transcriptPath, session.cwd || '');
        if (transcriptData.error) {
          appendLog(DATA_DIR, 'parse-errors.log', transcriptData.error);
          transcriptData = null;
        }
      } catch (err) {
        appendLog(DATA_DIR, 'parse-errors.log', `parse-transcript: ${err.message}`);
      }
    }

    // Update session with all final data
    session.end_time = endTime;
    session.build_time_seconds = buildTime;
    session.language = language;
    session.exit_reason = exitReason;
    session.status = 'completed';

    // Fix model if session-start missed it
    if (session.model === 'unknown' && transcriptData && transcriptData.model) {
      session.model = transcriptData.model;
    }

    if (transcriptData) {
      if (transcriptData.total_tokens != null) {
        session.total_tokens = transcriptData.total_tokens;
        session.input_tokens = transcriptData.input_tokens;
        session.output_tokens = transcriptData.output_tokens;
        session.cache_creation_input_tokens = transcriptData.cache_creation_input_tokens || 0;
        session.cache_read_input_tokens = transcriptData.cache_read_input_tokens || 0;
      }
      if (transcriptData.source_metadata) {
        session.files_touched = transcriptData.files_touched || [];
        session.tool_usage_summary = transcriptData.tool_usage_summary || {};
        session.source_metadata = transcriptData.source_metadata;
      }
    }

    // Write compact log to a file so the detached submit process can read it
    let compactLogFile = '';
    if (transcriptData && transcriptData.compact_log) {
      compactLogFile = path.join(sessionsDir, `${input.session_id}.compact.txt`);
      fs.writeFileSync(compactLogFile, transcriptData.compact_log, 'utf8');
    }

    atomicWrite(sessionFile, session);

    // Skip submission for sessions with no user interaction, very short duration,
    // AND negligible token usage. These are tooling artifacts.
    const promptCount = session.prompt_count || 0;
    const totalTokens = session.total_tokens || 0;
    if (promptCount === 0 && buildTime < 10 && totalTokens < 1000) {
      if (compactLogFile) try { fs.unlinkSync(compactLogFile); } catch { /* ignore */ }
      process.exit(0);
    }

    // Check if config exists for submission
    const config = readConfig();
    if (!config || !config.api_key || !config.api_url) {
      if (compactLogFile) try { fs.unlinkSync(compactLogFile); } catch { /* ignore */ }
      process.exit(0);
    }

    // Resolve full path to claude CLI now (synchronously), so the detached
    // background process doesn't depend on PATH being set correctly.
    let claudeBin = '';
    try {
      const { execSync } = require('child_process');
      claudeBin = execSync('which claude 2>/dev/null || where claude 2>nul', { encoding: 'utf8' }).trim();
    } catch { /* claude CLI not found — submit.js will handle this */ }

    // Build tool summary string for fallback title generation
    const toolSummary = session.source_metadata?.tool_usage_summary || session.tool_usage_summary || {};
    const toolSummaryStr = Object.entries(toolSummary)
      .sort((a, b) => b[1] - a[1])
      .slice(0, 3)
      .map(([k, v]) => `${v} ${k}`)
      .join(', ');

    // Spawn submit.js as a detached background process
    // This lets Claude Code exit immediately without waiting for network calls
    const submitScript = path.join(SCRIPTS_DIR, 'submit.js');
    if (!fs.existsSync(submitScript)) {
      appendLog(DATA_DIR, 'hook-errors.log', `session-end: submit.js not found at ${submitScript}`);
      if (compactLogFile) try { fs.unlinkSync(compactLogFile); } catch { /* ignore */ }
      process.exit(0);
    }
    const child = spawn('node', [submitScript], {
      detached: true,
      stdio: 'ignore',
      env: {
        ...process.env,
        PROMPTBOOK_SKIP_HOOKS: '1',
        PROMPTBOOK_SESSION_ID: input.session_id,
        PROMPTBOOK_SESSION_FILE: sessionFile,
        PROMPTBOOK_TRANSCRIPT_PATH: transcriptPath,
        PROMPTBOOK_COMPACT_LOG_FILE: compactLogFile,
        PROMPTBOOK_API_KEY: config.api_key,
        PROMPTBOOK_API_URL: config.api_url,
        PROMPTBOOK_AUTO_SUMMARY: String(config.auto_summary),
        PROMPTBOOK_CLAUDE_BIN: claudeBin,
        PROMPTBOOK_PROMPT_COUNT: String(promptCount),
        PROMPTBOOK_MODEL: session.model || 'unknown',
        PROMPTBOOK_BUILD_TIME: String(buildTime),
        PROMPTBOOK_TOTAL_TOKENS: String(totalTokens),
        PROMPTBOOK_TOOL_SUMMARY: toolSummaryStr,
        PROMPTBOOK_PROJECT_NAME: session.project_name || '',
        PROMPTBOOK_DATA_DIR: DATA_DIR,
        PROMPTBOOK_SCRIPTS_DIR: SCRIPTS_DIR,
      },
    });
    child.unref();
  } finally {
    releaseLock(sessionFile);
  }
} catch (err) {
  appendLog(DATA_DIR, 'hook-errors.log', `UNCAUGHT session-end: ${err.message}`);
  process.exit(0);
}
