#!/usr/bin/env python3
"""
Promptbook — Historic Data Sync (Backfill)

Scans local Claude Code JSONL transcripts and submits aggregate stats
as backfill Build Cards. Never sends prompts, code, or file paths —
only aggregate stats.

Usage:
  python3 backfill-history.py [--days N] [--dry-run] [--project DIR]

Options:
  --days N       How many days of history to backfill (default: 30)
  --dry-run      Parse and print stats without submitting to the API
  --project DIR  Only backfill sessions from this project directory
"""

import json
import sys
import time
import argparse
from pathlib import Path
from datetime import datetime
from collections import Counter
from typing import Optional


def find_jsonl_files(days: int, project_filter: Optional[str] = None, before: Optional[str] = None) -> list:
    """Find JSONL session files from the last N days, optionally before a cutoff date."""
    claude_dir = Path.home() / ".claude" / "projects"
    if not claude_dir.exists():
        print(f"No Claude Code projects found at {claude_dir}", file=sys.stderr)
        return []

    after_cutoff = time.time() - (days * 86400)
    before_cutoff = None
    if before:
        before_cutoff = datetime.fromisoformat(before.replace("Z", "+00:00")).timestamp()

    files = []

    for project_dir in claude_dir.iterdir():
        if not project_dir.is_dir():
            continue

        if project_filter:
            dir_name = project_dir.name
            decoded_project = dir_name.rsplit("-", 1)[-1] if "-" in dir_name else dir_name
            if project_filter.lower() not in dir_name.lower() and project_filter.lower() != decoded_project.lower():
                continue

        for jsonl_file in project_dir.glob("*.jsonl"):
            mtime = jsonl_file.stat().st_mtime
            if mtime >= after_cutoff and (before_cutoff is None or mtime < before_cutoff):
                files.append(jsonl_file)

    return sorted(files, key=lambda f: f.stat().st_mtime)


def derive_project_name(project_dir_name: str) -> str:
    """Derive a human-readable project name from the encoded directory name."""
    # Format: -Users-foo-Desktop-myproject → myproject
    parts = project_dir_name.split("-")
    # Filter out empty strings and find the last meaningful part
    meaningful = [p for p in parts if p]
    return meaningful[-1] if meaningful else project_dir_name


