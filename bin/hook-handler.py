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


def get_repo_name(cwd):
    """Derive repo name from git remote origin URL, falling back to directory name."""
    if not cwd:
        return "unknown"
    url = run(["git", "-C", cwd, "remote", "get-url", "origin"])
    if url:
        # Handle SSH (git@github.com:org/repo.git) and HTTPS (https://github.com/org/repo.git)
        name = url.rstrip("/").rsplit("/", 1)[-1].rsplit(":", 1)[-1]
        if name.endswith(".git"):
            name = name[:-4]
        if name:
            return name
    return os.path.basename(cwd)


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
    repo = get_repo_name(cwd)

    if is_ignored(repo):
        return

    info = gather_git_state(event, cwd)
    log_entry(make_entry(event, repo, command=cmd, cwd=cwd, **info))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # Never fail loudly — don't disrupt Claude Code
