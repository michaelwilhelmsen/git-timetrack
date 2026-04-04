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
        echo -e "\n  ${YELLOW}Note:${NC} Remove the git-timetrack hook entry from:"
        echo -e "  ${DIM}$CLAUDE_SETTINGS${NC}"
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
import json, sys, os, re, subprocess
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
        except: pass
    return ""

def is_ignored(repo):
    if IGNORE.exists():
        try: return repo in IGNORE.read_text().strip().split("\n")
        except: pass
    return False

def run(cmd):
    try: return subprocess.check_output(cmd, shell=True, stderr=subprocess.DEVNULL, timeout=5).decode().strip()
    except: return ""

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
        for pat, key in [(r'(\d+)\s+files?\s+changed','files_changed'),
                         (r'(\d+)\s+insertions?\(\+\)','insertions'),
                         (r'(\d+)\s+deletions?\(-\)','deletions')]:
            m3 = re.search(pat, out)
            if m3: info[key] = int(m3.group(1))
    elif event == "checkout":
        m = re.search(r"Switched to (?:a new )?branch '([^']+)'", out)
        if m: info["new_branch"] = info["branch"] = m.group(1)
    return info

def log_entry(entry):
    DIR.mkdir(parents=True, exist_ok=True)
    with open(LOG, "a") as f:
        f.write(json.dumps(entry) + "\n")

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

    repo = os.path.basename(run("git rev-parse --show-toplevel") or os.getcwd())
    if is_ignored(repo): return

    branch = run("git rev-parse --abbrev-ref HEAD")
    entry = {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "event": event, "repo": repo, "branch": branch,
        "client": get_client(repo),
        "commit_hash": "", "commit_message": "", "files_changed": 0,
        "insertions": 0, "deletions": 0, "new_branch": "", "command": "",
        "cwd": os.getcwd(),
    }

    if event == "commit":
        entry["commit_hash"] = run("git rev-parse --short HEAD")
        entry["commit_message"] = run("git log -1 --pretty=%s")
        diffstat = run("git diff --shortstat HEAD~1 HEAD")
        for pat, key in [(r'(\d+)\s+files?\s+changed','files_changed'),
                         (r'(\d+)\s+insertions?\(\+\)','insertions'),
                         (r'(\d+)\s+deletions?\(-\)','deletions')]:
            m = re.search(pat, diffstat)
            if m: entry[key] = int(m.group(1))

    elif event == "checkout":
        entry["new_branch"] = branch
        prev = sys.argv[2] if len(sys.argv) > 2 else ""
        if prev and len(prev) < 60:
            entry["branch"] = prev

    log_entry(entry)

if __name__ == "__main__":
    try:
        if len(sys.argv) > 1 and sys.argv[1] in ("commit", "checkout", "merge"):
            handle_git_hook()
        else:
            handle_claude_code()
    except:
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
                [ -n "$name" ] && tmp=$(mktemp) && jq --arg r "$repo" --arg c "$name" '. + {($r):$c}' "$MAP" > "$tmp" && mv "$tmp" "$MAP" && echo "  ✓ $repo → $name"
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
        tmp=$(mktemp) && jq --arg r "$1" --arg c "$2" '. + {($r):$c}' "$MAP" > "$tmp" && mv "$tmp" "$MAP"
        echo "✓ $1 → $2";;
esac
MAPPER

# ── Weeklog (standalone terminal tool) ───────────────────────

cat > "$DIR/weeklog.sh" << 'WEEKLOG'
#!/usr/bin/env bash
# weeklog — summarize git-timetrack activity
set -e
LOG="$HOME/.git-timetrack/activity.jsonl"
MAP="$HOME/.git-timetrack/clients.json"
FROM="$(date -d 'last monday' +%Y-%m-%d 2>/dev/null || date -v-monday +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)"
TO="$(date +%Y-%m-%d)"; CF=""; DE=false; JO=false
while [[ $# -gt 0 ]]; do case $1 in
    --from) FROM="$2";shift 2;; --to) TO="$2";shift 2;; --client) CF="$2";shift 2;;
    --draft-emails) DE=true;shift;; --json) JO=true;shift;;
    --help|-h) echo "Usage: weeklog [--from DATE] [--to DATE] [--client NAME] [--json] [--draft-emails]"; exit 0;;
    *) shift;; esac; done
[ ! -f "$LOG" ] && echo "No activity yet. Make some commits first!" && exit 0

exec python3 - "$FROM" "$TO" "$CF" "$DE" "$JO" << 'PY'
import json,sys,os,re
from datetime import datetime,timedelta
from collections import defaultdict

fd,td,cf,de,jo = sys.argv[1:6]
cf=cf.lower(); de=de=="true"; jo=jo=="true"
lf=os.path.expanduser("~/.git-timetrack/activity.jsonl")
mf=os.path.expanduser("~/.git-timetrack/clients.json")
cm=json.load(open(mf)) if os.path.exists(mf) else {}

