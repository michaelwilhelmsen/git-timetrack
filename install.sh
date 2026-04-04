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
RED='\033[0;31m'
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
        python3 -c "
import json, sys
path = '$CLAUDE_SETTINGS'
try:
    with open(path) as f:
        cfg = json.load(f)
    hooks = cfg.get('hooks', {})
    for event_key in list(hooks.keys()):
        entries = hooks[event_key]
        if isinstance(entries, list):
            hooks[event_key] = [
                e for e in entries
                if not (isinstance(e, dict) and 'git-timetrack' in json.dumps(e))
            ]
            if not hooks[event_key]:
                del hooks[event_key]
    if not hooks:
        cfg.pop('hooks', None)
    with open(path, 'w') as f:
        json.dump(cfg, f, indent=2)
        f.write('\n')
    print('  \033[0;32m\u2713\033[0m Claude Code hook removed from settings.json')
except Exception as ex:
    print(f'  \033[1;33mNote:\033[0m Could not auto-clean {path}: {ex}', file=sys.stderr)
    print(f'  \033[2mRemove the git-timetrack hook entry manually.\033[0m', file=sys.stderr)
" 2>&1
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
  - stdin JSON (Claude Code PostToolUse mode)
  - command-line args (git hook mode): hook-handler.py <event> [args...]
