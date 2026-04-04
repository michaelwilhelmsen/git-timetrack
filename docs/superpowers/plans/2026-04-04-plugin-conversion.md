# Git Timetrack Plugin Conversion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert git-timetrack from a bash installer into a Claude Code plugin, removing global git hooks mode entirely.

**Architecture:** The plugin provides a PostToolUse hook that silently logs git events to `~/.git-timetrack/activity.jsonl`, plus two skills — `timelog` for summarizing activity and `map-client` for managing repo-to-client mappings. All data stays at `~/.git-timetrack/`.

**Tech Stack:** Python 3 (hook handler), Markdown (skills, plugin manifest), JSON (hook config, plugin manifest)

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `.claude-plugin/plugin.json` | Create | Plugin manifest — name, version, description, author |
| `hooks/hooks.json` | Create | PostToolUse hook config — routes `Bash(git *)` to handler |
| `bin/hook-handler.py` | Create | Event processor — reads stdin JSON, gathers git state, appends to JSONL |
| `skills/timelog/SKILL.md` | Create | Timelog skill — Claude reads activity data and summarizes |
| `skills/map-client/SKILL.md` | Create | Map-client skill — Claude manages repo→client mappings |
| `README.md` | Rewrite | Plugin installation docs, usage, data format |
| `CLAUDE.md` | Rewrite | Updated project context for plugin structure |
| `install.sh` | Delete | Replaced by plugin system |
| `.gitignore` | Keep | No changes |
| `LICENSE` | Keep | No changes |

---

### Task 1: Create plugin manifest and hook config

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `hooks/hooks.json`

- [ ] **Step 1: Create `.claude-plugin/plugin.json`**

```json
{
  "name": "git-timetrack",
  "version": "1.0.0",
  "description": "Passive time tracking from git activity. Logs commits, checkouts, merges, and generates time reports with client billing summaries.",
  "author": { "name": "Michael Wilhelmsen" },
  "repository": "https://github.com/michaelwilhelmsen/git-timetrack",
  "license": "MIT",
  "keywords": ["git", "time-tracking", "billing", "productivity"]
}
```

- [ ] **Step 2: Create `hooks/hooks.json`**

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "if": "Bash(git *)",
            "command": "python3 \"${CLAUDE_PLUGIN_ROOT}/bin/hook-handler.py\"",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 3: Commit**

```bash
git add .claude-plugin/plugin.json hooks/hooks.json
git commit -m "Add plugin manifest and hook configuration"
```

---

### Task 2: Extract hook handler from install.sh

**Files:**
- Create: `bin/hook-handler.py`

Extract the Python code from between the `HANDLER_PY` heredoc markers in `install.sh` (lines 161-418), then apply these changes:

- [ ] **Step 1: Create `bin/hook-handler.py`**

Write the handler with these modifications from the current heredoc version:

1. Update docstring — remove mention of CLI args / git hook mode
2. Remove `GIT_HOOK_EVENTS` constant
3. Remove `handle_git_hook()` function entirely
4. Rename `handle_claude_code()` to `main()`
5. Update `gather_git_state()` docstring — remove "Shared by both handlers"
6. Update `is_duplicate()` docstring — remove mention of "both Claude Code hooks and global git hooks"
7. Simplify `__main__` block to just call `main()`
8. Add `ensure_data_dir()` function that creates `~/.git-timetrack/`, empty `clients.json`, and `ignore` file with example comments if they don't exist. Call it at the start of `main()`.

The full file content:

```python
#!/usr/bin/env python3
"""
git-timetrack hook handler.

Reads PostToolUse JSON from stdin, detects git commands,
and logs activity to ~/.git-timetrack/activity.jsonl.
"""

import fcntl
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# ── Paths ───────────────────────────────────────────────────

DIR     = Path.home() / ".git-timetrack"
LOG     = DIR / "activity.jsonl"
CLIENTS = DIR / "clients.json"
IGNORE  = DIR / "ignore"

# ── Constants ───────────────────────────────────────────────

EMPTY_TREE_SHA = "4b825dc642cb6eb9a060e54bf899d69f82e1764"
DEDUP_WINDOW_SECS = 5
TIMESTAMP_FMT = "%Y-%m-%dT%H:%M:%SZ"

TRACKED_COMMANDS = ["commit", "push", "checkout", "switch", "merge", "pull", "rebase"]

# ── Utility functions ───────────────────────────────────────

def run(cmd):
    """Run a command and return its stdout, or empty string on failure."""
    try:
        output = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, timeout=5)
        return output.decode().strip()
    except Exception:
        return ""


def get_client(repo):
    """Look up the client name for a repo from clients.json."""
    if not CLIENTS.exists():
        return ""
    try:
        mapping = json.loads(CLIENTS.read_text())
        return mapping.get(repo, "")
    except Exception:
        return ""


def is_ignored(repo):
    """Check if a repo is listed in the ignore file (skipping comments and blanks)."""
    if not IGNORE.exists():
        return False
    try:
        lines = IGNORE.read_text().strip().split("\n")
        ignored_repos = [
            line.strip() for line in lines
            if line.strip() and not line.strip().startswith("#")
        ]
        return repo in ignored_repos
    except Exception:
        return False


def ensure_data_dir():
    """Create data directory and default config files on first run."""
    DIR.mkdir(parents=True, exist_ok=True)
    if not CLIENTS.exists():
        CLIENTS.write_text("{}\n")
    if not IGNORE.exists():
        IGNORE.write_text(
            "# Repos to exclude from tracking (one name per line)\n"
            "# Example:\n"
            "# personal-dotfiles\n"
            "# throwaway-test\n"
        )

# ── Parsing helpers ─────────────────────────────────────────

DIFFSTAT_PATTERNS = [
    (r"(\d+)\s+files?\s+changed",    "files_changed"),
    (r"(\d+)\s+insertions?\(\+\)",   "insertions"),
    (r"(\d+)\s+deletions?\(-\)",     "deletions"),
]


def parse_diffstat(text):
    """Extract files_changed, insertions, deletions from git's --shortstat output."""
    stats = {"files_changed": 0, "insertions": 0, "deletions": 0}
    for pattern, key in DIFFSTAT_PATTERNS:
        match = re.search(pattern, text)
        if match:
            stats[key] = int(match.group(1))
    return stats


def detect_git_command(cmd):
    """Detect which tracked git command is in the string. Returns event name or None.
    Normalizes 'git switch' to 'checkout'."""
    normalized = re.sub(r"\s+", " ", cmd)
    for name in TRACKED_COMMANDS:
        if f"git {name}" in normalized:
            return "checkout" if name == "switch" else name
    return None


def gather_git_state(event, cwd):
    """Gather current git state by running git commands in cwd."""
    def git(*args):
        return run(["git", "-C", cwd] + list(args)) if cwd else run(["git"] + list(args))

    branch = git("rev-parse", "--abbrev-ref", "HEAD")
    info = {"branch": branch, "commit_hash": "", "commit_message": "",
            "files_changed": 0, "insertions": 0, "deletions": 0, "new_branch": ""}

    if event == "commit":
        info["commit_hash"] = git("rev-parse", "--short", "HEAD")
        info["commit_message"] = git("log", "-1", "--pretty=%s")
        # Use empty tree for initial commits (rev-parse HEAD~1 fails)
        parent = "HEAD~1" if git("rev-parse", "HEAD~1") else EMPTY_TREE_SHA
        info.update(parse_diffstat(git("diff", "--shortstat", parent, "HEAD")))
    elif event == "checkout":
        info["new_branch"] = branch

    return info

# ── Logging ─────────────────────────────────────────────────

def read_last_entry():
    """Read the last JSON entry from the activity log, or None."""
    if not LOG.exists():
        return None
    try:
        with open(LOG, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            if size == 0:
                return None
            f.seek(max(0, size - 512))
            tail = f.read().decode("utf-8", errors="replace")

        for line in reversed(tail.strip().split("\n")):
            if line.strip():
                return json.loads(line)
    except Exception:
        pass
    return None


def is_duplicate(entry):
    """Check if the entry duplicates the last log line (same event+repo+hash within window)."""
    last = read_last_entry()
    if last is None:
        return False

    if (last.get("event") != entry.get("event") or
            last.get("repo") != entry.get("repo") or
            last.get("commit_hash") != entry.get("commit_hash")):
        return False

    try:
        last_ts = datetime.strptime(last["timestamp"], TIMESTAMP_FMT).replace(tzinfo=timezone.utc)
        entry_ts = datetime.strptime(entry["timestamp"], TIMESTAMP_FMT).replace(tzinfo=timezone.utc)
        return abs((entry_ts - last_ts).total_seconds()) < DEDUP_WINDOW_SECS
    except Exception:
        return False


def log_entry(entry):
    """Append an entry to the activity log (with file locking and dedup)."""
    DIR.mkdir(parents=True, exist_ok=True)

    with open(LOG, "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            if not is_duplicate(entry):
                f.write(json.dumps(entry) + "\n")
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)

# ── Entry builders ──────────────────────────────────────────

def make_timestamp():
    return datetime.now(timezone.utc).strftime(TIMESTAMP_FMT)


def make_entry(event, repo, **extra):
    """Build a base log entry dict with common fields."""
    entry = {
        "timestamp": make_timestamp(),
        "event": event,
        "repo": repo,
        "branch": "",
        "client": get_client(repo),
        "commit_hash": "",
        "commit_message": "",
        "files_changed": 0,
        "insertions": 0,
        "deletions": 0,
        "new_branch": "",
        "command": "",
        "cwd": "",
    }
    entry.update(extra)
    return entry

# ── Main ────────────────────────────────────────────────────

def main():
    """Claude Code PostToolUse handler — reads JSON from stdin."""
    ensure_data_dir()

    data = json.loads(sys.stdin.read())

    cmd = data.get("tool_input", {}).get("command", "")

    event = detect_git_command(cmd)
    if not event:
        return

    cwd = data.get("cwd", "")
    repo = os.path.basename(cwd) if cwd else "unknown"

    if is_ignored(repo):
        return

    info = gather_git_state(event, cwd)
    log_entry(make_entry(event, repo, command=cmd, cwd=cwd, **info))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # Never fail loudly — don't disrupt Claude Code
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x bin/hook-handler.py
```

