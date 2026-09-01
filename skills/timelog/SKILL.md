---
name: timelog
description: "Summarize git activity for time reports, standups, and client updates. Use when the user asks about what they worked on, wants a time report, needs to write a status update, or mentions timelog/weeklog."
---

# Timelog — Summarize git activity

Read `~/.git-timetrack/activity.jsonl` and `~/.git-timetrack/clients.json`.

## Task

1. Parse the JSONL log (fields: timestamp, event, repo, branch, client, commit_hash, commit_message, files_changed, insertions, deletions, new_branch, command, cwd)
2. Resolve repo → client using the mapping file
3. Filter to the requested time range (default: **today**). Support natural language: "today", "yesterday", "this week", "last 3 days", "march", "last month", "since monday", etc.
4. Group by client, then by **work session** — commits <2hrs apart belong to the same session
5. Estimate hours per session: sum the gaps between commits; isolated commits = 30min–2hr by diff size; branch switches = +5min overhead
6. **Round each session to the nearest 30 minutes** (minimum 30 min)

## Per client, output

The output is meant for logging hours into timetracking software — one line per session, easy to copy over.

- **Sessions**: one line each — date, start–end time, rounded duration, and a very short description (a few words, e.g. "Cart bug fixes", "Landing page"). NO jargon — no "refactor", "CI/CD", "SSH", "MutationObserver", "webpack", etc.
- **Total hours** for the range (sum of rounded sessions; note: approximate — only captures git activity)

## Rules

- Group related commits in a session into one theme (3 cart fixes → "Cart fixes")
- Descriptions are client-facing: business terms, not technical ones
- Stay honest — don't inflate small fixes
- Default to English unless the user specifies otherwise
- If `$ARGUMENTS` given, adjust (e.g. "in german", "just acme", "last month", "today only")

## Edge cases

- No log file → explain that the plugin hooks into git commands automatically and tracking will begin once commits are made in Claude Code sessions
- Unmapped repos → list them, suggest running `/git-timetrack:map-client`
- Low time estimate → note it only captures git activity, actual work time is likely higher
- No activity in range → say so clearly, suggest a wider range