"""
import json, sys, os, re, subprocess, fcntl
from datetime import datetime, timezone
from pathlib import Path

DIR = Path.home() / ".git-timetrack"
LOG = DIR / "activity.jsonl"
CLIENTS = DIR / "clients.json"
IGNORE = DIR / "ignore"

TRACKED = {
    "commit": re.compile(r'\bgit\s+commit\b'),
    "push": re.compile(r'\bgit\s+push\b'),
    "checkout": re.compile(r'\bgit\s+(checkout|switch)\b'),
    "merge": re.compile(r'\bgit\s+merge\b'),
    "pull": re.compile(r'\bgit\s+pull\b'),
    "rebase": re.compile(r'\bgit\s+rebase\b'),
}

def get_client(repo):
    if CLIENTS.exists():
        try: return json.loads(CLIENTS.read_text()).get(repo, "")
        except Exception: pass
    return ""

def is_ignored(repo):
    if IGNORE.exists():
        try:
            lines = IGNORE.read_text().strip().split("\n")
            return repo in [l.strip() for l in lines if l.strip() and not l.strip().startswith("#")]
        except Exception: pass
    return False

def run(cmd):
    try: return subprocess.check_output(cmd, stderr=subprocess.DEVNULL, timeout=5).decode().strip()
    except Exception: return ""

def parse_diffstat(text):
    stats = {"files_changed": 0, "insertions": 0, "deletions": 0}
    for pat, key in [(r'(\d+)\s+files?\s+changed', 'files_changed'),
                     (r'(\d+)\s+insertions?\(\+\)', 'insertions'),
                     (r'(\d+)\s+deletions?\(-\)', 'deletions')]:
        m = re.search(pat, text)
        if m: stats[key] = int(m.group(1))
    return stats

def parse_git_output(out, event, cmd=""):
    info = {"commit_message":"","commit_hash":"","branch":"","files_changed":0,
            "insertions":0,"deletions":0,"new_branch":""}
    if event == "commit":
        m = re.search(r'\[(\S+)\s+(\w+)\]\s+(.+)', out)
        if m:
            info["branch"], info["commit_hash"], info["commit_message"] = m.group(1), m.group(2), m.group(3)
        if not info["commit_message"] and cmd:
            m2 = re.search(r'-m\s+["\'](.+?)["\']', cmd)
            if m2: info["commit_message"] = m2.group(1)
        info.update(parse_diffstat(out))
    elif event == "checkout":
        m = re.search(r"Switched to (?:a new )?branch '([^']+)'", out)
        if m: info["new_branch"] = info["branch"] = m.group(1)
    return info

DEDUP_WINDOW_SECS = 5

def is_duplicate(entry):
    """Check if the last logged entry is a duplicate (same event+repo+hash within DEDUP_WINDOW_SECS)."""
    if not LOG.exists():
        return False
    try:
        with open(LOG, "rb") as f:
            f.seek(0, 2)
            pos = f.tell()
            if pos == 0:
                return False
            # Read backwards to find last newline
            buf = b""
            while pos > 0:
                pos = max(pos - 256, 0)
                f.seek(pos)
                buf = f.read(f.tell() - pos if pos == 0 else 256) + buf
                lines = buf.split(b"\n")
                # Find last non-empty line
                for line in reversed(lines):
                    if line.strip():
                        last = json.loads(line)
                        if (last.get("event") == entry.get("event") and
                            last.get("repo") == entry.get("repo") and
                            last.get("commit_hash") == entry.get("commit_hash")):
                            last_ts = datetime.strptime(last["timestamp"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
                            entry_ts = datetime.strptime(entry["timestamp"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
                            return abs((entry_ts - last_ts).total_seconds()) < DEDUP_WINDOW_SECS
                        return False
                break
    except Exception:
        pass
    return False

def log_entry(entry):
    DIR.mkdir(parents=True, exist_ok=True)
    if is_duplicate(entry):
        return
    with open(LOG, "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            f.write(json.dumps(entry) + "\n")
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)

def handle_claude_code():
    """Claude Code PostToolUse mode — reads JSON from stdin."""
    data = json.loads(sys.stdin.read())
    cmd = data.get("tool_input", {}).get("command", "")
    event = None
    for name, pat in TRACKED.items():
        if pat.search(cmd):
            event = name; break
    if not event: return

    out = data.get("tool_output", {})
    combined = f"{out.get('stdout', '')}\n{out.get('stderr', '')}"
    cwd = data.get("session_cwd", data.get("cwd", ""))
    repo = os.path.basename(cwd) if cwd else "unknown"

    if is_ignored(repo): return

    info = parse_git_output(combined, event, cmd)
    log_entry({
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "event": event, "repo": repo, "branch": info["branch"],
        "client": get_client(repo), "commit_hash": info["commit_hash"],
        "commit_message": info["commit_message"], "files_changed": info["files_changed"],
        "insertions": info["insertions"], "deletions": info["deletions"],
        "new_branch": info["new_branch"], "command": cmd, "cwd": cwd,
    })

def handle_git_hook():
    """Global git hook mode — called with event type as arg."""
    event = sys.argv[1] if len(sys.argv) > 1 else ""
    if event not in ("commit", "checkout", "merge"): return

    repo = os.path.basename(run(["git", "rev-parse", "--show-toplevel"]) or os.getcwd())
    if is_ignored(repo): return

    branch = run(["git", "rev-parse", "--abbrev-ref", "HEAD"])
    entry = {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "event": event, "repo": repo, "branch": branch,
        "client": get_client(repo),
        "commit_hash": "", "commit_message": "", "files_changed": 0,
        "insertions": 0, "deletions": 0, "new_branch": "", "command": "",
        "cwd": os.getcwd(),
    }

    if event == "commit":
        entry["commit_hash"] = run(["git", "rev-parse", "--short", "HEAD"])
        entry["commit_message"] = run(["git", "log", "-1", "--pretty=%s"])
        count = run(["git", "rev-list", "--count", "HEAD"])
        if count == "1":
            diffstat = run(["git", "diff", "--shortstat", "4b825dc642cb6eb9a060e54bf899d69f82e1764", "HEAD"])
        else:
            diffstat = run(["git", "diff", "--shortstat", "HEAD~1", "HEAD"])
        entry.update(parse_diffstat(diffstat))

    elif event == "checkout":
        entry["new_branch"] = branch

    log_entry(entry)

if __name__ == "__main__":
    try:
        if len(sys.argv) > 1 and sys.argv[1] in ("commit", "checkout", "merge"):
            handle_git_hook()
        else:
            handle_claude_code()
    except Exception:
        pass  # Never block, never fail loudly
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
set -e
MAP="$HOME/.git-timetrack/clients.json"
LOG="$HOME/.git-timetrack/activity.jsonl"
[ ! -f "$MAP" ] && echo '{}' > "$MAP"

case "$1" in
    --list)
        echo ""; jq -r 'to_entries[] | "  \(.key) → \(.value)"' "$MAP" 2>/dev/null || cat "$MAP"; echo "";;
    --auto)
        [ ! -f "$LOG" ] && echo "No activity yet. Make some commits first!" && exit 0
        echo ""
        while IFS= read -r repo; do
            existing="$(jq -r --arg r "$repo" '.[$r] // ""' "$MAP" 2>/dev/null)"
            if [ -z "$existing" ]; then
                printf "  %s → which client? " "$repo"; read -r name
                [ -n "$name" ] && tmp=$(mktemp) && { jq --arg r "$repo" --arg c "$name" '. + {($r):$c}' "$MAP" > "$tmp" && mv "$tmp" "$MAP" && echo "  ✓ $repo → $name" || rm -f "$tmp"; }
            else
                echo "  $repo → $existing"
            fi
        done < <(jq -r '.repo' "$LOG" 2>/dev/null | sort -u)
        echo "";;
    ""|--help|-h)
        echo "Usage: map-client <repo> \"Client Name\""
        echo "       map-client --list"
        echo "       map-client --auto";;
    *)
        [ $# -lt 2 ] && echo "Usage: map-client <repo> \"Client Name\"" && exit 1
        tmp=$(mktemp) && { jq --arg r "$1" --arg c "$2" '. + {($r):$c}' "$MAP" > "$tmp" && mv "$tmp" "$MAP" && echo "✓ $1 → $2" || { rm -f "$tmp"; exit 1; }; };;
esac
MAPPER

# ── Weeklog (standalone terminal tool) ───────────────────────

cat > "$DIR/weeklog.sh" << 'WEEKLOG'
#!/usr/bin/env bash
# weeklog — summarize git-timetrack activity
set -e
LOG="$HOME/.git-timetrack/activity.jsonl"
MAP="$HOME/.git-timetrack/clients.json"
FROM="$(python3 -c "from datetime import date,timedelta;d=date.today();print(d - timedelta(days=d.weekday()))")"
TO="$(date +%Y-%m-%d)"; CF=""; DE=false; JO=false

validate_date() {
    if ! echo "$1" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
        echo "Error: Invalid date format '$1'. Expected YYYY-MM-DD." >&2; exit 1
    fi
    if ! python3 -c "from datetime import datetime; datetime.strptime('$1','%Y-%m-%d')" 2>/dev/null; then
        echo "Error: Invalid date '$1'." >&2; exit 1
    fi
}

while [[ $# -gt 0 ]]; do case $1 in
    --from) FROM="$2"; validate_date "$FROM"; shift 2;;
    --to) TO="$2"; validate_date "$TO"; shift 2;;
    --client) CF="$2";shift 2;;
    --draft-emails) DE=true;shift;; --json) JO=true;shift;;
    --help|-h) echo "Usage: weeklog [--from DATE] [--to DATE] [--client NAME] [--json] [--draft-emails]"; exit 0;;
    *) shift;; esac; done
[ ! -f "$LOG" ] && echo "No activity yet. Make some commits first!" && exit 0

exec python3 - "$FROM" "$TO" "$CF" "$DE" "$JO" << 'PY'
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
client_map = json.load(open(map_path)) if os.path.exists(map_path) else {}

# ── Load and parse entries ──────────────────────────────────
all_entries = []
for line in open(log_path):
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
            "command": "python3 \"$HOME/.git-timetrack/hook-handler.py\""
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
        echo '        "command": "python3 \"$HOME/.git-timetrack/hook-handler.py\""'
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
