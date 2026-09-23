#!/usr/bin/env python3
"""
git-timetrack session reader.

Derives measured work sessions from Claude Code transcripts in
~/.claude/projects and Codex threads in ~/.codex/sessions, and writes them
to ~/.git-timetrack/sessions.jsonl.

Unlike activity.jsonl (commit points, from which time must be inferred),
this measures wall-clock spans of real session activity.

  session-reader.py                       rebuild sessions.jsonl (all history)
  session-reader.py --report --days 7     rebuild, then print a digest for the range
  session-reader.py --dry-run --days 30   compare against git estimates, write nothing

--report rebuilds the log as a side effect, so the timelog skill needs one run.
Add --dry-run to report without writing.

The written log always covers all history; --since and --days narrow the
--dry-run report only.
"""

import argparse
import bisect
import importlib.util
import json
import math
import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from itertools import chain
from pathlib import Path

# ── Paths ───────────────────────────────────────────────────

DIR         = Path.home() / ".git-timetrack"
ACTIVITY    = DIR / "activity.jsonl"
SESSIONS    = DIR / "sessions.jsonl"
TRANSCRIPTS = Path.home() / ".claude" / "projects"
CODEX       = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")

# ── Constants ───────────────────────────────────────────────

TIMESTAMP_FMT = "%Y-%m-%dT%H:%M:%SZ"

# A pause longer than this ends a session. A session's last message is padded
# by TAIL_MINS to cover reading the final output — this is a guess, and it is
# applied per session, so the report states what it contributes to the total.
DEFAULT_GAP_MINS = 30
DEFAULT_TAIL_MINS = 5

# Estimates for the git-side comparison, mirroring the timelog skill.
GIT_GAP_MINS = 90
GIT_ISOLATED_SMALL_MINS = 30
GIT_ISOLATED_LARGE_MINS = 120
GIT_LARGE_DIFF_LINES = 200

# A subagent running longer than the session gap would otherwise split the
# session in two and drop the wait. Bridging is capped because an unattended
# overnight agent run is machine time, not work time.
DEFAULT_BRIDGE_MINS = 120

MAX_PROMPTS = 12
MAX_PROMPT_CHARS = 200
MAX_COMMITS_SHOWN = 6
DIGEST_CHARS = 80

# Past this many billable entries the per-entry evidence lines dominate the
# output, so a long range prints one line each instead.
BRIEF_THRESHOLD = 80

TS_RE      = re.compile(r'"timestamp":"([^"]+)"')
CWD_RE     = re.compile(r'"cwd":"([^"]*)"')
BRANCH_RE  = re.compile(r'"gitBranch":"([^"]*)"')
ENTRY_RE   = re.compile(r'"entrypoint":"([^"]+)"')
ROLLOUT_RE = re.compile(r'\{"timestamp":"([^"]+)",(?:"ordinal":\d+,)?"type":"(\w+)"'
                        r'(?:,"payload":\{"type":"(\w+)")?')

# ── Shared helpers from the hook handler ────────────────────

def _load_hook_module():
    path = Path(__file__).resolve().parent / "hook-handler.py"
    spec = importlib.util.spec_from_file_location("timetrack_hook", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

_hook = _load_hook_module()
get_client    = _hook.get_client
is_ignored    = _hook.is_ignored
get_repo_name = _hook.get_repo_name

# ── Transcript parsing ──────────────────────────────────────

def parse_ts(text):
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).astimezone(timezone.utc)
    except Exception:
        return None


def transcript_files():
    """Session transcripts only — the subagents/ subdirectories are agent time, not the user's."""
    return sorted(TRANSCRIPTS.glob("*/*.jsonl"))


def read_transcript(path):
    """Extract activity timestamps and metadata from one transcript.

    Returns (timestamps, prompts, titles, meta) where prompts carry the index
    into timestamps at which they appeared, so they can be matched to a block."""
    stamps = []
    prompts = []
    titles = []
    seen_titles = set()
    meta = {"cwd": "", "branches": [], "entrypoints": []}
    branches, entrypoints = set(), set()
    last_prompt = None

    with open(path, errors="replace") as f:
        for line in f:
            if '"isSidechain":true' in line:
                continue

            is_user = '"type":"user"' in line
            if is_user or '"type":"assistant"' in line:
                match = TS_RE.search(line)
                stamp = parse_ts(match.group(1)) if match else None
                if stamp:
                    stamps.append(stamp)
                if is_user and not meta["cwd"]:
                    match = CWD_RE.search(line)
                    if match:
                        meta["cwd"] = match.group(1)
                match = BRANCH_RE.search(line)
                if match and match.group(1):
                    branches.add(match.group(1))
                match = ENTRY_RE.search(line)
                if match:
                    entrypoints.add(match.group(1))
                continue

            # last-prompt and custom-title rows carry no timestamp; their
            # position in the file is what places them in a block.
            if '"type":"last-prompt"' in line:
                try:
                    text = (json.loads(line).get("lastPrompt") or "").strip()
                except Exception:
                    continue
                if text and text != last_prompt:
                    prompts.append((len(stamps), text[:MAX_PROMPT_CHARS]))
                    last_prompt = text
            elif '"type":"custom-title"' in line:
                try:
                    text = (json.loads(line).get("customTitle") or "").strip()
                except Exception:
                    continue
                if text and text not in seen_titles:
                    seen_titles.add(text)
                    titles.append((len(stamps), text))

    meta["branches"] = sorted(branches)
    meta["entrypoints"] = sorted(entrypoints)
    return sorted(stamps), prompts, titles, meta


