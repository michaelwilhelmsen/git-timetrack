---
name: timelog
description: "Summarize git and Claude Code activity for time reports, standups, and client updates. Use when the user asks about what they worked on, wants a time report, needs to write a status update, or mentions timelog/weeklog."
---

# Timelog — Summarize work sessions

Two sources, with different strengths:

| File | What it is | Use it for |
|---|---|---|
| `~/.git-timetrack/sessions.jsonl` | **Measured** spans of Claude Code activity | The clock — start, end, duration |
| `~/.git-timetrack/activity.jsonl` | Commit points from git | What was delivered, and work done outside Claude Code |
| `~/.git-timetrack/clients.json` | repo → client mapping | Attribution |

## Task

**Run the reader. Do not parse the logs yourself.** It does the merging, rounding, client grouping, commit matching and overlap detection, and returns a digest of a few KB. Reading the raw logs instead costs tens of thousands of tokens for the same answer.

1. Work out the date range from the request (default: **today**), in the user's local timezone. Support natural language: "today", "yesterday", "this week", "last 3 days", "march", "last month", "since monday", etc.
2. Run the reader **once** — it rebuilds from the transcripts and prints the digest in the same pass:
   ```bash
   python3 ${CLAUDE_PLUGIN_ROOT}/bin/session-reader.py --report --since 2026-09-01 --until 2026-09-07
   ```
   `--days N` works instead of the dates. It takes a few seconds and only reads local files. If it fails, say so and fall back to reading `activity.jsonl` yourself, noting that the report is then estimated from commits rather than measured.
3. Read the digest. Each line is `date  start-end  hours  [msg, commits, sessions, repos]` — one stretch of continuous work for one client, already merged and billed per the policy below, followed by its `titles`, `prompts` and `commits` as description material.
4. Write a short description per session from that evidence, preferring `titles`, then `prompts`, then the commit subjects. Commits are the best evidence of what actually shipped
5. Report the `COMMITS OUTSIDE ANY SESSION` block as its own estimated lines — that is work done without Claude Code
6. Never recompute the hours. The digest's numbers are the answer; only the wording is yours

Only read `sessions.jsonl` or `activity.jsonl` directly if the digest is missing something specific — and then grep for the few lines you need, never the whole file.

## Per client, output

The output is meant for logging hours into timetracking software — one line per session, copyable as-is (rounded times, rounded duration).

- **Sessions**: one line each — date, rounded start–end time, rounded duration, and a very short description (a few words, e.g. "Cart bug fixes", "Landing page"). A session covering several topics combines them ("Operator console + cleanup fixes"). NO jargon — no "refactor", "CI/CD", "SSH", "MutationObserver", "webpack", etc.
- **Total hours** for the range

Do NOT write draft emails. Output the session lines and the total only.

## Billing policy

The digest already applies these — never recompute them, and never talk the numbers down:

- The billable unit is **continuous work for one client**, not one Claude Code session. Sessions get restarted mid-task to manage context, so a single billable line routinely spans several sessions and several repos of that client. The `sessions` count on each line shows how many were merged. Never split a line by session, repo, branch or topic
- A started task bills **at least 30 minutes**
- Part-hours **round up** to the next 30-minute step: 1h05 → 1h30, 2h35 → 3h00
- **Parallel work bills to every client.** Two clients worked at the same time are both billed in full; the hour is not split between them

## Pushing to Finago Busy

Only when the user asks for it ("legg inn timene", "push til Busy"). The report itself never writes anything.

1. Re-run the reader with `--json` for the same range — same rows, same hours, plus a stable `key` per line:
   ```bash
   python3 ${CLAUDE_PLUGIN_ROOT}/bin/session-reader.py --json --since 2026-09-02 --until 2026-09-08 > /tmp/entries.json
   ```
2. Write the entries file outside the repo (`/tmp`, or the scratchpad) — it names real clients and projects. Fill in each entry's `description` with the same wording you wrote in the report, and add a `task` (name or id) per entry — the project's own task list, picked from the evidence for that line. Add `tag` where the default is wrong (evening or night fixes, project management, meetings). Drop the `evidence` blocks; keep `key`, `client`, `date`, `start`, `hours`.
3. Show the dry run and let the user read it before anything is written:
   ```bash
   python3 ${CLAUDE_PLUGIN_ROOT}/bin/busy-push.py push /tmp/entries.json
   ```
