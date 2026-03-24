#!/usr/bin/env python3
"""Promptbook — Transcript parser for token tracking + file metadata.

Reads a Claude Code transcript JSONL file and extracts:
- Token usage (input_tokens, output_tokens, total_tokens)
- Files touched (file paths from Read/Write/Edit tool uses)
- Tool usage summary (counts per tool name)
- Compact session log for auto-summary (file paths + assistant first-lines)

Called by session-end.sh. Outputs JSON to stdout.

Usage:
  python3 parse-transcript.py <transcript_path> [cwd]           — full parse
  python3 parse-transcript.py --compact-log <transcript_path> [cwd]  — compact log only
"""

import json
import os
import sys


def _sanitize_text(text: str) -> str:
    """Remove control characters that break JSON encoding."""
    return "".join(c if c >= " " or c in ("\n", "\t") else " " for c in text)


def sanitize_path(file_path: str, cwd: str, home: str) -> str:
    if not file_path:
        return ""

    normalized = os.path.normpath(os.path.expanduser(file_path))

    if cwd and os.path.isabs(normalized):
        try:
            relative = os.path.relpath(normalized, cwd)
            if relative != ".." and not relative.startswith(f"..{os.sep}"):
                return relative
        except ValueError:
            pass

    if home and normalized.startswith(f"{home}{os.sep}"):
        return normalized[len(home) + 1 :]

    if os.path.isabs(normalized):
        return os.path.basename(normalized)

    return normalized.lstrip("./")