def parse_session(jsonl_path: Path) -> Optional[dict]:
    """Parse a JSONL transcript and extract aggregate stats."""
    session_id = jsonl_path.stem
    project_dir_name = jsonl_path.parent.name
    project_name = derive_project_name(project_dir_name)

    entries = []
    try:
        with open(jsonl_path, "r") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entries.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except (IOError, OSError) as e:
        print(f"  Skipping {jsonl_path.name}: {e}", file=sys.stderr)
        return None

    if not entries:
        return None

    # Extract timestamps
    timestamps = []
    for entry in entries:
        ts = entry.get("timestamp")
        if ts and isinstance(ts, str):
            try:
                timestamps.append(datetime.fromisoformat(ts.replace("Z", "+00:00")))
            except ValueError:
                continue

    if len(timestamps) < 2:
        return None

    start_time = min(timestamps)
    end_time = max(timestamps)
    build_time_seconds = int((end_time - start_time).total_seconds())

    if build_time_seconds < 5:
        return None  # Too short to be a real session

    # Count prompts: only user entries with actual text content (real human prompts).
    # Empty type=user entries are tool results, hook responses, etc. — not prompts.
    def is_real_prompt(entry):
        if entry.get("type") != "user":
            return False
        msg = entry.get("message", {})
        content = msg.get("content") if isinstance(msg, dict) else None
        if isinstance(content, str):
            return len(content.strip()) > 0
        if isinstance(content, list):
            return any(
                isinstance(b, dict) and b.get("type") == "text"
                and isinstance(b.get("text"), str) and len(b["text"].strip()) > 0
                for b in content
            )
        return False

    prompt_count = sum(1 for e in entries if is_real_prompt(e))

    # Extract token usage from assistant messages
    total_input = 0
    total_output = 0
    total_cache_creation = 0
    total_cache_read = 0
    model = None
    tool_usage: Counter = Counter()
    file_extensions: Counter = Counter()

    for entry in entries:
        if entry.get("type") != "assistant":
            continue

        msg = entry.get("message", {})

        # Get model from first assistant message
        if model is None and msg.get("model"):
            model = msg["model"]

        # Sum token usage
        usage = msg.get("usage", {})
        total_input += usage.get("input_tokens", 0)
        total_output += usage.get("output_tokens", 0)
        total_cache_creation += usage.get("cache_creation_input_tokens", 0)
        total_cache_read += usage.get("cache_read_input_tokens", 0)

        # Count tool usage
        for block in msg.get("content", []):
            if block.get("type") == "tool_use":
                tool_name = block.get("name", "Unknown")
                tool_usage[tool_name] += 1

                # Extract file extensions from tool inputs (Read, Edit, Write)
                tool_input = block.get("input", {})
                file_path = tool_input.get("file_path") or tool_input.get("path") or ""
                if file_path and "." in file_path:
                    ext = "." + file_path.rsplit(".", 1)[-1].lower()
                    if len(ext) <= 10:  # Reasonable extension length
                        file_extensions[ext] += 1

    if model is None:
        return None  # No assistant messages — not a real session

    # Calculate total tokens (cache reads excluded per cost-estimate.ts logic)
    total_tokens = total_input + total_cache_creation + total_output

    if total_tokens == 0 and prompt_count == 0:
        return None  # Empty session

    # Determine primary language from file extensions
    language = "Unknown"
    ext_to_lang = {
        ".ts": "TypeScript", ".tsx": "TypeScript",
        ".js": "JavaScript", ".jsx": "JavaScript",
        ".py": "Python",
        ".rs": "Rust",
        ".go": "Go",
        ".rb": "Ruby",
        ".java": "Java",
        ".cpp": "C++", ".c": "C", ".h": "C",
        ".cs": "C#",
        ".swift": "Swift",
        ".kt": "Kotlin",
        ".php": "PHP",
        ".sh": "Shell", ".bash": "Shell", ".zsh": "Shell",
        ".sql": "SQL",
        ".html": "HTML", ".css": "CSS", ".scss": "CSS",
        ".md": "Markdown",
        ".json": "JSON", ".yaml": "YAML", ".yml": "YAML",
        ".toml": "TOML",
    }
    if file_extensions:
        # Find the most common non-config extension
        for ext, _ in file_extensions.most_common():
            if ext in ext_to_lang and ext not in (".json", ".yaml", ".yml", ".toml", ".md"):
                language = ext_to_lang[ext]
                break
        else:
            # Fall back to most common extension even if config
            top_ext = file_extensions.most_common(1)[0][0]
            language = ext_to_lang.get(top_ext, "Unknown")

    return {
        "session_id": session_id,
        "project_name": project_name,
        "model": model,
        "ai_tool": "claude-code",
        "start_time": start_time.isoformat(),
        "end_time": end_time.isoformat(),
        "build_time_seconds": build_time_seconds,
        "prompt_count": prompt_count,
        "lines_changed": None,  # Not available from JSONL — omit, don't show 0
        "language": language,
        "status": "completed",
        "total_tokens": total_tokens,
        "input_tokens": total_input,
        "output_tokens": total_output,
        "cache_creation_input_tokens": total_cache_creation,
        "cache_read_input_tokens": total_cache_read,
        "source": "backfill",
        "source_metadata": {
            "file_extensions": dict(file_extensions.most_common(50)),
            "tool_usage_summary": dict(tool_usage.most_common(50)),
        },
    }