4. Only after the user confirms, add `--commit`.

Never invent hours, dates or keys here — they come from `--json` untouched. A re-run updates the entries it wrote before, keyed on `externalId`, so pushing twice does not double-book. `busy-push.py undo entries.json --commit` deletes what it wrote. `busy-push.py lookup` lists projects, tasks, tags and users when the mapping in `~/.git-timetrack/busy.json` needs a new client.

### What the dry run can tell you

- `OVERLAP` — the line covers hours already in Busy: logged by hand, or pushed earlier under a different key. **Nothing is written and the run stops.** Never pass `--force` on your own judgement — hours logged by hand are usually the correct ones, since they are what the client was invoiced from. Show the clash, say which is which, and let the user decide: drop those lines, or overwrite them
- `JOIN` — two or more lines met end-to-end on the same project, task and tag, so they go in as one entry with the descriptions joined. Busy shows one card per entry; this is what keeps a day from looking like confetti. Report the joined line, not the pieces
- `DELETED` — the entry was deleted in Busy after a previous push. It is left alone, because reviving it would undo the user's own cleanup every time the week is pushed again
- `LOCKED` — locked or already invoiced. Left untouched; say so rather than working around it
- `SKIP` — no mapping, or a task the project does not have. Fix the mapping, don't guess a different project

The hours in Busy are live and other people share the workspace, so treat a reading as a snapshot: if the user is tidying up while you work, re-run the dry run rather than trusting what you saw a few minutes ago.

## Rules

- Group related work in a session into one theme (3 cart fixes → "Cart fixes")
- Descriptions are client-facing: business terms, not technical ones
- **Never paste prompt text into the output.** Prompts are private working notes — read them, then write your own short description
- Stay honest — don't inflate small fixes
- Default to English unless the user specifies otherwise
- If `$ARGUMENTS` given, adjust (e.g. "in german", "just acme", "last month", "today only")

## What the digest's footer means

- `TOTAL` — the sum to report. An "entry" is one billable line; the `sessions` count inside a line is how many Claude Code sessions it merged
- `MEASURED` — actual session activity, with the two reasons `TOTAL` sits above it: merged gaps under 30 minutes, and rounding up. Both are the billing policy working as intended, not error. Mention the spread only if asked
- `PARALLEL WORK` — the same wall-clock hour under two clients, from parallel sessions. Correct and already in `TOTAL`: parallel work bills to every client. Do not deduct it, do not flag it as a conflict, do not ask how to split
- `BRIDGED` — waits where a subagent was working and the user was not prompting. Already included; mention it only if asked
- `BRIEF` — the range was too long for per-entry evidence. Descriptions will be thin; offer to narrow the range
- `UNMAPPED` — suggest `/git-timetrack:map-client`

## Parsing notes

The digest is already in local time and needs no conversion. These apply only when falling back to the raw logs:

- Timestamps there are **UTC** ("Z" suffix) — convert to local before filtering and display. Never filter by date-substring match; local midnight is not UTC midnight
- Both logs can be large (`activity.jsonl` is megabytes). Do it in ONE script/pass: prefilter lines by date **with a day of slack on each side** (timezone + boundary sessions), then `json.loads` only those. Never print raw log lines
- Multiple records can share the exact same timestamp — sort with `key=lambda x: x[0]` (or equivalent), never by tuples containing dicts
- The `client` field is often empty — always resolve through `clients.json` by repo name
- A session line marked `NOTE unresolved repo` had its name guessed from a path that no longer exists (a deleted worktree, a scratch folder). Include the time, but check the guess against the titles and prompts before attributing it to a client — and say which sessions these were
- `sessions.jsonl` is derived data, rebuilt in full on every reader run — never append to it by hand

## Edge cases

- No `sessions.jsonl` and the reader fails → fall back to `activity.jsonl` only, and say the report is estimated from commits
- No log files at all → explain that the plugin tracks git commands automatically and reads Claude Code transcripts, and that tracking begins with the next session
- Unmapped repos → list them, suggest running `/git-timetrack:map-client`
- Sessions but no commits in range → normal (research, debugging, reviews). Report the time, describe from titles and prompts
- A session line with very few messages and a long span → likely a session left open. Flag it rather than billing it silently
- Commits but no sessions → work done outside Claude Code. Report it estimated, and note the distinction
- No activity in range → say so clearly, suggest a wider range
