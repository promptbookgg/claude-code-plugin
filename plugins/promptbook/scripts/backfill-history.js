#!/usr/bin/env node
/**
 * Promptbook — Historic Data Sync (Backfill)
 *
 * Scans local Claude Code JSONL transcripts and submits aggregate stats
 * as backfill Build Cards. Uses the same parsing logic as the live hooks.
 *
 * Never sends prompts, code, or file contents — only aggregate stats.
 *
 * Usage:
 *   node backfill-history.js [--days N] [--dry-run] [--json] [--project DIR]
 *                            [--before DATE] [--generate-summaries]
 *                            [--api-url URL] [--api-key KEY]
 */
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');
const { execSync, execFileSync } = require('child_process');
const { parseTranscript } = require('./lib/transcript');
const { getPrimaryLanguage, deriveProjectName } = require('./lib/language');
const { buildSummaryPrompt, generateFallbackTitle, generateFallbackSummary } = require('./lib/summary');

// --- CLI argument parsing ---
const args = process.argv.slice(2);
function getArg(name, defaultVal) {
  const idx = args.indexOf(`--${name}`);
  if (idx === -1) return defaultVal;
  if (typeof defaultVal === 'boolean') return true;
  return args[idx + 1] || defaultVal;
}
const DAYS = Number(getArg('days', '30'));
const DRY_RUN = getArg('dry-run', false);
const JSON_MODE = getArg('json', false);
const PROJECT_FILTER = getArg('project', '');
const BEFORE = getArg('before', '');
const GENERATE_SUMMARIES = getArg('generate-summaries', false);
const API_URL_ARG = getArg('api-url', '');
const API_KEY_ARG = getArg('api-key', '');

// --- Helpers ---
function log(msg) {
  process.stderr.write(msg + '\n');
}

/**
 * Count real user prompts in a JSONL file.
 * Only counts type=user entries with actual text content (not empty tool results).
 */
function countPrompts(jsonlPath) {
  let count = 0;
  const content = fs.readFileSync(jsonlPath, 'utf8');
  for (const line of content.split('\n')) {
    if (!line.trim()) continue;
    let entry;
    try { entry = JSON.parse(line); } catch { continue; }
    if (entry.type !== 'user') continue;
    const msg = entry.message || {};
    const c = typeof msg === 'object' ? msg.content : undefined;
    if (typeof c === 'string' && c.trim().length > 0) {
      count++;
    } else if (Array.isArray(c)) {
      if (c.some(b => b && b.type === 'text' && typeof b.text === 'string' && b.text.trim().length > 0)) {
        count++;
      }
    }
  }
  return count;
}

/**
 * Extract timestamps from JSONL entries for session duration.
 */
function extractTimestamps(jsonlPath) {
  const timestamps = [];
  const content = fs.readFileSync(jsonlPath, 'utf8');
  for (const line of content.split('\n')) {
    if (!line.trim()) continue;
    let entry;
    try { entry = JSON.parse(line); } catch { continue; }
    const ts = entry.timestamp;
    if (ts && typeof ts === 'string') {
      const d = new Date(ts);
      if (!isNaN(d.getTime())) timestamps.push(d);
    }
  }
  return timestamps;
}

/**
 * Count lines changed from tool_use blocks in the JSONL (same logic as track-edits.js).
 */
function countLinesChanged(jsonlPath) {
  let linesChanged = 0;
  const content = fs.readFileSync(jsonlPath, 'utf8');
  for (const line of content.split('\n')) {
    if (!line.trim()) continue;
    let entry;
    try { entry = JSON.parse(line); } catch { continue; }
    if (entry.type !== 'assistant') continue;
    const msg = entry.message || {};
    const blocks = msg.content;
    if (!Array.isArray(blocks)) continue;
    for (const block of blocks) {
      if (!block || block.type !== 'tool_use') continue;
      const toolName = block.name || '';
      const toolInput = block.input || {};
      if (toolName === 'Write') {
        const c = toolInput.content || '';
        if (c) linesChanged += c.split('\n').length;
      } else if (toolName === 'Edit') {
        const newStr = toolInput.new_string || '';
        const oldStr = toolInput.old_string || '';
        if (newStr) {
          const diff = Math.abs(newStr.split('\n').length - (oldStr ? oldStr.split('\n').length : 0));
          linesChanged += diff || (newStr ? 1 : 0);
        }
      } else if (toolName === 'NotebookEdit') {
        const src = toolInput.new_source || '';
        linesChanged += src ? src.split('\n').length : 1;
      }
    }
  }
  return linesChanged;
}