def subagent_spans(path):
    """Activity spans of the subagents spawned by one session."""
    directory = path.parent / path.stem / "subagents"
    if not directory.is_dir():
        return []

    spans = []
    for sub in directory.glob("*.jsonl"):
        stamps = []
        with open(sub, errors="replace") as f:
            for line in f:
                if '"type":"user"' in line or '"type":"assistant"' in line:
                    match = TS_RE.search(line)
                    stamp = parse_ts(match.group(1)) if match else None
                    if stamp:
                        stamps.append(stamp)
        if stamps:
            spans.append((min(stamps), max(stamps)))
    return spans


def find_bridges(stamps, spans, gap, bridge):
    """Gap indices a subagent was working through, so the session is not split there.

    Returns (indices, [(when, length)])."""
    indices = set()
    bridged = []
    if not spans or bridge <= timedelta():
        return indices, bridged

    for i in range(1, len(stamps)):
        length = stamps[i] - stamps[i - 1]
        if not gap < length <= bridge:
            continue
        if any(start < stamps[i] and end > stamps[i - 1] for start, end in spans):
            indices.add(i)
            bridged.append((stamps[i - 1], length))
    return indices, bridged


def split_blocks(stamps, gap, bridges=frozenset()):
    """Split ordered timestamps into contiguous blocks, as (start, end, first_idx, count)."""
    blocks = []
    if not stamps:
        return blocks

    start_idx = 0
    for i in range(1, len(stamps) + 1):
        ended = i == len(stamps) or (stamps[i] - stamps[i - 1] > gap and i not in bridges)
        if ended:
            blocks.append((stamps[start_idx], stamps[i - 1], start_idx, i - start_idx))
            start_idx = i
    return blocks


def pick_by_position(items, first_idx, count):
    """Select prompts/titles whose file position falls inside a block.

    A position of None belongs to every block."""
    return [text for pos, text in items if pos is None or first_idx <= pos <= first_idx + count]


def claude_sessions():
    """One entry per Claude Code transcript, with the spans of its subagents."""
    for path in transcript_files():
        stamps, prompts, titles, meta = read_transcript(path)
        if stamps:
            yield dict(meta, id=path.stem, stamps=stamps, prompts=prompts, titles=titles,
                       subagents=subagent_spans(path))

# ── Codex rollouts ──────────────────────────────────────────

CODEX_ENTRYPOINT = "codex"

# Codex wraps what the human typed in context of its own, under a "## My request"
# heading. Context with no request in it opens with a tag or a heading.
REQUEST_RE     = re.compile(r"^## My request[^\n:]*:\s*", re.M)
INJECTED_RE    = re.compile(r"</?[A-Za-z][\w-]*[\s>/]|#+ ")
ATTACHED       = ("# Files mentioned by the user", "# Files pasted by the user")
QUESTION_REPLY = "<send_user_message_question_reply>"


def codex_files():
    """Rollouts of every Codex thread. A thread is filed under the local day it
    started but can run for days after, so the day is no filter."""
    return (sorted((CODEX / "sessions").glob("*/*/*/rollout-*.jsonl"))
            + sorted((CODEX / "archived_sessions").glob("rollout-*.jsonl")))


def read_rollout(path):
    """Extract activity timestamps, human prompts and metadata from one Codex rollout.

    Only response items count as activity: event rows keep arriving when a
    background command exits long after the work. A turn copied in from another
    agent is stamped with the time of the import, and a turn an automation
    started ran with nobody there, so neither counts."""
    meta = {}
    stamps, prompts = [], []
    turn = {"stamps": [], "prompts": [], "imported": False, "automated": False}

    def keep(turn):
        if not turn["imported"] and (turn["prompts"] or not turn["automated"]):
            stamps.extend(turn["stamps"])
            prompts.extend(turn["prompts"])

    with open(path, errors="replace") as f:
        for line in f:
            match = ROLLOUT_RE.match(line)
            if not match:
                continue
            when, kind, item = match.groups()
            if kind == "session_meta" and not meta:
                try:
                    meta = json.loads(line).get("payload") or {}
                except Exception:
                    pass
            elif kind == "event_msg" and item == "task_started":
                keep(turn)
                turn = {"stamps": [], "prompts": [], "automated": False,
                        "imported": '"turn_id":"external-import-' in line}
            elif kind == "response_item":
                stamp = parse_ts(when)
                if not stamp:
                    continue
                turn["stamps"].append(stamp)
                if item == "message" and '"role":"user"' in line:
                    for text in user_texts(line):
                        typed = " ".join(human_text(text).split())
                        if typed:
                            turn["prompts"].append((stamp, typed[:MAX_PROMPT_CHARS]))
                        elif text.lstrip().startswith("<heartbeat>"):
                            turn["automated"] = True
                elif item == "function_call_output" and '"output":"<heartbeat>' in line:
                    turn["automated"] = True
    keep(turn)
    return meta, sorted(stamps), prompts


