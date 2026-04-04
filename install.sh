#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════╗
# ║  git-timetrack — passive time tracking from git activity  ║
# ║                                                           ║
# ║  Install:    bash install.sh                              ║
# ║  Uninstall:  bash install.sh --uninstall                  ║
# ╚═══════════════════════════════════════════════════════════╝

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

DIR="$HOME/.git-timetrack"
BIN="$HOME/.local/bin"
CLAUDE_DIR="$HOME/.claude"
CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"

# ─────────────────────────────────────────────────────────────
# Uninstall
# ─────────────────────────────────────────────────────────────

if [ "$1" = "--uninstall" ]; then
    echo -e "\n${BOLD}Removing git-timetrack...${NC}\n"

    # Restore original git hooks path if we set it
    CURRENT_HOOKS="$(git config --global core.hooksPath 2>/dev/null || echo "")"
    if [ "$CURRENT_HOOKS" = "$DIR/hooks" ]; then
        git config --global --unset core.hooksPath
        echo -e "  ${GREEN}✓${NC} Restored default git hooks path"
    fi

    rm -f "$BIN/weeklog" "$BIN/map-client"
    rm -f "$CLAUDE_DIR/commands/weeklog.md"
    echo -e "  ${GREEN}✓${NC} Removed commands"

    if [ -f "$DIR/activity.jsonl" ]; then
        echo -e "\n  ${YELLOW}Keep your activity data? ($DIR/activity.jsonl)${NC}"
        printf "  [Y/n] "; read -r KEEP
        if [ "$KEEP" = "n" ] || [ "$KEEP" = "N" ]; then
            rm -rf "$DIR"
            echo -e "  ${GREEN}✓${NC} All data removed"
        else
            rm -f "$DIR/hook-handler.py" "$DIR/map-client.sh" "$DIR/weeklog.sh"
            rm -rf "$DIR/hooks"
            echo -e "  ${GREEN}✓${NC} Tools removed, data preserved"
        fi
    else
        rm -rf "$DIR"
    fi

    if [ -f "$CLAUDE_SETTINGS" ] && grep -q "git-timetrack" "$CLAUDE_SETTINGS" 2>/dev/null; then
        python3 << CLEANUP_PY
import json, sys

path = "$CLAUDE_SETTINGS"
GREEN = "\033[0;32m"
YELLOW = "\033[1;33m"
DIM = "\033[2m"
NC = "\033[0m"