entries=[]
for l in open(lf):
    l=l.strip()
    if l:
        try: entries.append(json.loads(l))
        except: pass

fd2=datetime.strptime(fd,"%Y-%m-%d")
td2=datetime.strptime(td,"%Y-%m-%d")+timedelta(days=1)

fl=[]
for e in entries:
    try:
        ts=datetime.strptime(e["timestamp"],"%Y-%m-%dT%H:%M:%SZ")
        if fd2<=ts<td2:
            r=e.get("repo","?"); c=e.get("client","") or cm.get(r,"")
            e["_c"]=c or r; e["_t"]=ts
            if cf and cf not in e["_c"].lower(): continue
            fl.append(e)
    except: pass

if not fl:
    print(f"\nNo activity found for {fd} → {td}")
    if cf: print(f"(filtered: {cf})")
    sys.exit(0)

bc=defaultdict(list)
for e in sorted(fl, key=lambda x:x["_t"]):
    bc[e["_c"]].append(e)

def est(ev):
    co=[e for e in ev if e["event"]=="commit"]
    if not co: return 0.0
    if len(co)==1:
        lines=co[0].get("insertions",0)+co[0].get("deletions",0)
        return max(0.5,min(2.0,lines/50))
    m=30
    for i in range(1,len(co)):
        g=(co[i]["_t"]-co[i-1]["_t"]).total_seconds()/60
        m+=g if g<=120 else 30
    m+=len([e for e in ev if e["event"]=="checkout"])*5
    return round(m/60,1)

def clean(msg):
    lb={"fix":"Fixed","feat":"Added","chore":"Updated","refactor":"Improved",
        "docs":"Docs","perf":"Optimized","ci":"CI/CD","style":"Styled","test":"Tests"}
    mx=re.match(r'^(fix|feat|chore|refactor|docs|style|test|perf|ci)(\(.+?\))?:\s*',msg)
    if mx:
        p=lb.get(mx.group(1),"Updated"); b=msg[mx.end():]
        b=b[0].upper()+b[1:] if b else b; return f"{p}: {b}"
    return msg

if jo:
    r={}
    for cl,ev in sorted(bc.items()):
        co=[e for e in ev if e["event"]=="commit"]
        br=sorted(set(e.get("branch","") for e in ev if e.get("branch","") and len(e.get("branch",""))<60))
        r[cl]={"estimated_hours":est(ev),"branches":br,
               "commits":[{"timestamp":e["timestamp"],"message":e.get("commit_message",""),
                           "branch":e.get("branch",""),"files_changed":e.get("files_changed",0),
                           "insertions":e.get("insertions",0),"deletions":e.get("deletions",0)}
                          for e in co],
               "context_switches":len([e for e in ev if e["event"]=="checkout"])}
    print(json.dumps(r,indent=2)); sys.exit(0)

B="\033[1m";D="\033[2m";G="\033[0;32m";C="\033[0;36m";N="\033[0m"
th=0
print(f"\n{B}═══ Week Log: {fd} → {td} ═══{N}\n")
for cl,ev in sorted(bc.items()):
    h=est(ev); th+=h; co=[e for e in ev if e["event"]=="commit"]
    print(f"{B}{cl}{N}  {D}(~{h} hrs){N}\n")
    bd=defaultdict(list)
    for c in co: bd[c["_t"].strftime("%a %d %b")].append(c)
    for d,dc in bd.items():
        print(f"  {C}{d}{N}")
        for c in dc:
            m=c.get("commit_message","?"); f=c.get("files_changed",0)
            a=c.get("insertions",0); dl=c.get("deletions",0)
            s=f"  {D}+{a}/-{dl} ({f} files){N}" if f else ""
            print(f"    • {m}{s}")
        print()
    br=sorted(set(e.get("branch","") for e in ev if e.get("branch","") and len(e.get("branch",""))<60))
    if br: print(f"  {D}Branches: {', '.join(br)}{N}\n")
    if de and co:
        print(f"  {G}📧 Draft email:{N}\n  {D}{'─'*40}{N}")
        print(f"  Subject: Weekly update — {cl}\n\n  Hi,\n\n  Here's what we worked on this week:\n")
        for c in co:
            m=c.get("commit_message","")
            if m: print(f"    • {clean(m)}")
        print(f"\n  Estimated time: ~{h} hours\n\n  Let me know if you have any questions.")
        print(f"  {D}{'─'*40}{N}\n")
    print(f"  {'─'*40}\n")
print(f"{B}Total: ~{th} hrs{N}")
um=set(e.get("repo","") for e in fl)-set(cm.keys())
if um: print(f"\n{D}💡 Unmapped repos: {', '.join(um)} → run: map-client --auto{N}")
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