def user_texts(line):
    """The text items of a user-role message row."""
    try:
        payload = json.loads(line).get("payload") or {}
    except Exception:
        return []
    if payload.get("role") != "user":
        return []
    return [c.get("text") or "" for c in payload.get("content") or []
            if isinstance(c, dict) and c.get("type") == "input_text"]


def human_text(text):
    """What the human wrote in one user-role item, or "" for context Codex injected."""
    match = REQUEST_RE.search(text)
    if match:
        return text[match.end():].strip()
    text = text.strip()
    if text.startswith(QUESTION_REPLY):
        return question_answers(text)
    if text.startswith(ATTACHED) or not INJECTED_RE.match(text):
        return text
    return ""


def question_answers(text):
    """The human's answers in a reply to questions the agent asked."""
    body = text[len(QUESTION_REPLY):].split("</send_user_message_question_reply>")[0]
    try:
        return " | ".join(str(item["answer"]) for item in json.loads(body) if item.get("answer"))
    except Exception:
        return text


def codex_titles():
    """Thread names by thread id. The index is only appended to, so a later row is a rename."""
    titles = {}
    try:
        with open(CODEX / "session_index.jsonl", errors="replace") as f:
            for line in f:
                try:
                    row = json.loads(line)
                except Exception:
                    continue
                name = " ".join((row.get("thread_name") or "").split())
                if row.get("id") and name:
                    titles[row["id"]] = name
    except OSError:
        pass
    return titles


def codex_sessions(gap):
    """One entry per Codex thread, which may be spread over several rollouts.

    Spawned subagents only bridge their parent's gaps, as Claude subagents do,
    one stretch of activity at a time since one agent can serve for hours. The
    reviewer that approves commands is left out: it runs only while its parent
    does, and it wakes as a thread resumes, which would bridge the pause before."""
    threads = {}
    spans = defaultdict(list)
    for path in codex_files():
        meta, stamps, prompts = read_rollout(path)
        if not stamps:
            continue
        source = meta.get("source")
        subagent = source.get("subagent") if isinstance(source, dict) else None
        if subagent is not None:
            if isinstance(subagent, dict) and "thread_spawn" in subagent:
                spans[meta.get("parent_thread_id")] += [(start, end) for start, end, _, _
                                                        in split_blocks(stamps, gap)]
            continue
        thread = threads.setdefault(meta.get("id") or path.stem, {
            "stamps": [], "prompts": [], "branches": set(), "cwd": meta.get("cwd") or ""})
        thread["stamps"] += stamps
        thread["prompts"] += prompts
        branch = (meta.get("git") or {}).get("branch")
        if branch:
            thread["branches"].add(branch)

    titles = codex_titles()
    for thread_id, thread in threads.items():
        stamps = sorted(thread["stamps"])
        yield {
            "id": thread_id,
            "stamps": stamps,
            "prompts": [(bisect.bisect_right(stamps, when), text) for when, text in thread["prompts"]],
            "titles": [(None, titles[thread_id])] if thread_id in titles else [],
            "cwd": thread["cwd"],
            "branches": sorted(thread["branches"]),
            "entrypoints": [CODEX_ENTRYPOINT],
            "subagents": spans.get(thread_id, []),
        }

# ── Repo resolution ─────────────────────────────────────────

_repo_cache = {}


def resolve_repo(cwd):
    """Map a session's cwd to a repo name, normalizing subdirectories and worktrees.

    Returns (name, resolved). Unresolved means the directory is gone or is not a
    repo, so the name is only a guess from the path."""
    if not cwd:
        return "", False
    if cwd in _repo_cache:
        return _repo_cache[cwd]

    top = _hook.run(["git", "-C", cwd, "rev-parse", "--show-toplevel"])
    result = (get_repo_name(top), True) if top else (os.path.basename(cwd.rstrip("/")), False)
    _repo_cache[cwd] = result
    return result

# ── Session building ────────────────────────────────────────