try:
    with open(path) as f:
        config = json.load(f)

    # Remove any hook entries that reference git-timetrack
    hooks = config.get("hooks", {})
    for event_key in list(hooks.keys()):
        entries = hooks[event_key]
        if isinstance(entries, list):
            hooks[event_key] = [
                entry for entry in entries
                if not (isinstance(entry, dict) and "git-timetrack" in json.dumps(entry))
            ]
            if not hooks[event_key]:
                del hooks[event_key]

    # Remove the hooks key entirely if empty
    if not hooks:
        config.pop("hooks", None)

    with open(path, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\\n")

    print(f"  {GREEN}\\u2713{NC} Claude Code hook removed from settings.json")

except Exception as ex:
    print(f"  {YELLOW}Note:{NC} Could not auto-clean {path}: {ex}", file=sys.stderr)
    print(f"  {DIM}Remove the git-timetrack hook entry manually.{NC}", file=sys.stderr)
CLEANUP_PY
    fi

    echo -e "\n${GREEN}Done.${NC}\n"
    exit 0
fi

# ─────────────────────────────────────────────────────────────
# Install
# ─────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}git-timetrack${NC} — passive time tracking from git activity"
echo -e "${DIM}No timers. No buttons. Just code.${NC}"
echo ""

# ── Detect environment ───────────────────────────────────────

HAS_CLAUDE=false
if command -v claude &>/dev/null; then
    HAS_CLAUDE=true
fi

# Check if git hooks path is already set to something else
EXISTING_HOOKS="$(git config --global core.hooksPath 2>/dev/null || echo "")"
HOOKS_CONFLICT=false
if [ -n "$EXISTING_HOOKS" ] && [ "$EXISTING_HOOKS" != "$DIR/hooks" ]; then
    HOOKS_CONFLICT=true
fi

# ── Choose mode ──────────────────────────────────────────────

echo -e "${BOLD}How do you want to track?${NC}"
echo ""
if [ "$HAS_CLAUDE" = true ]; then
    echo -e "  ${CYAN}1${NC}  Claude Code hooks    ${DIM}— tracks git commands inside Claude Code sessions${NC}"
fi
echo -e "  ${CYAN}2${NC}  Global git hooks     ${DIM}— tracks all git activity across every repo${NC}"
if [ "$HAS_CLAUDE" = true ]; then
    echo -e "  ${CYAN}3${NC}  Both                 ${DIM}— maximum coverage${NC}"
fi
echo ""

if [ "$HAS_CLAUDE" = true ]; then
    printf "  Choose [1/2/3]: "; read -r MODE
else
    echo -e "  ${DIM}(Claude Code not detected — installing global git hooks)${NC}"
    MODE=2
fi

INSTALL_CLAUDE=false
INSTALL_GIT=false

case "$MODE" in
    1) INSTALL_CLAUDE=true;;
    3) INSTALL_CLAUDE=true; INSTALL_GIT=true;;
    *) INSTALL_GIT=true;;
esac

# ── Create directories ───────────────────────────────────────

mkdir -p "$DIR" "$BIN"

# ── Hook handler (shared by both modes) ──────────────────────

