# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**git-timetrack** is a passive time tracking tool that monitors git activity (commits, checkouts, merges, push/pull/rebase) and generates weekly time reports and client billing summaries. It installs via a single bash script that generates all application code into `~/.git-timetrack/`.

## Architecture

This is an **installer-based project** — there is no traditional build system. All application logic lives inside `install.sh` as heredoc-embedded scripts. When `install.sh` runs, it generates and writes these files to the user's home directory:

| Generated file | Purpose |
|---|---|
| `~/.git-timetrack/hook-handler.py` | Central event processor (Python) |
| `~/.git-timetrack/weeklog.sh` | Terminal summarizer (bash + embedded Python) |
| `~/.git-timetrack/map-client.sh` | Interactive repo→client mapping CLI |
| `~/.claude/commands/weeklog.md` | Claude Code slash command |
| `~/.git-timetrack/activity.jsonl` | JSON Lines activity log (append-only) |
| `~/.git-timetrack/clients.json` | Repo-to-client name mapping |
| `~/.git-timetrack/ignore` | Repos to exclude from tracking |

## Tracking Modes

Two modes can be active simultaneously:

1. **Claude Code Hook** — Uses Claude Code's `PostToolUse` hook system; `hook-handler.py` receives JSON on stdin describing each bash command Claude runs, extracts git metadata from the output.

2. **Global Git Hooks** — Sets `git config --global core.hooksPath` to a directory containing `post-commit`, `post-checkout`, and `post-merge` hooks; these call `hook-handler.py` with CLI args after every git operation system-wide.

## Installation & Development

```bash
# Install (interactive — prompts for tracking mode)
bash install.sh

# Uninstall
bash install.sh --uninstall
```

**After install**, user commands available at `~/.local/bin/`:
```bash
weeklog                                   # Default weekly summary
weeklog --json                            # Structured output
weeklog --client acme                     # Filter by client
weeklog --from 2025-03-01 --to 2025-03-31 # Date range
map-client --auto                         # Interactive client mapping
map-client my-repo "Client Name"          # Direct mapping
```

There are no tests, no linter config, and no build system. Changes to application logic mean editing the heredoc blocks inside `install.sh`.

## Key Implementation Details

**Data format** — Each event appended to `activity.jsonl` is one JSON object per line:
```json
{"timestamp": "...", "event": "commit", "repo": "my-repo", "branch": "main", "client": "Acme Corp", "message": "...", "diff_stats": "..."}
```

**Time estimation algorithm** — `weeklog.sh` estimates work time from activity patterns:
- Commits <2 hours apart → continuous work (sum the gaps)
- Isolated commits → 30 min–2 hr based on diff size
- Branch switches → +5 min context-switch overhead

**hook-handler.py** handles two input modes: stdin JSON (from Claude Code hooks) and CLI args (from git hooks). It silently exits on failure to avoid blocking git operations.

**Client mapping** — `clients.json` maps repo names to client names. `map-client` tool manages this. The ignore file (one repo name per line) excludes repos from tracking.

## Claude Code Integration

The `/weeklog` slash command (installed to `~/.claude/commands/weeklog.md`) lets Claude read `activity.jsonl` directly and summarize activity conversationally. Supports natural language: `/weeklog just the acme project`, `/weeklog in german`.

The Claude Code hook is configured in `~/.claude/settings.json` under `hooks.PostToolUse` to invoke `hook-handler.py` via stdin pipe whenever Claude runs bash commands.