def build_sessions(gap_mins, tail_mins, bridge_mins):
    """Read every transcript and Codex thread and merge activity blocks into per-repo sessions."""
    gap = timedelta(minutes=gap_mins)
    tail = timedelta(minutes=tail_mins)
    bridge = timedelta(minutes=bridge_mins)
    raw = defaultdict(list)
    skipped = defaultdict(int)
    bridged = []

    for session in chain(claude_sessions(), codex_sessions(gap)):
        stamps = session["stamps"]
        repo, resolved = resolve_repo(session["cwd"])
        if not repo:
            skipped["no cwd"] += 1
            continue
        if is_ignored(repo):
            skipped[repo] += 1
            continue

        bridges, spans_bridged = find_bridges(stamps, session["subagents"], gap, bridge)
        bridged.extend(spans_bridged)

        for start, end, first_idx, count in split_blocks(stamps, gap, bridges):
            raw[repo].append({
                "start": start,
                "end": end + tail,
                "messages": count,
                "session_ids": [session["id"]],
                "branches": session["branches"],
                "entrypoints": session["entrypoints"],
                "cwd": session["cwd"],
                "resolved": resolved,
                "titles": pick_by_position(session["titles"], first_idx, count),
                "prompts": pick_by_position(session["prompts"], first_idx, count),
            })

    sessions = {repo: merge_blocks(blocks) for repo, blocks in raw.items()}
    return sessions, skipped, bridged


def merge_blocks(blocks):
    """Union overlapping blocks within a repo so parallel sessions count once."""
    merged = []
    for block in sorted(blocks, key=lambda b: b["start"]):
        if merged and block["start"] <= merged[-1]["end"]:
            prev = merged[-1]
            prev["end"] = max(prev["end"], block["end"])
            prev["messages"] += block["messages"]
            for key in ("session_ids", "branches", "entrypoints", "titles", "prompts"):
                prev[key] = list(dict.fromkeys(prev[key] + block[key]))
        else:
            merged.append(dict(block))
    return merged


def to_record(repo, block):
    hours = (block["end"] - block["start"]).total_seconds() / 3600
    return {
        "start": block["start"].strftime(TIMESTAMP_FMT),
        "end": block["end"].strftime(TIMESTAMP_FMT),
        "hours": round(hours, 2),
        "event": "session",
        "repo": repo,
        "client": get_client(repo),
        "branches": block["branches"],
        "entrypoints": block["entrypoints"],
        "session_ids": block["session_ids"],
        "titles": list(dict.fromkeys(block["titles"]))[:MAX_PROMPTS],
        "prompts": list(dict.fromkeys(block["prompts"]))[:MAX_PROMPTS],
        "messages": block["messages"],
        "cwd": block["cwd"],
        "resolved": block["resolved"],
    }

# ── Overlap across repos ────────────────────────────────────

def merged_hours(spans):
    """Total wall-clock hours covered by spans, counting overlap once."""
    total = timedelta()
    end = None
    start = None
    for span_start, span_end in sorted(spans):
        if end is None or span_start > end:
            if end is not None:
                total += end - start
            start, end = span_start, span_end
        else:
            end = max(end, span_end)
    if end is not None:
        total += end - start
    return total.total_seconds() / 3600

# ── Git-side estimate, for comparison ───────────────────────

def git_sessions(since):
    """Estimate hours per repo from activity.jsonl using the timelog skill's rules."""
    if not ACTIVITY.exists():
        return {}

    events = defaultdict(list)
    with open(ACTIVITY, errors="replace") as f:
        for line in f:
            try:
                event = json.loads(line)
            except Exception:
                continue
            stamp = parse_ts(event.get("timestamp", ""))
            if not stamp or (since and stamp < since):
                continue
            events[event.get("repo", "")].append((stamp, event))

    result = {}
    for repo, rows in events.items():
        if not repo or is_ignored(repo):
            continue
        groups = git_groups(sorted(rows, key=lambda r: r[0]))
        result[repo] = {"hours": sum(estimate_git_group(g) for g in groups), "sessions": len(groups)}
    return result


def git_groups(rows):
    """Split time-ordered (stamp, event) rows into stretches of work at gaps over GIT_GAP_MINS."""
    gap = timedelta(minutes=GIT_GAP_MINS)
    groups = []
    for row in rows:
        if groups and row[0] - groups[-1][-1][0] <= gap:
            groups[-1].append(row)
        else:
            groups.append([row])
    return groups


def estimate_git_group(group):
    if len(group) > 1:
        return (group[-1][0] - group[0][0]).total_seconds() / 3600

    event = group[0][1]
    size = event.get("insertions", 0) + event.get("deletions", 0)
    mins = GIT_ISOLATED_LARGE_MINS if size > GIT_LARGE_DIFF_LINES else GIT_ISOLATED_SMALL_MINS
    return mins / 60

# ── Output ──────────────────────────────────────────────────