cat > "$DIR/hook-handler.py" << 'HANDLER_PY'
#!/usr/bin/env python3
"""
git-timetrack hook handler.

Accepts input two ways:
  - stdin JSON  → Claude Code PostToolUse mode
  - CLI args    → git hook mode: hook-handler.py <event> [args...]
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
# Events the global git hooks can fire (subset of TRACKED_COMMANDS)
GIT_HOOK_EVENTS = ("commit", "checkout", "merge")

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
    """Gather current git state by running git commands in cwd. Shared by both handlers."""
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
            # Seek to end, read the last 512 bytes (enough for one entry)
            f.seek(0, 2)
            size = f.tell()
            if size == 0:
                return None
            f.seek(max(0, size - 512))
            tail = f.read().decode("utf-8", errors="replace")

        # Grab the last non-empty line
        for line in reversed(tail.strip().split("\n")):
            if line.strip():
                return json.loads(line)
    except Exception:
        pass
    return None


def is_duplicate(entry):
    """Check if the entry duplicates the last log line (same event+repo+hash within a few seconds).

    This prevents double-logging when both Claude Code hooks and global git hooks
    are active simultaneously.
    """
    last = read_last_entry()
    if last is None:
        return False

    # Different event, repo, or commit hash → not a duplicate
    if (last.get("event") != entry.get("event") or
            last.get("repo") != entry.get("repo") or
            last.get("commit_hash") != entry.get("commit_hash")):
        return False

    # Same event — check if timestamps are within the dedup window
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

# ── Handlers ────────────────────────────────────────────────

def handle_claude_code():
    """Claude Code PostToolUse mode — reads JSON from stdin."""
    data = json.loads(sys.stdin.read())

    # Extract the command that was run
    cmd = data.get("tool_input", {}).get("command", "")

    # Check if it's a git command we track
    event = detect_git_command(cmd)
    if not event:
        return

    # Extract working directory
    cwd = data.get("cwd", "")
    repo = os.path.basename(cwd) if cwd else "unknown"

    if is_ignored(repo):
        return

    # Gather git state by running commands (same approach as git hook handler)
    info = gather_git_state(event, cwd)
    log_entry(make_entry(event, repo, command=cmd, cwd=cwd, **info))


def handle_git_hook():
    """Global git hook mode — called with event type as arg."""
    event = sys.argv[1] if len(sys.argv) > 1 else ""
    if event not in GIT_HOOK_EVENTS:
        return

    cwd = run(["git", "rev-parse", "--show-toplevel"]) or os.getcwd()
    repo = os.path.basename(cwd)
    if is_ignored(repo):
        return

    info = gather_git_state(event, cwd)
    log_entry(make_entry(event, repo, cwd=cwd, **info))

# ── Main ────────────────────────────────────────────────────

if __name__ == "__main__":
    try:
        if len(sys.argv) > 1 and sys.argv[1] in GIT_HOOK_EVENTS:
            handle_git_hook()
        else:
            handle_claude_code()
    except Exception:
        pass  # Never block git operations, never fail loudly
HANDLER_PY

echo -e "  ${GREEN}✓${NC} Hook handler installed"

# ── Ignore file (with example) ───────────────────────────────

if [ ! -f "$DIR/ignore" ]; then
    cat > "$DIR/ignore" << 'IGNOREFILE'
# Repos to exclude from tracking (one name per line)
# Example:
# personal-dotfiles
# throwaway-test
IGNOREFILE
fi

# ── Client mapper ────────────────────────────────────────────

cat > "$DIR/map-client.sh" << 'MAPPER'
#!/usr/bin/env bash
# map-client — map git repos to client names for time tracking
set -e

MAP="$HOME/.git-timetrack/clients.json"
LOG="$HOME/.git-timetrack/activity.jsonl"

# Ensure the mapping file exists
[ ! -f "$MAP" ] && echo '{}' > "$MAP"

# ── Helper: safely update the JSON map ──────────────────────

update_map() {
    local repo="$1" client="$2"
    local tmp
    tmp=$(mktemp)
    if jq --arg r "$repo" --arg c "$client" '. + {($r):$c}' "$MAP" > "$tmp"; then
        mv "$tmp" "$MAP"
    else
        rm -f "$tmp"
        return 1
    fi
}

# ── Commands ────────────────────────────────────────────────

case "$1" in
    --list)
        echo ""
        jq -r 'to_entries[] | "  \(.key) → \(.value)"' "$MAP" 2>/dev/null || cat "$MAP"
        echo ""
        ;;

    --auto)
        [ ! -f "$LOG" ] && echo "No activity yet. Make some commits first!" && exit 0
        echo ""
        while IFS= read -r repo; do
            existing="$(jq -r --arg r "$repo" '.[$r] // ""' "$MAP" 2>/dev/null)"
            if [ -z "$existing" ]; then
                printf "  %s → which client? " "$repo"
                read -r name
                if [ -n "$name" ]; then
                    update_map "$repo" "$name" && echo "  ✓ $repo → $name"
                fi
            else
                echo "  $repo → $existing"
            fi
        done < <(jq -r '.repo' "$LOG" 2>/dev/null | sort -u)
        echo ""
        ;;

    "" | --help | -h)
        echo "Usage: map-client <repo> \"Client Name\""
        echo "       map-client --list"
        echo "       map-client --auto"
        ;;

    *)
        if [ $# -lt 2 ]; then
            echo "Usage: map-client <repo> \"Client Name\""
            exit 1
        fi
        update_map "$1" "$2" && echo "✓ $1 → $2"
        ;;
esac
MAPPER

# ── Weeklog (standalone terminal tool) ───────────────────────

cat > "$DIR/weeklog.sh" << 'WEEKLOG'
#!/usr/bin/env bash
# weeklog — summarize git-timetrack activity
set -e

LOG="$HOME/.git-timetrack/activity.jsonl"
MAP="$HOME/.git-timetrack/clients.json"

# Default date range: this Monday → today
FROM="$(python3 -c "from datetime import date,timedelta;d=date.today();print(d - timedelta(days=d.weekday()))")"
TO="$(date +%Y-%m-%d)"
CLIENT_FILTER=""
DRAFT_EMAILS=false
JSON_OUTPUT=false

# ── Validate a YYYY-MM-DD date string ──────────────────────

validate_date() {
    if ! echo "$1" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
        echo "Error: Invalid date format '$1'. Expected YYYY-MM-DD." >&2
        exit 1
    fi
    if ! python3 -c "from datetime import datetime; datetime.strptime('$1','%Y-%m-%d')" 2>/dev/null; then
        echo "Error: Invalid date '$1'." >&2
        exit 1
    fi
}

# ── Parse arguments ─────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case $1 in
        --from)
            FROM="$2"
            validate_date "$FROM"
            shift 2
            ;;
        --to)
            TO="$2"
            validate_date "$TO"
            shift 2
            ;;
        --client)
            CLIENT_FILTER="$2"
            shift 2
            ;;
        --draft-emails)
            DRAFT_EMAILS=true
            shift
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        --help | -h)
            echo "Usage: weeklog [--from DATE] [--to DATE] [--client NAME] [--json] [--draft-emails]"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

[ ! -f "$LOG" ] && echo "No activity yet. Make some commits first!" && exit 0

exec python3 - "$FROM" "$TO" "$CLIENT_FILTER" "$DRAFT_EMAILS" "$JSON_OUTPUT" << 'PY'
import json, sys, os, re
from datetime import datetime, timedelta
from collections import defaultdict

# ── Time estimation constants ───────────────────────────────
CONTINUOUS_WORK_GAP_MIN = 120   # Max minutes between commits to count as continuous work
DEFAULT_SESSION_MIN = 30        # Minutes assumed for an isolated commit or gap > threshold
CHECKOUT_OVERHEAD_MIN = 5       # Minutes added per branch switch
LINES_PER_HOUR = 50             # Lines changed per estimated hour (for single-commit repos)

# ── Parse arguments ─────────────────────────────────────────
from_date_str, to_date_str, client_filter, draft_emails_str, json_output_str = sys.argv[1:6]
client_filter = client_filter.lower()
draft_emails = draft_emails_str == "true"
json_output = json_output_str == "true"

log_path = os.path.expanduser("~/.git-timetrack/activity.jsonl")
map_path = os.path.expanduser("~/.git-timetrack/clients.json")
client_map = {}
if os.path.exists(map_path):
    with open(map_path) as f:
        client_map = json.load(f)

# ── Load and parse entries ──────────────────────────────────
all_entries = []
if os.path.exists(log_path):
    with open(log_path) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    all_entries.append(json.loads(line))
                except Exception:
                    pass

from_date = datetime.strptime(from_date_str, "%Y-%m-%d")
to_date = datetime.strptime(to_date_str, "%Y-%m-%d") + timedelta(days=1)

# ── Filter to date range and client ─────────────────────────
filtered = []
for entry in all_entries:
    try:
        timestamp = datetime.strptime(entry["timestamp"], "%Y-%m-%dT%H:%M:%SZ")
        if from_date <= timestamp < to_date:
            repo = entry.get("repo", "?")
            client = entry.get("client", "") or client_map.get(repo, "")
            entry["_client"] = client or repo
            entry["_time"] = timestamp
            if client_filter and client_filter not in entry["_client"].lower():
                continue
            filtered.append(entry)
    except Exception:
        pass

if not filtered:
    print(f"\nNo activity found for {from_date_str} \u2192 {to_date_str}")
    if client_filter:
        print(f"(filtered: {client_filter})")
    sys.exit(0)

# ── Group by client ─────────────────────────────────────────
by_client = defaultdict(list)
for entry in sorted(filtered, key=lambda x: x["_time"]):
    by_client[entry["_client"]].append(entry)

def estimate_hours(events):
    """Estimate work hours from commit patterns."""
    commits = [e for e in events if e["event"] == "commit"]
    if not commits:
        return 0.0
    # Single commit: estimate from diff size
    if len(commits) == 1:
        lines = commits[0].get("insertions", 0) + commits[0].get("deletions", 0)
        return max(0.5, min(2.0, lines / LINES_PER_HOUR))
    # Multiple commits: sum gaps (continuous if < threshold, else default session)
    minutes = DEFAULT_SESSION_MIN
    for i in range(1, len(commits)):
        gap = (commits[i]["_time"] - commits[i - 1]["_time"]).total_seconds() / 60
        minutes += gap if gap <= CONTINUOUS_WORK_GAP_MIN else DEFAULT_SESSION_MIN
    # Add overhead for branch switches
    minutes += len([e for e in events if e["event"] == "checkout"]) * CHECKOUT_OVERHEAD_MIN
    return round(minutes / 60, 1)

def clean_message(msg):
    """Translate conventional commit prefixes to business-friendly language."""
    prefix_labels = {
        "fix": "Fixed", "feat": "Added", "chore": "Updated", "refactor": "Improved",
        "docs": "Docs", "perf": "Optimized", "ci": "CI/CD", "style": "Styled", "test": "Tests",
    }
    match = re.match(r'^(fix|feat|chore|refactor|docs|style|test|perf|ci)(\(.+?\))?:\s*', msg)
    if match:
        prefix = prefix_labels.get(match.group(1), "Updated")
        body = msg[match.end():]
        body = body[0].upper() + body[1:] if body else body
        return f"{prefix}: {body}"
    return msg

# ── JSON output mode ────────────────────────────────────────
if json_output:
    result = {}
    for client_name, events in sorted(by_client.items()):
        commits = [e for e in events if e["event"] == "commit"]
        branches = sorted(set(
            e.get("branch", "") for e in events
            if e.get("branch", "") and len(e.get("branch", "")) < 60
        ))
        result[client_name] = {
            "estimated_hours": estimate_hours(events),
            "branches": branches,
            "commits": [{
                "timestamp": e["timestamp"],
                "message": e.get("commit_message", ""),
                "branch": e.get("branch", ""),
                "files_changed": e.get("files_changed", 0),
                "insertions": e.get("insertions", 0),
                "deletions": e.get("deletions", 0),
            } for e in commits],
            "context_switches": len([e for e in events if e["event"] == "checkout"]),
        }
    print(json.dumps(result, indent=2))
    sys.exit(0)

# ── Terminal output mode ────────────────────────────────────
BOLD = "\033[1m"
DIM = "\033[2m"
GREEN = "\033[0;32m"
CYAN = "\033[0;36m"
RESET = "\033[0m"

total_hours = 0
separator = "\u2500" * 40
print(f"\n{BOLD}\u2550\u2550\u2550 Week Log: {from_date_str} \u2192 {to_date_str} \u2550\u2550\u2550{RESET}\n")

for client_name, events in sorted(by_client.items()):
    hours = estimate_hours(events)
    total_hours += hours
    commits = [e for e in events if e["event"] == "commit"]
    print(f"{BOLD}{client_name}{RESET}  {DIM}(~{hours} hrs){RESET}\n")

    # Group commits by day
    by_day = defaultdict(list)
    for commit in commits:
        by_day[commit["_time"].strftime("%a %d %b")].append(commit)

    for day_label, day_commits in by_day.items():
        print(f"  {CYAN}{day_label}{RESET}")
        for commit in day_commits:
            message = commit.get("commit_message", "?")
            files = commit.get("files_changed", 0)
            added = commit.get("insertions", 0)
            deleted = commit.get("deletions", 0)
            stats = f"  {DIM}+{added}/-{deleted} ({files} files){RESET}" if files else ""
            print(f"    \u2022 {message}{stats}")
        print()

    branches = sorted(set(
        e.get("branch", "") for e in events
        if e.get("branch", "") and len(e.get("branch", "")) < 60
    ))
    if branches:
        print(f"  {DIM}Branches: {', '.join(branches)}{RESET}\n")

    if draft_emails and commits:
        print(f"  {GREEN}\U0001f4e7 Draft email:{RESET}\n  {DIM}{separator}{RESET}")
        print(f"  Subject: Weekly update \u2014 {client_name}\n\n  Hi,\n\n  Here's what we worked on this week:\n")
        for commit in commits:
            message = commit.get("commit_message", "")
            if message:
                print(f"    \u2022 {clean_message(message)}")
        print(f"\n  Estimated time: ~{hours} hours\n\n  Let me know if you have any questions.")
        print(f"  {DIM}{separator}{RESET}\n")

    print(f"  {separator}\n")

print(f"{BOLD}Total: ~{total_hours} hrs{RESET}")
unmapped = set(e.get("repo", "") for e in filtered) - set(client_map.keys())
if unmapped:
    print(f"\n{DIM}\U0001f4a1 Unmapped repos: {', '.join(unmapped)} \u2192 run: map-client --auto{RESET}")
print()
PY
WEEKLOG

# ── Symlinks to PATH ────────────────────────────────────────

ln -sf "$DIR/weeklog.sh" "$BIN/weeklog"
ln -sf "$DIR/map-client.sh" "$BIN/map-client"
chmod +x "$DIR/weeklog.sh" "$DIR/map-client.sh"

echo -e "  ${GREEN}✓${NC} weeklog and map-client commands installed"

# ── Initialize client map ────────────────────────────────────

[ ! -f "$DIR/clients.json" ] && echo '{}' > "$DIR/clients.json"

# ── Claude Code mode ─────────────────────────────────────────

if [ "$INSTALL_CLAUDE" = true ]; then
    mkdir -p "$CLAUDE_DIR/commands"

    # Slash command
    cat > "$CLAUDE_DIR/commands/weeklog.md" << 'SLASHCMD'
# /weeklog — Summarize git activity for client updates

Read `~/.git-timetrack/activity.jsonl` and `~/.git-timetrack/clients.json`.

## Task

1. Parse the JSONL log (fields: timestamp, event, repo, branch, client, commit_hash, commit_message, files_changed, insertions, deletions)
2. Resolve repo → client using the mapping file
3. Filter to requested time range (default: this Monday to today)
4. Group by client, then by day
5. Estimate hours: commits <2hrs apart = continuous work; isolated commits = 30min–2hr by diff size; branch switches = +5min overhead
6. Generate a client-friendly summary per client

## Per client, output:

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
- If `$ARGUMENTS` given, adjust (e.g. "in german", "professional", "just acme", "last month")

## Edge cases

- No log file → explain how the hook works and that commits will be tracked automatically
- Unmapped repos → list them, suggest running `map-client --auto`
- Low time estimate → note it only captures git activity
SLASHCMD

    # Hook config
    if [ ! -f "$CLAUDE_SETTINGS" ]; then
        mkdir -p "$CLAUDE_DIR"
        cat > "$CLAUDE_SETTINGS" << 'HOOKJSON'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "if": "Bash(git *)",
            "command": "python3 \"$HOME/.git-timetrack/hook-handler.py\"",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
HOOKJSON
        echo -e "  ${GREEN}✓${NC} Claude Code hook configured"
    elif grep -q "git-timetrack" "$CLAUDE_SETTINGS" 2>/dev/null; then
        echo -e "  ${DIM}  Claude Code hook already configured${NC}"
    else
        echo -e "  ${GREEN}✓${NC} /weeklog slash command installed"
        echo ""
        echo -e "  ${YELLOW}Add this to hooks.PostToolUse in $CLAUDE_SETTINGS:${NC}"
        echo ""
        echo '    {'
        echo '      "matcher": "Bash",'
        echo '      "hooks": [{'
        echo '        "type": "command",'
        echo '        "if": "Bash(git *)",'
        echo '        "command": "python3 \"$HOME/.git-timetrack/hook-handler.py\"",'
        echo '        "timeout": 30'
        echo '      }]'
        echo '    }'
        echo ""
    fi
fi

# ── Global git hooks mode ────────────────────────────────────

if [ "$INSTALL_GIT" = true ]; then
    HOOKS_DIR="$DIR/hooks"
    mkdir -p "$HOOKS_DIR"

    # post-commit hook (synchronous — must capture HEAD before next commit)
    cat > "$HOOKS_DIR/post-commit" << 'GITHOOK'
#!/usr/bin/env bash
python3 "$HOME/.git-timetrack/hook-handler.py" commit
GITHOOK

    # post-checkout hook (can background — branch info comes via args)
    cat > "$HOOKS_DIR/post-checkout" << 'GITHOOK'
#!/usr/bin/env bash
python3 "$HOME/.git-timetrack/hook-handler.py" checkout "$@" &
GITHOOK

    # post-merge hook
    cat > "$HOOKS_DIR/post-merge" << 'GITHOOK'
#!/usr/bin/env bash
python3 "$HOME/.git-timetrack/hook-handler.py" merge &
GITHOOK

    chmod +x "$HOOKS_DIR"/*

    if [ "$HOOKS_CONFLICT" = true ]; then
        echo ""
        echo -e "  ${YELLOW}⚠ You already have core.hooksPath set to: $EXISTING_HOOKS${NC}"
        echo -e "  ${DIM}git-timetrack hooks are in: $HOOKS_DIR${NC}"
        echo -e "  ${DIM}You'll need to call git-timetrack from your existing hooks,${NC}"
        echo -e "  ${DIM}or merge them manually.${NC}"
    else
        git config --global core.hooksPath "$HOOKS_DIR"
        echo -e "  ${GREEN}✓${NC} Global git hooks active"
        echo -e "  ${YELLOW}⚠ Note:${NC} ${DIM}Per-repo hooks (.git/hooks, husky, pre-commit) won't run while${NC}"
        echo -e "  ${DIM}  global core.hooksPath is set. See README FAQ for workarounds.${NC}"
    fi
fi

# ── PATH check ───────────────────────────────────────────────

if ! echo "$PATH" | grep -q "$BIN"; then
    echo ""
    echo -e "  ${YELLOW}Add ~/.local/bin to your PATH:${NC}"
    SHELL_NAME="$(basename "$SHELL")"
    case "$SHELL_NAME" in
        zsh)  echo -e "  ${CYAN}echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc${NC}";;
        fish) echo -e "  ${CYAN}fish_add_path ~/.local/bin${NC}";;
        *)    echo -e "  ${CYAN}echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc && source ~/.bashrc${NC}";;
    esac
fi

# ── Done ─────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}${BOLD}✓ git-timetrack installed${NC}"
echo ""
echo -e "  ${BOLD}Just code. On Friday:${NC}"
echo ""
if [ "$INSTALL_CLAUDE" = true ]; then
    echo -e "    ${CYAN}/weeklog${NC}                  ${DIM}← Claude summarizes your week${NC}"
fi
echo -e "    ${CYAN}weeklog${NC}                   ${DIM}← quick terminal view${NC}"
echo -e "    ${CYAN}weeklog --json${NC}            ${DIM}← structured data${NC}"
echo -e "    ${CYAN}weeklog --draft-emails${NC}    ${DIM}← basic email drafts${NC}"
echo ""
echo -e "  ${BOLD}First time — map your repos to clients:${NC}"
echo -e "    ${CYAN}map-client --auto${NC}"
echo ""
echo -e "  ${BOLD}Exclude a repo:${NC}"
echo -e "    ${DIM}Add the repo name to ~/.git-timetrack/ignore${NC}"
echo ""
