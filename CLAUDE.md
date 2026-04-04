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