def write_sessions(sessions):
    DIR.mkdir(parents=True, exist_ok=True)
    records = [to_record(repo, block) for repo, blocks in sessions.items() for block in blocks]
    records.sort(key=lambda r: r["start"])

    tmp = SESSIONS.with_suffix(".jsonl.tmp")
    with open(tmp, "w") as f:
        for record in records:
            f.write(json.dumps(record) + "\n")
    os.replace(tmp, SESSIONS)
    return records


def filter_since(sessions, since):
    if not since:
        return sessions
    return {repo: [b for b in blocks if b["start"] >= since]
            for repo, blocks in sessions.items()}


def report(sessions, since, skipped, tail_mins, bridged):
    sessions = {repo: blocks for repo, blocks in filter_since(sessions, since).items() if blocks}
    git = git_sessions(since)
    repos = sorted(set(sessions) | set(git))

    rows = []
    for repo in repos:
        blocks = sessions.get(repo, [])
        measured = sum((b["end"] - b["start"]).total_seconds() / 3600 for b in blocks)
        resolved = all(b.get("resolved") for b in blocks) if blocks else True
        rows.append({
            "repo": repo,
            "client": get_client(repo),
            "count": len(blocks),
            "measured": measured,
            "commits": git.get(repo, {}).get("sessions", 0),
            "estimate": git.get(repo, {}).get("hours", 0.0),
            "resolved": resolved,
        })

    known = [r for r in rows if r["resolved"]]
    unknown = [r for r in rows if not r["resolved"]]
    for group in (known, unknown):
        group.sort(key=lambda r: -max(r["measured"], r["estimate"]))

    labels = [f"{r['repo']} ({r['client']})" if r["client"] else r["repo"] for r in rows]
    width = max([len(l) for l in labels] + [13])

    def print_rows(group):
        for r in group:
            label = f"{r['repo']} ({r['client']})" if r["client"] else r["repo"]
            print(f"{label.ljust(width)}  {r['count']:>8}  {r['measured']:>8.1f}h  "
                  f"{r['commits']:>8}  {r['estimate']:>7.1f}h  "
                  f"{r['measured'] - r['estimate']:>+6.1f}h")

    print(f"\n{'repo (client)'.ljust(width)}  {'sessions':>8}  {'measured':>9}  "
          f"{'commits':>8}  {'git est':>8}  {'diff':>7}")
    print("-" * (width + 50))
    print_rows(known)

    if unknown:
        print(f"\n{'unresolved — directory gone or not a repo'.ljust(width)}")
        print("-" * (width + 50))
        print_rows(unknown)

    total_measured = sum(r["measured"] for r in rows)
    total_estimate = sum(r["estimate"] for r in rows)
    total_count = sum(r["count"] for r in rows)
    print("-" * (width + 50))
    print(f"{'TOTAL'.ljust(width)}  {total_count:>8}  {total_measured:>8.1f}h  "
          f"{sum(r['commits'] for r in rows):>8}  {total_estimate:>7.1f}h  "
          f"{total_measured - total_estimate:>+6.1f}h")

    if unknown:
        known_measured = sum(r["measured"] for r in known)
        print(f"{'  of which resolved'.ljust(width)}  "
              f"{sum(r['count'] for r in known):>8}  {known_measured:>8.1f}h")

    padding = total_count * tail_mins / 60
    print(f"\nIncludes {padding:.1f}h of tail padding "
          f"({tail_mins} min x {total_count} sessions) — a guess, tune with --tail.")

    spans = [(b["start"], b["end"]) for blocks in sessions.values() for b in blocks]
    wall = merged_hours(spans)
    count, time_bridged = bridged_in_range(bridged, since, None)
    if count:
        print(f"Bridged {time_bridged.total_seconds() / 3600:.1f}h of subagent waits "
              f"across {count} gaps (--bridge {DEFAULT_BRIDGE_MINS} min).")
    if total_measured - wall > 0.05:
        print(f"Parallel sessions across repos overlap by {total_measured - wall:.1f}h — "
              f"{wall:.1f}h of actual wall-clock time.")
    if skipped:
        print("Skipped: " + ", ".join(f"{k} ({v})" for k, v in sorted(skipped.items())))


# ── Digest for the timelog skill ────────────────────────────

# Billing policy: a started task bills at least 30 minutes, and part-hours
# round up to the next 30-minute step (1h05 bills 1h30).
BILL_STEP_MINS = 30
BILL_MINIMUM_MINS = 30


def bill_hours(hours):
    step = BILL_STEP_MINS / 60
    return max(BILL_MINIMUM_MINS / 60, math.ceil(hours / step - 1e-9) * step)


def round_clock(when):
    minute = 30 if 15 <= when.minute < 45 else 0
    hour = when.hour + (1 if when.minute >= 45 else 0)
    return when.replace(minute=minute, second=0, microsecond=0) + timedelta(hours=hour - when.hour)