- [ ] **Step 3: Commit**

```bash
git add bin/hook-handler.py
git commit -m "Add hook handler extracted from install.sh"
```

---

### Task 3: Create timelog skill

**Files:**
- Create: `skills/timelog/SKILL.md`

This replaces both the `/weeklog` slash command and the terminal `weeklog` script. The key changes from the old command:
- Default time range is "today" instead of "this Monday"
- Support natural language time ranges
- Name is `timelog` not `weeklog`
- Suggest `/git-timetrack:map-client` instead of `map-client --auto`

- [ ] **Step 1: Create `skills/timelog/SKILL.md`**

```markdown
---
description: Summarize git activity for time reports, standups, and client updates. Use when the user asks about what they worked on, wants a time report, needs to write a status update, or mentions timelog/weeklog.
---

# Timelog — Summarize git activity

Read `~/.git-timetrack/activity.jsonl` and `~/.git-timetrack/clients.json`.

## Task

1. Parse the JSONL log (fields: timestamp, event, repo, branch, client, commit_hash, commit_message, files_changed, insertions, deletions, new_branch, command, cwd)
2. Resolve repo → client using the mapping file
3. Filter to the requested time range (default: **today**). Support natural language: "today", "yesterday", "this week", "last 3 days", "march", "last month", "since monday", etc.
4. Group by client, then by day
5. Estimate hours: commits <2hrs apart = continuous work; isolated commits = 30min–2hr by diff size; branch switches = +5min overhead
6. Generate a client-friendly summary per client

## Per client, output

- **Raw activity**: commits grouped by day (developer reference)
- **Estimated hours** (note: approximate — only captures git activity)
- **Client summary**: 3–5 bullet points translating technical work into business outcomes. NO jargon — no "refactor", "CI/CD", "SSH", "MutationObserver", "webpack", etc.
- **Draft email**: ready to review, with greeting and sign-off

## Rules

- Group related commits into themes (3 cart fixes → one bullet about cart improvements)
- Translate to user/business impact
- Stay honest — don't inflate small fixes
- Default to English unless the user specifies otherwise
- Warm, casual-professional tone unless told otherwise
- If `$ARGUMENTS` given, adjust (e.g. "in german", "professional", "just acme", "last month", "today only", "draft invoice")

## Edge cases

- No log file → explain that the plugin hooks into git commands automatically and tracking will begin once commits are made in Claude Code sessions
- Unmapped repos → list them, suggest running `/git-timetrack:map-client`
- Low time estimate → note it only captures git activity, actual work time is likely higher
- No activity in range → say so clearly, suggest a wider range
```