/**
 * Find JSONL session files from the last N days.
 */
function findJsonlFiles() {
  const claudeDir = path.join(os.homedir(), '.claude', 'projects');
  if (!fs.existsSync(claudeDir)) {
    log(`No Claude Code projects found at ${claudeDir}`);
    return [];
  }

  const afterCutoff = Date.now() - (DAYS * 86400 * 1000);
  const beforeCutoff = BEFORE ? new Date(BEFORE).getTime() : null;
  const files = [];

  for (const dirName of fs.readdirSync(claudeDir)) {
    const projectDir = path.join(claudeDir, dirName);
    if (!fs.statSync(projectDir).isDirectory()) continue;

    if (PROJECT_FILTER) {
      const decoded = dirName.split('-').filter(Boolean).pop() || dirName;
      if (!dirName.toLowerCase().includes(PROJECT_FILTER.toLowerCase()) &&
          decoded.toLowerCase() !== PROJECT_FILTER.toLowerCase()) {
        continue;
      }
    }

    for (const file of fs.readdirSync(projectDir)) {
      if (!file.endsWith('.jsonl')) continue;
      const filePath = path.join(projectDir, file);
      try {
        const stat = fs.statSync(filePath);
        if (!stat.isFile()) continue;
        const mtime = stat.mtimeMs;
        if (mtime >= afterCutoff && (!beforeCutoff || mtime < beforeCutoff)) {
          files.push(filePath);
        }
      } catch { continue; }
    }
  }

  return files.sort((a, b) => fs.statSync(a).mtimeMs - fs.statSync(b).mtimeMs);
}

/**
 * Parse a single JSONL session file into a build record.
 * Uses the shared lib/ modules (same code as live hooks).
 */
function parseSession(jsonlPath) {
  const sessionId = path.basename(jsonlPath, '.jsonl');
  const projectDirName = path.basename(path.dirname(jsonlPath));

  // Decode the Claude Code directory name back to a real path, then use shared
  // deriveProjectName() which handles git worktrees.
  // Format: -Users-foo-Desktop-myproject → /Users/foo/Desktop/myproject
  const decodedPath = '/' + projectDirName.replace(/^-/, '').replace(/-/g, '/');
  const projectName = deriveProjectName(decodedPath);

  // Extract timestamps for session duration
  const timestamps = extractTimestamps(jsonlPath);
  if (timestamps.length < 2) return null;

  const startTime = new Date(Math.min(...timestamps.map(t => t.getTime())));
  const endTime = new Date(Math.max(...timestamps.map(t => t.getTime())));
  const buildTimeSeconds = Math.round((endTime - startTime) / 1000);

  if (buildTimeSeconds < 5) return null;

  // Count real user prompts (same logic as UserPromptSubmit hook)
  const promptCount = countPrompts(jsonlPath);

  // Parse transcript using shared lib (same code as session-end.js)
  const transcript = parseTranscript(jsonlPath, '');
  if (transcript.error) return null;
  if (!transcript.model) return null;

  const totalTokens = transcript.total_tokens || 0;

  // Skip noise (same filter as session-end.js)
  if (promptCount === 0 && buildTimeSeconds < 10 && totalTokens < 1000) return null;
  if (totalTokens === 0 && promptCount === 0) return null;

  // Count lines changed (same logic as track-edits.js)
  const linesChanged = countLinesChanged(jsonlPath);

  // Language detection using shared lib (same as session-end.js)
  const fileExtensions = transcript.source_metadata?.file_extensions || {};
  const language = getPrimaryLanguage(fileExtensions);

  // Tool summary for fallback title generation
  const toolSummary = transcript.tool_usage_summary || {};
  const toolSummaryStr = Object.entries(toolSummary)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 3)
    .map(([k, v]) => `${v} ${k}`)
    .join(', ');

  return {
    session_id: sessionId,
    project_name: projectName,
    model: transcript.model,
    ai_tool: 'claude-code',
    start_time: startTime.toISOString(),
    end_time: endTime.toISOString(),
    build_time_seconds: buildTimeSeconds,
    prompt_count: promptCount,
    lines_changed: linesChanged || null,
    language,
    status: 'completed',
    total_tokens: totalTokens,
    input_tokens: transcript.input_tokens || 0,
    output_tokens: transcript.output_tokens || 0,
    cache_creation_input_tokens: transcript.cache_creation_input_tokens || 0,
    cache_read_input_tokens: transcript.cache_read_input_tokens || 0,
    source: 'backfill',
    source_metadata: {
      file_extensions: fileExtensions,
      tool_usage_summary: toolSummary,
    },
    // Kept locally for summary generation — stripped before upload
    _compact_log: transcript.compact_log || '',
    _tool_summary_str: toolSummaryStr,
    _jsonl_path: jsonlPath,
  };
}