def load_commits(since):
    """Commits from `since` on, as (local time, event)."""
    if not ACTIVITY.exists():
        return []

    commits = []
    with open(ACTIVITY, errors="replace") as f:
        for line in f:
            if '"event": "commit"' not in line:
                continue
            try:
                event = json.loads(line)
            except Exception:
                continue
            stamp = parse_ts(event.get("timestamp", ""))
            if not stamp or stamp < since:
                continue
            commits.append((stamp.astimezone(), event))
    return commits


def billable_sessions(sessions, since, until, merge_mins):
    """Merge per-repo sessions into per-client billable sessions in local time.

    The billable unit is continuous work for one client, not one Claude Code
    session — sessions get restarted mid-task to manage context, so a billable
    session routinely spans several of them and several repos of that client.
    The merge uses the same gap that split the blocks; a separate threshold
    here would silently override --gap."""
    merge = timedelta(minutes=merge_mins)
    by_client = defaultdict(list)

    for repo, blocks in sessions.items():
        for block in blocks:
            if block["start"] < since or (until and block["start"] > until):
                continue
            client = get_client(repo) or repo
            by_client[client].append((block["start"].astimezone(),
                                      block["end"].astimezone(), repo, block))

    result = {}
    for client, blocks in by_client.items():
        merged = []
        for start, end, repo, block in sorted(blocks):
            if merged and start - merged[-1]["end"] < merge:
                current = merged[-1]
                current["end"] = max(current["end"], end)
                current["repos"].add(repo)
                current["blocks"].append(block)
            else:
                merged.append({"start": start, "end": end, "repos": {repo}, "blocks": [block]})
        result[client] = merged
    return result


def cross_client_overlaps(billable):
    """Pairs of sessions from different clients covering the same wall-clock time.

    Reported for visibility only — parallel work bills to every client."""
    flat = [(s["start"], s["end"], client) for client, rows in billable.items() for s in rows]
    flat.sort()
    overlaps = []
    for i, (start, end, client) in enumerate(flat):
        for other_start, other_end, other in flat[i + 1:]:
            if other_start >= end:
                break
            if other == client:
                continue
            shared_end = min(end, other_end)
            shared = (shared_end - other_start).total_seconds() / 3600
            if shared > 0.05:
                overlaps.append((shared, client, other, other_start, shared_end))

    # Summing pairs double-counts when three clients overlap at once, so the
    # headline figure is the union of the overlapping stretches.
    union = merged_hours([(start, end) for _, _, _, start, end in overlaps])
    return sorted(overlaps, reverse=True), union


def bridged_in_range(bridged, since, until):
    rows = [(when, length) for when, length in bridged
            if (not since or when >= since) and (not until or when <= until)]
    return len(rows), sum((length for _, length in rows), timedelta())


# Busy caps an externalId at 50 characters, and the key must survive intact
# for a re-push to update its own entry rather than add a second one.
SLUG_CHARS = 20


def slug(text):
    trimmed = re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", text.lower())).strip("-")
    return trimmed[:SLUG_CHARS].rstrip("-")


def block_sources(block):
    """Which tools a block's activity came from: "claude", "codex" or both."""
    return {"codex" if e == CODEX_ENTRYPOINT else "claude" for e in block["entrypoints"]} or {"claude"}


def digest_rows(sessions, since, until, gap_mins):
    """One row per billable line: merged per client, billed, commits matched.

    A line keeps the commits made inside it even when it runs past `until`, and
    a commit inside a session that started before the range is left to that
    session's line rather than estimated a second time.

    Both --report and --json render from this, so the printed digest and the
    machine-readable one can never drift apart."""
    billable = billable_sessions(sessions, since, until, gap_mins)
    commits = load_commits(since)
    covered = set()
    rows = []

    for client in sorted(billable):
        for row in sorted(billable[client], key=lambda r: r["start"]):
            span = (row["end"] - row["start"]).total_seconds() / 3600
            hours = bill_hours(span)
            start = round_clock(row["start"])

            inside = []
            for stamp, event in commits:
                if row["start"] <= stamp <= row["end"] and event.get("repo") in row["repos"]:
                    inside.append(event)
                    covered.add(event.get("commit_hash"))

            rows.append({
                "client": client,
                "begin": row["start"],
                "start": start,
                "end": start + timedelta(hours=hours),
                "hours": hours,
                "span": span,
                "measured": sum((b["end"] - b["start"]).total_seconds() / 3600
                                for b in row["blocks"]),
                "messages": sum(b["messages"] for b in row["blocks"]),
                "restarts": len({sid for b in row["blocks"] for sid in b["session_ids"]}),
                "sources": sorted(set().union(*(block_sources(b) for b in row["blocks"]))),
                "repos": sorted(row["repos"]),
                "titles": list(dict.fromkeys(t for b in row["blocks"] for t in b["titles"])),
                "prompts": list(dict.fromkeys(p for b in row["blocks"] for p in b["prompts"])),
                "commits": list(dict.fromkeys(e.get("commit_message", "") for e in inside)),
                "commit_count": len(inside),
                "resolved": all(b.get("resolved") for b in row["blocks"]),
                "key": f"gtt:{start:%Y-%m-%d}:{slug(client)}:{start:%H%M}",
            })

    outside = defaultdict(list)
    for stamp, event in commits:
        repo = event.get("repo", "")
        if event.get("commit_hash") in covered or (until and stamp > until):
            continue
        if any(b["start"] <= stamp <= b["end"] for b in sessions.get(repo, [])):
            continue
        outside[get_client(repo) or repo].append((stamp, event))
    stray = [{"client": client, "commits": group, "hours": estimate_git_group(group)}
             for client in sorted(outside)
             for group in git_groups(sorted(outside[client], key=lambda r: r[0]))]

    unmapped = set()
    for blocks in billable.values():
        for row in blocks:
            for block in row["blocks"]:
                if not block.get("resolved"):
                    continue
                for repo in row["repos"]:
                    if not get_client(repo):
                        unmapped.add(repo)

    return rows, stray, billable, unmapped


