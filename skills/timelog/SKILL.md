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
4. Group by client, then by day, then split each day into **blocks**: start a new block wherever the gap between logged events exceeds **1 hour**. Never present a day as one wide span — show each block's own time range, commit count and diff totals, and label the gaps between them.
5. Estimate hours: commits <2hrs apart = continuous work; isolated commits = 30min–2hr by diff size; branch switches = +5min overhead. Build the estimate from the same blocks used for display, so the printed ranges and the total reconcile.
6. Generate a client-friendly summary per client

## Per client, output

- **Raw activity**: commits grouped by day (developer reference)
- **Estimated hours** (note: approximate — only captures git activity)
- **Client summary**: 3–5 bullet points translating technical work into business outcomes. NO jargon — no "refactor", "CI/CD", "SSH", "MutationObserver", "webpack", etc.

Do NOT write draft emails. Output the activity, the hours and the summary bullets only.

## Rules

- Group related commits into themes (3 cart fixes → one bullet about cart improvements)
- Translate to user/business impact
- Stay honest — don't inflate small fixes
- Default to English unless the user specifies otherwise
- Warm, casual-professional tone unless told otherwise
- If `$ARGUMENTS` given, adjust (e.g. "in german", "professional", "just acme", "last month", "today only")

## Edge cases

- No log file → explain that the plugin hooks into git commands automatically and tracking will begin once commits are made in Claude Code sessions
- Unmapped repos → list them, suggest running `/git-timetrack:map-client`
- Low time estimate → note it only captures git activity, actual work time is likely higher
- No activity in range → say so clearly, suggest a wider range