/**
 * Generate a title and summary for a session using Haiku (or fallback).
 * Same logic as submit.js generateAndPublish().
 */
function generateSummary(session) {
  let compactLog = session._compact_log || '';
  if (!compactLog) return null;

  // Truncate to ~4000 chars
  if (compactLog.length > 4000) {
    compactLog = compactLog.slice(0, 4000) + '\n... (truncated)';
  }

  // Try Haiku via claude CLI
  let claudeCmd = '';
  try {
    claudeCmd = execSync('which claude 2>/dev/null || where claude 2>nul', { encoding: 'utf8' }).trim();
  } catch { /* not found */ }

  if (claudeCmd) {
    try {
      const prompt = buildSummaryPrompt(compactLog, session.project_name, session.prompt_count);
      const response = execFileSync(claudeCmd, ['--print', '--model', 'haiku'], {
        input: prompt,
        encoding: 'utf8',
        timeout: 60000,
        env: { ...process.env, PROMPTBOOK_SKIP_HOOKS: '1' },
      });

      if (response) {
        const titleMatch = response.match(/^TITLE:\s*(.+)/im);
        const summaryMatch = response.match(/^SUMMARY:\s*(.+)/im);
        if (titleMatch || summaryMatch) {
          return {
            title: titleMatch ? titleMatch[1].trim() : '',
            summary: summaryMatch ? summaryMatch[1].trim() : '',
          };
        }
      }
    } catch (err) {
      log(`  Haiku failed for ${session.session_id.slice(0, 8)}...: ${err.message}`);
    }
  }

  // Fallback: deterministic title/summary (same as submit.js)
  return {
    title: generateFallbackTitle(
      session.prompt_count, session.build_time_seconds,
      session.project_name, session._tool_summary_str
    ),
    summary: generateFallbackSummary(
      session.prompt_count, session.build_time_seconds,
      session.total_tokens, session.model, session._tool_summary_str
    ),
  };
}

/**
 * Upload sessions to the backfill batch endpoint.
 */