def upload_batch(sessions: list, api_url: str, api_key: str, days: int) -> Optional[str]:
    """Upload sessions to the backfill batch endpoint. Returns batch_id."""
    import urllib.request
    import urllib.error

    # Upload in chunks of 50
    chunk_size = 50
    batch_id = None

    for i in range(0, len(sessions), chunk_size):
        chunk = sessions[i:i + chunk_size]
        payload = json.dumps({
            "days_scanned": days,
            "sessions": chunk,
        }).encode("utf-8")

        req = urllib.request.Request(
            f"{api_url}/api/backfill/upload",
            data=payload,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {api_key}",
            },
            method="POST",
        )

        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = json.loads(resp.read().decode("utf-8"))
                if batch_id is None:
                    batch_id = body.get("batch_id")
                uploaded = body.get("uploaded", 0)
                dupes = body.get("duplicates", 0)
                print(f"  Uploaded {uploaded} sessions ({dupes} duplicates)", file=sys.stderr)
        except urllib.error.HTTPError as e:
            err_body = e.read().decode("utf-8", errors="replace")
            print(f"  Upload failed (HTTP {e.code}): {err_body}", file=sys.stderr)
            # Stop on auth or server errors — retrying won't help
            if e.code in (401, 403, 500):
                print("  Stopping due to server error.", file=sys.stderr)
                break
        except Exception as e:
            print(f"  Upload failed: {e}", file=sys.stderr)
            break

        # Brief pause between chunks for rate limiting
        if i + chunk_size < len(sessions):
            time.sleep(2)

    return batch_id


def main():
    parser = argparse.ArgumentParser(description="Backfill Claude Code session history to Promptbook")
    parser.add_argument("--days", type=int, default=30, help="Days of history to backfill (default: 30)")
    parser.add_argument("--dry-run", action="store_true", help="Parse and print without submitting")
    parser.add_argument("--json", action="store_true", help="Output parsed sessions as JSON to stdout")
    parser.add_argument("--api-url", type=str, help="API URL (overrides config)")
    parser.add_argument("--api-key", type=str, help="API key (overrides config)")
    parser.add_argument("--project", type=str, help="Only backfill sessions from this project")
    parser.add_argument("--before", type=str, help="Only include sessions before this ISO date (e.g. 2026-03-10)")
    args = parser.parse_args()

    needs_config = not args.dry_run and not args.json

    # Load config
    config_path = Path.home() / ".promptbook" / "config.json"
    api_url = args.api_url or ""
    api_key = args.api_key or ""

    if needs_config and not api_url:
        if not config_path.exists():
            print("Error: ~/.promptbook/config.json not found. Run the Promptbook setup first.", file=sys.stderr)
            sys.exit(1)
        with open(config_path) as f:
            config = json.load(f)
        api_url = api_url or config.get("api_url", "")
        api_key = api_key or config.get("api_key", "")
        if not api_url or not api_key:
            print("Error: config.json missing api_url or api_key", file=sys.stderr)
            sys.exit(1)

    # Find and parse sessions
    if not args.json:
        print(f"Scanning for sessions from the last {args.days} days...", file=sys.stderr)

    jsonl_files = find_jsonl_files(args.days, args.project, args.before)

    if not args.json:
        print(f"Found {len(jsonl_files)} session files", file=sys.stderr)

    if not jsonl_files:
        if args.json:
            print("[]")
        else:
            print("Nothing to backfill.", file=sys.stderr)
        return

    # Parse all sessions
    sessions = []
    skipped = 0
    for jsonl_path in jsonl_files:
        session_data = parse_session(jsonl_path)
        if session_data is None:
            skipped += 1
        else:
            sessions.append(session_data)

    if not args.json:
        print(f"Parsed {len(sessions)} sessions ({skipped} skipped)", file=sys.stderr)

    # --json mode: output to stdout and exit
    if args.json:
        json.dump(sessions, sys.stdout, default=str)
        return

    # --dry-run mode: print summary
    if args.dry_run:
        for i, s in enumerate(sessions, 1):
            print(f"  [{i}/{len(sessions)}] {s['project_name']}: "
                  f"{s['prompt_count']} prompts, "
                  f"{s['total_tokens']:,} tokens, "
                  f"{s['build_time_seconds']}s, "
                  f"model={s['model']}")
        print(f"\nDone: {len(sessions)} sessions found, {skipped} empty/invalid")
        return

    # Default mode: upload to backfill batch endpoint
    if not sessions:
        print("No sessions to upload.", file=sys.stderr)
        return
    batch_id = upload_batch(sessions, api_url, api_key, args.days)
    if batch_id:
        print(f"Batch {batch_id}: {len(sessions)} sessions uploaded", file=sys.stderr)
        print(batch_id)  # stdout: just the batch_id for script consumption
    else:
        print("Upload failed — no batch created.", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
