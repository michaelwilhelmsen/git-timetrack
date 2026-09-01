---
name: timelog
description: "Summarize git activity for time reports, standups, and client updates. Use when the user asks about what they worked on, wants a time report, needs to write a status update, or mentions timelog/weeklog."
---

# Timelog — Summarize git activity

Read `~/.git-timetrack/activity.jsonl` and `~/.git-timetrack/clients.json`.

## Task

1. Parse the JSONL log (fields: timestamp, event, repo, branch, client, commit_hash, commit_message, files_changed, insertions, deletions, new_branch, command, cwd)
2. Resolve repo → client using the mapping file
3. Filter to the requested time range (default: **today**). Support natural language: "today", "yesterday", "this week", "last 3 days", "march", "last month", "since monday", etc. Build sessions from events up to ~3 hours PAST the range end, then keep the sessions that **start** inside the range — work that runs past midnight belongs to the day it started, and a range boundary must never cut a session in half
4. Group by client, then by **work session** — commits <1.5hrs apart belong to the same session. ONLY a gap of 1.5+ hours starts a new session; a change of topic, feature, or branch never does. Do not split a session to keep descriptions single-topic — merge and combine the description instead
5. Estimate hours per session: sum the gaps between commits; isolated commits = 30min–2hr by diff size; branch switches = +5min overhead
6. **Round each session to the nearest 30 minutes** (minimum 30 min), and round the displayed start/end times to the nearest half hour so the time range matches the rounded duration (e.g. 06:42–09:10 → 06:30–09:00)

## Per client, output

The output is meant for logging hours into timetracking software — one line per session, copyable as-is (rounded times, rounded duration).

- **Sessions**: one line each — date, rounded start–end time, rounded duration, and a very short description (a few words, e.g. "Cart bug fixes", "Landing page"). A session covering several topics combines them ("Operator console + cleanup fixes"). NO jargon — no "refactor", "CI/CD", "SSH", "MutationObserver", "webpack", etc.
- **Total hours** for the range (sum of rounded sessions; note: approximate — only captures git activity)

Do NOT write draft emails. Output the session lines and the total only.

## Rules

- Group related commits in a session into one theme (3 cart fixes → "Cart fixes")
- Descriptions are client-facing: business terms, not technical ones
- Stay honest — don't inflate small fixes
- Default to English unless the user specifies otherwise
- If `$ARGUMENTS` given, adjust (e.g. "in german", "just acme", "last month", "today only")

## Parsing notes

- Timestamps are **UTC** ("Z" suffix) — parse and convert to the user's local timezone before filtering and display. Never filter by date-substring match; local midnight is not UTC midnight
- The log can be large. Do it in ONE script/pass: grep-prefilter lines by date **with a day of slack on each side** (timezone + boundary sessions), then `json.loads` only those. The log is append-only and effectively time-ordered
- Multiple events can share the exact same timestamp — sort with `key=lambda x: x[0]` (or equivalent), never by tuples containing dicts
- The `client` field in events is often empty — always resolve through `clients.json` by repo name

## Edge cases

- No log file → explain that the plugin hooks into git commands automatically and tracking will begin once commits are made in Claude Code sessions
- Unmapped repos → list them, suggest running `/git-timetrack:map-client`
- Low time estimate → note it only captures git activity, actual work time is likely higher
- No activity in range → say so clearly, suggest a wider range