def digest(sessions, since, until, bridged, gap_mins):
    """Compact, pre-aggregated output for the timelog skill to describe and format."""
    rows, stray, billable, unmapped = digest_rows(sessions, since, until, gap_mins)

    end_label = (until or datetime.now(timezone.utc)).astimezone()
    print(f"RANGE {since.astimezone():%Y-%m-%d %H:%M} .. {end_label:%Y-%m-%d %H:%M} (local)")

    total_entries = len(rows)
    brief = total_entries > BRIEF_THRESHOLD

    grand = sum(r["hours"] for r in rows)
    billed_raw = sum(r["span"] for r in rows)
    measured = sum(r["measured"] for r in rows)

    client = None
    for row in rows:
        if row["client"] != client:
            client = row["client"]
            print(f"\n{client}")

        head = (f"  {row['begin']:%a %d.%m}  {row['start']:%H:%M}-{row['end']:%H:%M}  "
                f"{row['hours']:>4.1f}h")
        via = "+".join(row["sources"])
        if brief:
            labels = row["titles"] + row["prompts"] + row["commits"]
            first = labels[0][:DIGEST_CHARS] if labels else ""
            print(f"{head}  [{row['commit_count']}c, {row['restarts']}s {via}, "
                  f"{'+'.join(row['repos'])}]  {first}")
            continue

        print(f"{head}  [{row['messages']} msg, {row['commit_count']} commits, "
              f"{row['restarts']} {via} session{'s' if row['restarts'] != 1 else ''}, "
              f"{'+'.join(row['repos'])}]")
        for label in ("titles", "prompts"):
            values = row[label][:3]
            if values:
                print(f"    {label}: " + " | ".join(v[:DIGEST_CHARS] for v in values))
        if row["commits"]:
            shown = row["commits"][:MAX_COMMITS_SHOWN]
            more = f" (+{len(row['commits']) - len(shown)})" if len(row["commits"]) > len(shown) else ""
            print("    commits: " + " | ".join(x[:DIGEST_CHARS] for x in shown) + more)
        if not row["resolved"]:
            print("    NOTE unresolved repo — name guessed from a path that no longer exists")

    if stray:
        print("\nCOMMITS OUTSIDE ANY SESSION (work without Claude Code or Codex — estimate these)")
        for group in stray:
            commits = group["commits"]
            subjects = list(dict.fromkeys(e.get("commit_message", "") for _, e in commits))
            print(f"  {group['client']}: {len(commits)} commit{'s' if len(commits) != 1 else ''}, "
                  f"~{group['hours']:.1f}h est  "
                  f"({commits[0][0]:%a %d.%m %H:%M}-{commits[-1][0]:%H:%M})")
            print("    " + " | ".join(x[:DIGEST_CHARS] for x in subjects[:MAX_COMMITS_SHOWN]))

    overlaps, union = cross_client_overlaps(billable)
    if overlaps:
        print(f"\nPARALLEL WORK {union:.1f}h of wall-clock time across {len(overlaps)} "
              f"client pairs — billed to each client, already counted in TOTAL")
        for shared, a, b, start, end in overlaps[:10]:
            print(f"  {start:%a %d.%m} {start:%H:%M}-{end:%H:%M}  {shared:.1f}h  {a} vs {b}")

    print(f"\nTOTAL {grand:.1f}h billable across {total_entries} entries "
          f"(min {BILL_MINIMUM_MINS} min each, rounded up to {BILL_STEP_MINS}-min steps, "
          f"parallel work billed to every client)")
    print(f"MEASURED {measured:.1f}h of actual session activity "
          f"(+{billed_raw - measured:.1f}h sub-{gap_mins}-min gaps merged, "
          f"+{grand - billed_raw:.1f}h rounded up)")
    if brief:
        print(f"BRIEF one line per entry ({total_entries} > {BRIEF_THRESHOLD}); "
              f"narrow the range for titles, prompts and commit subjects")
    count, time_bridged = bridged_in_range(bridged, since, until)
    if count:
        print(f"BRIDGED {time_bridged.total_seconds() / 3600:.1f}h of subagent waits "
              f"in {count} gaps")
    if unmapped:
        print("UNMAPPED " + ", ".join(sorted(unmapped)) + " — suggest /git-timetrack:map-client")