- [ ] **Step 2: Commit**

```bash
git add skills/timelog/SKILL.md
git commit -m "Add timelog skill for activity summaries"
```

---

### Task 4: Create map-client skill

**Files:**
- Create: `skills/map-client/SKILL.md`

This replaces the bash `map-client` CLI with a conversational Claude-driven experience.

- [ ] **Step 1: Create `skills/map-client/SKILL.md`**

```markdown
---
description: Map git repos to client names for time tracking reports. Use when the user wants to set up client mappings, has unmapped repos, or mentions map-client.
---

# Map Client — Manage repo-to-client mappings

Read `~/.git-timetrack/clients.json` and `~/.git-timetrack/activity.jsonl`.

## Task

1. Read the current client mappings from `clients.json`
2. Read `activity.jsonl` to find all unique repo names that have been tracked
3. Identify repos with no client mapping
4. Present the current state: show existing mappings and list unmapped repos
5. For unmapped repos, suggest likely client names based on the repo name and ask the user to confirm or provide the correct name
6. Write the updated mappings to `clients.json`

## Rules

- Show existing mappings first so the user has context
- For each unmapped repo, suggest a client name if the repo name hints at one (e.g. "acme-website" → "Acme")
- Accept user corrections and preferences without pushback
- If `$ARGUMENTS` is a direct mapping (e.g. "my-repo Acme Corp"), just apply it without the interactive flow
- Preserve existing mappings — only add or update, never remove unless explicitly asked
- Write valid JSON to `clients.json` with proper formatting

## Edge cases

- No activity log yet → explain that tracking starts automatically with git commands in Claude Code
- All repos already mapped → confirm everything is mapped, show the list
- Empty `$ARGUMENTS` → run the interactive flow
```

- [ ] **Step 2: Commit**

```bash
git add skills/map-client/SKILL.md
git commit -m "Add map-client skill for repo-to-client mapping"
```

---

### Task 5: Delete install.sh and old files

**Files:**
- Delete: `install.sh`

- [ ] **Step 1: Remove install.sh**

```bash
git rm install.sh
```

- [ ] **Step 2: Commit**

```bash
git commit -m "Remove install.sh — replaced by plugin system"
```

---

### Task 6: Rewrite README.md

**Files:**
- Modify: `README.md`

Rewrite the README for plugin distribution. Keep the same voice and structure but update all content for the plugin model.

- [ ] **Step 1: Rewrite README.md**

The README should cover:

1. **Opening hook** — keep the "It's Friday" intro (it's good)
2. **Requirements** — Claude Code
3. **Install** — plugin install commands (marketplace add + plugin install)
4. **Usage** — `/git-timetrack:timelog` examples (today, this week, last month, specific client, draft emails, different languages). `/git-timetrack:map-client` for client mapping.
5. **How time estimation works** — keep as-is
6. **What gets tracked** — keep the event table
7. **Data format** — keep the JSON example
8. **Data storage** — `~/.git-timetrack/` files (activity.jsonl, clients.json, ignore)
9. **FAQ** — update for plugin context:
   - "Does this track outside git?" — same answer
   - "Does this send data anywhere?" — same answer
   - "What about repos I don't want tracked?" — mention ignore file
   - "How do I uninstall?" — `/plugin uninstall git-timetrack@...`
   - Remove the "Will this slow down my commits?" FAQ (hooks run async via plugin system)
   - Remove "Can I use this with a team?" or update for plugin context
10. **Contributing** — update
11. **License** — keep

Full content:

```markdown
# Git Timetrack

It's Friday. You have no idea what you did this week.

You know you _worked_ — you were in the zone, fixing things, shipping things. But now your PM wants a status update, your client needs a time report, and you're staring at a blank email trying to reconstruct five days from memory. So you skim through git logs, guess at hours, and write something that feels vaguely dishonest.

**Git Timetrack** fixes this. It silently watches your git activity — commits, branch switches, merges — and logs everything to a local file. No timers to start. No buttons to press. You just code.

Then you ask Claude, and get:

- Per-project activity grouped by day
- Time estimates based on commit patterns
- Client-ready email drafts in any language

## Requirements

- [Claude Code](https://claude.ai/code)
- Python 3.6+

## Install

```
/plugin marketplace add michaelwilhelmsen/claude-plugins
/plugin install git-timetrack@claude-plugins
```

That's it. The plugin hooks into your git commands automatically — no configuration needed.

## Usage

### Time reports

Use `/git-timetrack:timelog` to summarize your activity. Claude reads your git history and writes human-friendly reports.

```
/git-timetrack:timelog
/git-timetrack:timelog today
/git-timetrack:timelog this week for acme
/git-timetrack:timelog last month, invoice format
/git-timetrack:timelog in german, professional tone
```

Claude translates `fix: MutationObserver feedback loop in cart widget` into `Fixed an issue where the shopping cart wasn't updating correctly` — and writes a complete email draft you can review and send.

You can have a conversation about it: _"Combine those first two bullets."_ _"Make it more formal."_ _"Skip the infrastructure stuff, the client doesn't care."_

### Map projects to clients

Use `/git-timetrack:map-client` to associate repos with client names. Claude walks through your unmapped repos and suggests mappings.

```
/git-timetrack:map-client
/git-timetrack:map-client my-repo "Acme Corp"
```

## How time estimation works

The tool doesn't know when you _started_ working — only when you committed. So it uses heuristics:

- Commits within **2 hours** of each other → the gap counts as work time
- **Isolated commits** → estimated at 30min–2hr based on diff size
- **Branch switches** → +5 minutes for context-switch overhead

These are **approximations**, not invoiceable truth. The tool flags this clearly. Always review before sharing.

## What gets tracked

| Event                                  | Captured data                                              |
| -------------------------------------- | ---------------------------------------------------------- |
| `git commit`                           | Message, hash, branch, files changed, insertions/deletions |
| `git checkout` / `git switch`          | New branch                                                 |
| `git merge`                            | Branch                                                     |
| `git push` / `git pull` / `git rebase` | Branch                                                     |

Everything is stored locally in `~/.git-timetrack/activity.jsonl`. Nothing is sent anywhere. The file is plain JSON Lines — one object per event — so you can grep it, pipe it, or build your own tools on top.

## Data format

```json
{
  "timestamp": "2025-03-28T14:23:01Z",
  "event": "commit",
  "repo": "acme-website",
  "branch": "main",
  "client": "Acme Corp",
  "commit_hash": "a1b2c3d",
  "commit_message": "fix: resolve checkout page crash on mobile",
  "files_changed": 3,
  "insertions": 42,
  "deletions": 7,
  "new_branch": "",
  "command": "git commit -m '...'",
  "cwd": "/Users/you/projects/acme-website"
}
```

## Data storage

| File | Location | Purpose |
| --- | --- | --- |
| Activity log | `~/.git-timetrack/activity.jsonl` | Append-only event log (created on first git event) |
| Client map | `~/.git-timetrack/clients.json` | Repo → client name mapping |
| Ignore list | `~/.git-timetrack/ignore` | Repos to exclude (one name per line) |

## FAQ

**Does this track my time outside of git?**
No. It only sees git commands run inside Claude Code sessions. Meetings, code review, debugging without committing — invisible. Your actual work time is almost certainly higher than what the tool reports.

**Does this send my data anywhere?**
No. Everything stays in `~/.git-timetrack/` on your machine.

**What about repos I don't want tracked?**
Add the repo name to `~/.git-timetrack/ignore` (one per line). The handler checks this file before logging.

**How do I uninstall?**
```
/plugin uninstall git-timetrack@claude-plugins
```
Your activity data in `~/.git-timetrack/` is preserved. Delete it manually if you want.

## Contributing

Issues and PRs welcome at [github.com/michaelwilhelmsen/git-timetrack](https://github.com/michaelwilhelmsen/git-timetrack).

## License

MIT
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "Rewrite README for plugin distribution"
```

---

### Task 7: Rewrite CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

Update project context for the plugin structure.

- [ ] **Step 1: Rewrite CLAUDE.md**

```markdown
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**git-timetrack** is a Claude Code plugin that passively tracks git activity (commits, checkouts, merges, push/pull/rebase) and generates time reports and client billing summaries via conversational skills.

## Architecture

This is a **Claude Code plugin** — installed via `/plugin install`. The plugin provides:

| Component | File | Purpose |
|---|---|---|
| Hook handler | `bin/hook-handler.py` | PostToolUse hook — logs git events to JSONL |
| Hook config | `hooks/hooks.json` | Routes `Bash(git *)` commands to the handler |
| Timelog skill | `skills/timelog/SKILL.md` | `/git-timetrack:timelog` — activity summaries |
| Map-client skill | `skills/map-client/SKILL.md` | `/git-timetrack:map-client` — repo→client mapping |
| Plugin manifest | `.claude-plugin/plugin.json` | Plugin metadata |

## Data Storage

All data lives at `~/.git-timetrack/`:

| File | Format | Purpose |
|---|---|---|
| `activity.jsonl` | JSON Lines (append-only) | One event per line |
| `clients.json` | JSON object | `{"repo-name": "Client Name"}` mapping |
| `ignore` | Plain text | Repo names to exclude (one per line) |

## Key Implementation Details

**Data format** — Each event in `activity.jsonl`:
```json
{"timestamp": "...", "event": "commit", "repo": "my-repo", "branch": "main", "client": "Acme Corp", "commit_hash": "...", "commit_message": "...", "files_changed": 3, "insertions": 42, "deletions": 7, "new_branch": "", "command": "...", "cwd": "..."}
```

**Time estimation** (used by the timelog skill):
- Commits <2 hours apart → continuous work (sum the gaps)
- Isolated commits → 30 min–2 hr based on diff size
- Branch switches → +5 min context-switch overhead

**hook-handler.py** reads PostToolUse JSON from stdin, detects git commands, runs git commands to gather state, and appends to the activity log. It silently exits on failure to avoid disrupting Claude Code.

**Plugin environment variables** — hooks.json uses `${CLAUDE_PLUGIN_ROOT}` to reference the handler script.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "Rewrite CLAUDE.md for plugin architecture"
```

---

### Task 8: Clean up old files and verify structure

**Files:**
- Delete: `docs/superpowers/` (specs and plans — development artifacts, not part of the plugin)

- [ ] **Step 1: Remove development artifacts**

```bash
git rm -r docs/
```

- [ ] **Step 2: Verify the final file structure**

```bash
find . -not -path './.git/*' -not -path './.git' -not -name '.DS_Store' | sort
```

Expected output:
```
.
./.claude-plugin
./.claude-plugin/plugin.json
./.gitignore
./bin
./bin/hook-handler.py
./CLAUDE.md
./hooks
./hooks/hooks.json
./LICENSE
./README.md
./skills
./skills/map-client
./skills/map-client/SKILL.md
./skills/timelog
./skills/timelog/SKILL.md
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "Clean up development artifacts"
```

---

### Task 9: Test the plugin locally

- [ ] **Step 1: Test the plugin loads in Claude Code**

```bash
claude --plugin-dir .
```

In the session, verify:
- `/git-timetrack:timelog` skill is available
- `/git-timetrack:map-client` skill is available
- Run a git command (e.g. `git status`) and check if `~/.git-timetrack/activity.jsonl` gets an entry

- [ ] **Step 2: Test timelog skill**

```
/git-timetrack:timelog today
```

Verify Claude reads the activity data and produces a summary.

- [ ] **Step 3: Test map-client skill**

```
/git-timetrack:map-client
```

Verify Claude reads repos from activity log and offers to map them.

- [ ] **Step 4: Push**

```bash
git push
```