def _format_compact_log(
    assistant_first_lines: list[str],
    assistant_full_blocks: list[str],
    files_seen: set[str],
    tool_counts: dict[str, int],
) -> str:
    """Format extracted data into a budget-allocated text log for auto-summary.

    Budget allocation (~4000 chars total):
    - ~800 chars: structured metadata (files touched, tool counts)
    - ~1200 chars: session conclusion (last 5-10 complete assistant blocks)
    - ~2000 chars: sparse sample from earlier session activity for arc context
    """
    parts: list[str] = []

    # --- Zone 1: Metadata (~800 chars) ---
    metadata_parts: list[str] = []
    if files_seen:
        metadata_parts.append("Files touched:")
        for fp in sorted(files_seen):
            metadata_parts.append(f"  {fp}")
    if tool_counts:
        tools_str = ", ".join(f"{v} {k}" for k, v in sorted(tool_counts.items(), key=lambda x: -x[1]))
        metadata_parts.append(f"Tool usage: {tools_str}")
    metadata_text = "\n".join(metadata_parts)
    if len(metadata_text) > 800:
        metadata_text = metadata_text[:800] + "\n..."
    if metadata_text:
        parts.append(metadata_text)

    # --- Zone 2: Session conclusion (~1200 chars) ---
    # Last 5-10 complete assistant blocks — these describe what was finished
    conclusion_blocks = assistant_full_blocks[-10:]
    if conclusion_blocks:
        conclusion_lines: list[str] = []
        total_chars = 0
        for block in reversed(conclusion_blocks):
            if total_chars + len(block) > 1200:
                break
            conclusion_lines.insert(0, f"  - {block}")
            total_chars += len(block)
        if conclusion_lines:
            parts.append("\nSession conclusion (what was completed):")
            parts.extend(conclusion_lines)

    # --- Zone 3: Earlier session activity (~2000 chars) ---
    # Sparse sample from the rest of the session for overall arc context
    # Exclude the last 10 (already in conclusion)
    earlier_lines = assistant_first_lines[:-10] if len(assistant_first_lines) > 10 else []
    if earlier_lines:
        # Sample evenly across the session
        if len(earlier_lines) > 30:
            step = max(1, len(earlier_lines) // 30)
            earlier_lines = earlier_lines[::step][:30]
        sampled: list[str] = []
        total_chars = 0
        for line in earlier_lines:
            if total_chars + len(line) > 2000:
                break
            sampled.append(f"  - {line}")
            total_chars += len(line)
        if sampled:
            parts.append("\nEarlier session activity:")
            parts.extend(sampled)

    return "\n".join(parts)


def _scan_transcript(path: str, cwd: str = "", home: str = "", compact_only: bool = False) -> dict:
    """Single-pass scan of a transcript JSONL file.

    Extracts tokens, file metadata, tool usage, AND compact log data
    in one read. When compact_only=True, skips token tracking and
    file extension counting.
    """
    # Token tracking (skipped in compact_only mode)
    total_output_tokens = 0
    last_input_tokens = 0
    last_cache_creation = 0
    last_cache_read = 0
    # Cumulative sums for cost calculation (sum across ALL requests)
    sum_fresh_input = 0
    sum_cache_creation = 0
    sum_cache_read = 0

    # Model extraction — grab from first assistant message
    model: str = ""

    # Shared between full parse and compact log
    files_touched: set[str] = set()
    tool_counts: dict[str, int] = {}
    file_extensions: dict[str, int] = {}

    # Compact log: first-lines for sparse sampling, full blocks for conclusion
    assistant_lines: list[str] = []
    assistant_full_blocks: list[str] = []

    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue

            if entry.get("type") != "assistant":
                continue

            message = entry.get("message", {})

            # --- Model extraction (first assistant message wins) ---
            if not model:
                m = message.get("model", "")
                if m and isinstance(m, str):
                    model = m

            # --- Token tracking (full mode only) ---
            if not compact_only:
                usage = message.get("usage")
                if usage:
                    output = usage.get("output_tokens", 0)
                    total_output_tokens += output

                    inp = usage.get("input_tokens", 0)
                    cc = usage.get("cache_creation_input_tokens", 0)
                    cr = usage.get("cache_read_input_tokens", 0)
                    if inp or cc or cr:
                        last_input_tokens = inp
                        last_cache_creation = cc
                        last_cache_read = cr
                    # Cumulative sums for accurate cost calculation
                    sum_fresh_input += inp
                    sum_cache_creation += cc
                    sum_cache_read += cr

            # --- Content blocks: tool usage, file paths, assistant text ---
            content = message.get("content", [])
            if not isinstance(content, list):
                continue

            for block in content:
                if not isinstance(block, dict):
                    continue

                block_type = block.get("type")

                if block_type == "text":
                    text = _sanitize_text(block.get("text", "").strip())
                    if text:
                        first_line = text.split("\n")[0].strip()
                        if len(first_line) > 10:
                            assistant_lines.append(first_line)
                        # Capture fuller text for conclusion zone (cap each block at 300 chars)
                        if len(text) > 10:
                            assistant_full_blocks.append(text[:300])

                elif block_type == "tool_use":
                    tool_name = block.get("name", "")
                    if tool_name:
                        tool_counts[tool_name] = tool_counts.get(tool_name, 0) + 1

                    tool_input = block.get("input", {})
                    if tool_name in ("Read", "Write", "Edit") and isinstance(tool_input, dict):
                        file_path = tool_input.get("file_path", "")
                        sanitized = sanitize_path(file_path, cwd, home)
                        if sanitized:
                            files_touched.add(sanitized)
                            if not compact_only:
                                _, ext = os.path.splitext(sanitized)
                                ext = ext.lower().lstrip(".")
                                if ext:
                                    file_extensions[ext] = file_extensions.get(ext, 0) + 1

    compact_log = _format_compact_log(assistant_lines, assistant_full_blocks, files_touched, tool_counts)

    if compact_only:
        result = {"compact_log": compact_log}
        if model:
            result["model"] = model
        return result

    # Genuinely processed tokens = fresh input + cache creation + output
    # (cumulative across all API calls in the session)
    # Cache reads are excluded — they're just loading saved state, not real compute
    total_tokens = sum_fresh_input + sum_cache_creation + total_output_tokens
    sorted_files = sorted(files_touched)

    result = {
        "input_tokens": sum_fresh_input,
        "output_tokens": total_output_tokens,
        "total_tokens": total_tokens,
        "cache_creation_input_tokens": sum_cache_creation,
        "cache_read_input_tokens": sum_cache_read,
        "files_touched": sorted_files,
        "tool_usage_summary": tool_counts,
        "compact_log": compact_log,
        "source_metadata": {
            "files_touched": sorted_files,
            "file_count": len(sorted_files),
            "file_extensions": file_extensions,
            "tool_usage_summary": tool_counts,
        },
    }
    if model:
        result["model"] = model
    return result


def extract_compact_log(path: str, cwd: str = "", home: str = "") -> str:
    """Extract only the compact session log (single pass, no token tracking)."""
    return _scan_transcript(path, cwd, home, compact_only=True)["compact_log"]


def parse_transcript(path: str, cwd: str = "", home: str = "") -> dict:
    """Full parse: tokens, metadata, and compact log in a single pass."""
    return _scan_transcript(path, cwd, home, compact_only=False)


if __name__ == "__main__":
    args = sys.argv[1:]
    compact_mode = False

    if args and args[0] == "--compact-log":
        compact_mode = True
        args = args[1:]

    if len(args) not in (1, 2):
        print(json.dumps({"error": "Usage: parse-transcript.py [--compact-log] <transcript_path> [cwd]"}))
        sys.exit(1)

    transcript_path = args[0]
    transcript_cwd = args[1] if len(args) == 2 else ""
    home = os.path.expanduser("~")

    try:
        if compact_mode:
            print(extract_compact_log(transcript_path, transcript_cwd, home))
        else:
            result = parse_transcript(transcript_path, transcript_cwd, home)
            print(json.dumps(result))
    except FileNotFoundError:
        print(json.dumps({"error": f"Transcript not found: {transcript_path}"}))
        sys.exit(1)
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)