async function uploadBatch(sessions, apiUrl, apiKey) {
  const chunkSize = 50;
  let batchId = null;

  for (let i = 0; i < sessions.length; i += chunkSize) {
    const chunk = sessions.slice(i, i + chunkSize);

    // Strip internal fields before upload
    const cleaned = chunk.map(s => {
      const { _compact_log, _tool_summary_str, _jsonl_path, ...rest } = s;
      return rest;
    });

    try {
      const response = await fetch(`${apiUrl}/api/backfill/upload`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${apiKey}`,
        },
        body: JSON.stringify({ days_scanned: DAYS, sessions: cleaned }),
        signal: AbortSignal.timeout(30000),
      });

      if (!response.ok) {
        const body = await response.text();
        log(`  Upload failed (HTTP ${response.status}): ${body}`);
        if ([401, 403, 500].includes(response.status)) {
          log('  Stopping due to server error.');
          break;
        }
        continue;
      }

      const body = await response.json();
      if (!batchId) batchId = body.batch_id;
      log(`  Uploaded ${body.uploaded || 0} sessions (${body.duplicates || 0} duplicates)`);
    } catch (err) {
      log(`  Upload failed: ${err.message}`);
      break;
    }

    // Brief pause between chunks for rate limiting
    if (i + chunkSize < sessions.length) {
      await new Promise(r => setTimeout(r, 2000));
    }
  }

  return batchId;
}

// --- Main ---
async function main() {
  // Load config
  let apiUrl = API_URL_ARG;
  let apiKey = API_KEY_ARG;
  const needsConfig = !DRY_RUN && !JSON_MODE;

  if (needsConfig && !apiUrl) {
    const configPath = path.join(os.homedir(), '.promptbook', 'config.json');
    if (!fs.existsSync(configPath)) {
      log('Error: ~/.promptbook/config.json not found. Run the Promptbook setup first.');
      process.exit(1);
    }
    const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    apiUrl = apiUrl || config.api_url || '';
    apiKey = apiKey || config.api_key || '';
    if (!apiUrl || !apiKey) {
      log('Error: config.json missing api_url or api_key');
      process.exit(1);
    }
  }

  // Find sessions
  if (!JSON_MODE) log(`Scanning for sessions from the last ${DAYS} days...`);
  const jsonlFiles = findJsonlFiles();
  if (!JSON_MODE) log(`Found ${jsonlFiles.length} session files`);

  if (jsonlFiles.length === 0) {
    if (JSON_MODE) process.stdout.write('[]');
    else log('Nothing to backfill.');
    return;
  }

  // Parse all sessions
  const sessions = [];
  let skipped = 0;
  for (const filePath of jsonlFiles) {
    const session = parseSession(filePath);
    if (session) sessions.push(session);
    else skipped++;
  }

  if (!JSON_MODE) log(`Parsed ${sessions.length} sessions (${skipped} skipped)`);

  // Generate summaries if requested
  if (GENERATE_SUMMARIES && sessions.length > 0) {
    log(`Generating summaries for ${sessions.length} sessions...`);
    for (let i = 0; i < sessions.length; i++) {
      const s = sessions[i];
      const result = generateSummary(s);
      if (result) {
        s.title = result.title;
        s.summary = result.summary;
        if (!JSON_MODE) {
          const label = result.title.length > 50 ? result.title.slice(0, 50) + '...' : result.title;
          log(`  [${i + 1}/${sessions.length}] ${label}`);
        }
      }
    }
  }

  // --json mode
  if (JSON_MODE) {
    const cleaned = sessions.map(s => {
      const { _compact_log, _tool_summary_str, _jsonl_path, ...rest } = s;
      return rest;
    });
    process.stdout.write(JSON.stringify(cleaned));
    return;
  }

  // --dry-run mode
  if (DRY_RUN) {
    for (let i = 0; i < sessions.length; i++) {
      const s = sessions[i];
      log(`  [${i + 1}/${sessions.length}] ${s.project_name}: ` +
        `${s.prompt_count} prompts, ${s.total_tokens.toLocaleString()} tokens, ` +
        `${s.build_time_seconds}s, ${s.lines_changed || 0} lines, model=${s.model}`);
    }
    log(`\nDone: ${sessions.length} sessions found, ${skipped} empty/invalid`);
    return;
  }

  // Upload
  if (sessions.length === 0) {
    log('No sessions to upload.');
    return;
  }

  const batchId = await uploadBatch(sessions, apiUrl, apiKey);
  if (batchId) {
    log(`Batch ${batchId}: ${sessions.length} sessions uploaded`);
    process.stdout.write(batchId); // stdout: just the batch_id for script consumption
  } else {
    log('Upload failed — no batch created.');
    process.exit(1);
  }
}

main().catch(err => {
  log(`Fatal: ${err.message}`);
  process.exit(1);
});
