# AGENTS.md

This file provides guidance to Codex when working with code in this repository. It mirrors `CLAUDE.md` — keep the two in sync. The product facts below are unchanged: this repo is a Claude Code plugin, so paths like `.claude-plugin/` and `~/.claude/projects/` are real and must not be renamed.

## Project Overview

**git-timetrack** is a Claude Code plugin that passively tracks git activity (commits, checkouts, merges, push/pull/rebase) and generates time reports and client billing summaries via conversational skills.

## Architecture

This is a **Claude Code plugin** — installed via `/plugin install`. The plugin provides:

| Component | File | Purpose |
|---|---|---|
| Hook handler | `bin/hook-handler.py` | PostToolUse hook — logs git events to JSONL |
| Session reader | `bin/session-reader.py` | Derives measured sessions from Claude Code transcripts and Codex threads |
| Busy push | `bin/busy-push.py` | Writes billable entries to Finago Busy's API as hour entries |
| Hook config | `hooks/hooks.json` | Routes `Bash(git *)` commands to the handler |
| Timelog skill | `skills/timelog/SKILL.md` | `/git-timetrack:timelog` — activity summaries |
| Map-client skill | `skills/map-client/SKILL.md` | `/git-timetrack:map-client` — repo→client mapping |
| Plugin manifest | `.claude-plugin/plugin.json` | Plugin metadata |

## Data Storage

All data lives at `~/.git-timetrack/`:

| File | Format | Purpose |
|---|---|---|
| `activity.jsonl` | JSON Lines (append-only) | One git event per line |
| `sessions.jsonl` | JSON Lines (rebuilt in full) | One measured session per line; `entrypoints` holds `codex` for a Codex thread |
| `clients.json` | JSON object | `{"repo-name": "Client Name"}` mapping |
| `ignore` | Plain text | Repo names to exclude (one per line) |
| `busy.json` | JSON object | Finago Busy mapping — `user_id`, `default_tag_id`, `clients` |
| `busy-token` | Plain text | Finago Busy API token, mode 600 (or `$BUSY_TOKEN`) |

## Key Implementation Details

**Data format** — Each event in `activity.jsonl`:
```json
{"timestamp": "...", "event": "commit", "repo": "my-repo", "branch": "main", "client": "Acme Corp", "commit_hash": "...", "commit_message": "...", "files_changed": 3, "insertions": 42, "deletions": 7, "new_branch": "", "command": "...", "cwd": "..."}
```

**Time estimation** (used by the timelog skill):
- Measured session spans from `sessions.jsonl` take precedence — no re-estimation
- The billable unit is **continuous work per client**, not per Claude Code session or Codex thread: blocks for one client merge on the same gap that split them (`--gap`, default 30 min), across session ids and across that client's repos. Sessions are restarted mid-task to manage context, so ~30% of billable lines span several
- **Billing policy** (`bill_hours`): minimum 30 min per session, part-hours round up to the next 30-min step. Parallel sessions bill to every client in full and are never deducted — `PARALLEL WORK` in the digest is information, not a conflict
- Commits outside any session → work done in neither tool, estimated per stretch (`git_groups`): commits <1.5 hours apart are continuous work (sum the gaps), isolated commits are 30 min–2 hr by diff size. A line keeps the commits made inside it even past `--until`, and a commit inside a session that started before the range is left to that session's line rather than estimated again

**session-reader.py** reads `~/.claude/projects/*/*.jsonl` (never the `subagents/` subdirectories, which are agent time, and skipping `isSidechain` rows), splits each transcript into activity blocks on a 30-minute gap, merges overlapping blocks per repo so parallel sessions count once, and rebuilds `sessions.jsonl` in full. Transcript row order is not guaranteed, so timestamps must be sorted. The transcript format is undocumented internals and may change without notice.

Subagents are read only to bridge gaps: when a subagent worked through a pause longer than `--gap`, the session is kept whole rather than split, capped at `--bridge` minutes so an unattended overnight run is not billed. Their own spans are never added as time — the parent session logs activity again when a subagent returns.

**Codex threads** come from `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl` and `archived_sessions/` (`~/.codex` by default) and go through the same block, merge and billing code as the transcripts, with `entrypoints: ["codex"]`. Every rollout is read on every run: a thread is filed under the local day it started but can run for days, and continues in further `<thread>_<rollout>` files that share its id. Only `response_item` rows are activity — `event_msg` rows keep arriving when a background command exits long after the work. Two kinds of turn are dropped whole: turns Codex imported from Claude Code (`turn_id` `external-import-turn-*`), which carry the time of the import and would bill a burst on that day, and turns an automation started (`<heartbeat>`) that hold no human prompt. Prompts are the user-role items minus the context Codex injects, which opens with a tag or a heading; the typed part follows a `## My request` heading when Codex wraps it, and question replies and attached files count as the human's. Spawned subagents (`source.subagent.thread_spawn`) bridge like Claude subagents, one stretch of activity at a time. The approval reviewer (`guardian`) is ignored: it wakes as its parent resumes, so it would bridge the very pause before. Thread names come from `session_index.jsonl`, where a later row is a rename. The rollout format is undocumented internals as well.

`--report` is the skill's entry point: it rebuilds the log and prints a pre-aggregated digest (merged per client, rounded, commits matched, cross-client overlap flagged) so the skill never parses megabytes of JSONL into context. Past `BRIEF_THRESHOLD` sessions it drops to one line each to keep the output small.

**hook-handler.py** reads PostToolUse JSON from stdin, detects git commands, runs git commands to gather state, and appends to the activity log. It silently exits on failure to avoid disrupting Claude Code.

**busy-push.py** pushes billable entries to Finago Busy (`https://api.busy.no`, OpenAPI at `/v2/openapi.json`). `--json` on the reader emits the same rows as `--report` — both render from `digest_rows`, so they cannot drift — with an empty `description` and a `key` per line. The skill writes the description and picks the task; the script never invents time.

The `key` becomes the hour entry's `externalId`, which makes a re-push idempotent: the script looks the keys up (`externalIdIn`, `isActive=all`) and creates, patches, revives or skips accordingly. Busy caps an externalId at 50 characters, so the client slug in the key is trimmed — changing `SLUG_CHARS` orphans every entry already written. Hour entries cannot be deleted through the API, only patched to `isActive: false`; that is what `undo` does. Entries Busy reports as locked or invoiced are left untouched.

Two guards sit in front of the write. Lines that meet end-to-end on the same project, task and tag are joined into one entry with the descriptions concatenated, because Busy draws one card per hour entry; only exactly contiguous lines join, since anything looser would change the billed total. And because the `externalId` lookup only ever finds this script's own entries, `push` also reads back the user's hours for the range and stops on any line overlapping one already logged — by hand, or by an earlier push under another key — until `--force`. An entry deleted in Busy stays deleted for the same reason: reviving it would undo a deliberate cleanup on every re-push.

The API answers in UTC with a `Z` suffix while everything here is local, so convert on the way in — comparing the two directly silently shifts every overlap by the offset.

Writing is opt-in: `push` is a dry run unless `--commit`. Tags and tasks may be given by name or id, and a task-based project refuses an entry with no task. Lunch break deduction is not applied automatically to hours created via the API.

**Plugin environment variables** — hooks.json uses `${CLAUDE_PLUGIN_ROOT}` to reference the handler script.