def digest_json(sessions, since, until, gap_mins):
    """The same rows as --report, for busy-push.py.

    `description` is left empty on purpose: the clock comes from here, the
    client-facing wording from the timelog skill."""
    rows, stray, _, unmapped = digest_rows(sessions, since, until, gap_mins)

    entries = [{
        "key": row["key"],
        "client": row["client"],
        "date": f"{row['start']:%Y-%m-%d}",
        "start": f"{row['start']:%H:%M}",
        "hours": round(row["hours"], 2),
        "description": "",
        "evidence": {
            "repos": row["repos"],
            "sources": row["sources"],
            "sessions": row["restarts"],
            "messages": row["messages"],
            "titles": row["titles"][:6],
            "prompts": row["prompts"][:6],
            "commits": row["commits"][:MAX_COMMITS_SHOWN],
        },
    } for row in rows]

    print(json.dumps({
        "range": {"since": f"{since.astimezone():%Y-%m-%d}",
                  "until": f"{(until or datetime.now(timezone.utc)).astimezone():%Y-%m-%d}"},
        "total_hours": round(sum(r["hours"] for r in rows), 2),
        "entries": entries,
        "outside_sessions": [{
            "client": group["client"],
            "date": f"{group['commits'][0][0]:%Y-%m-%d}",
            "first_commit": f"{group['commits'][0][0]:%H:%M}",
            "last_commit": f"{group['commits'][-1][0]:%H:%M}",
            "commits": len(group["commits"]),
            "estimated_hours": round(group["hours"], 2),
            "subjects": list(dict.fromkeys(e.get("commit_message", "") for _, e in group["commits"])),
        } for group in stray],
        "unmapped_repos": sorted(unmapped),
    }, indent=2, ensure_ascii=False))

# ── Main ────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true",
                        help="compare measured sessions against git estimates, write nothing")
    parser.add_argument("--report", action="store_true",
                        help="print a compact digest of the range for the timelog skill")
    parser.add_argument("--json", action="store_true",
                        help="print the same rows as JSON, for busy-push.py")
    parser.add_argument("--until", metavar="DATE",
                        help="report sessions starting on/before this date (YYYY-MM-DD)")
    parser.add_argument("--since", metavar="DATE",
                        help="report sessions starting on/after this date (YYYY-MM-DD)")
    parser.add_argument("--days", type=int, metavar="N",
                        help="report only the last N days")
    parser.add_argument("--gap", type=int, default=DEFAULT_GAP_MINS, metavar="MINS",
                        help=f"pause that ends a session (default {DEFAULT_GAP_MINS})")
    parser.add_argument("--tail", type=int, default=DEFAULT_TAIL_MINS, metavar="MINS",
                        help=f"padding after the last message (default {DEFAULT_TAIL_MINS})")
    parser.add_argument("--bridge", type=int, default=DEFAULT_BRIDGE_MINS, metavar="MINS",
                        help="keep a session whole across a subagent wait up to this long "
                             f"(default {DEFAULT_BRIDGE_MINS}, 0 disables)")
    args = parser.parse_args()

    if not TRANSCRIPTS.is_dir() and not (CODEX / "sessions").is_dir():
        sys.exit(f"No transcripts at {TRANSCRIPTS} or {CODEX / 'sessions'}")

    since = None
    if args.since:
        since = datetime.strptime(args.since, "%Y-%m-%d").astimezone()
    elif args.days:
        since = datetime.now(timezone.utc) - timedelta(days=args.days)

    sessions, skipped, bridged = build_sessions(args.gap, args.tail, args.bridge)

    until = None
    if args.until:
        until = (datetime.strptime(args.until, "%Y-%m-%d")
                 .replace(hour=23, minute=59, second=59).astimezone())

    if args.report or args.json:
        if not since:
            since = datetime.now(timezone.utc) - timedelta(days=7)
        if not args.dry_run:
            write_sessions(sessions)
        if args.json:
            digest_json(sessions, since, until, args.gap)
        else:
            digest(sessions, since, until, bridged, args.gap)
        return

    if args.dry_run:
        report(sessions, since, skipped, args.tail, bridged)
        return

    records = write_sessions(sessions)
    hours = sum(r["hours"] for r in records)
    print(f"Wrote {len(records)} sessions ({hours:.1f}h) to {SESSIONS}")


if __name__ == "__main__":
    main()
