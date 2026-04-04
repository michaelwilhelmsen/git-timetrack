# git-timetrack

It's Friday. You have no idea what you did this week.

You know you *worked* — you were in the zone, fixing things, shipping things. But now your PM wants a status update, your client needs a time report, and you're staring at a blank email trying to reconstruct five days from memory. So you skim through git logs, guess at hours, and write something that feels vaguely dishonest.

**git-timetrack** fixes this. It silently watches your git activity — commits, branch switches, merges — and logs everything to a local file. No timers to start. No buttons to press. You just code.

Then on Friday, you run one command and get:
- Per-project activity grouped by day
- Time estimates based on commit patterns
- Optionally: client-ready email drafts

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/git-timetrack/main/install.sh | bash
```

Or clone and run:

```bash
git clone https://github.com/YOUR_USER/git-timetrack.git
cd git-timetrack
bash install.sh
```

The installer asks how you want to track:

| Mode | How it works | Best for |
|---|---|---|
| **Claude Code** | PostToolUse hook watches git commands in Claude Code sessions | Claude Code users |
| **Global git hooks** | Sets `core.hooksPath` to intercept git across all repos | Everyone else |

Both modes log to the same file. You can use both at once.

## Usage

### See your week

```bash
# Quick terminal view
weeklog

# Filter by project
weeklog --client acme

# Custom date range
weeklog --from 2025-03-01 --to 2025-03-31

# JSON output (pipe to other tools)
weeklog --json

# Include basic email drafts
weeklog --draft-emails
```

### Smart summaries (Claude Code users)

If you use Claude Code, the `/weeklog` slash command lets Claude read your activity and summarize it conversationally:

```
/weeklog
/weeklog just the acme project
/weeklog in german, professional tone
/weeklog last month
```

Claude translates `fix: MutationObserver feedback loop in cart widget` into `Fixed an issue where the shopping cart wasn't updating correctly` — and writes a complete email draft you can review and send.

You can have a conversation about it: *"Combine those first two bullets."* *"Make it more formal."* *"Skip the infrastructure stuff, the client doesn't care."*

### Map projects to clients

```bash
# Interactive — walks through unmapped repos
map-client --auto

# Direct mapping
map-client my-repo "Acme Corp"

# See current mappings
map-client --list
```

## How time estimation works

The tool doesn't know when you *started* working — only when you committed. So it uses heuristics:

- Commits within **2 hours** of each other → the gap counts as work time
- **Isolated commits** → estimated at 30min–2hr based on diff size
- **Branch switches** → +5 minutes for context-switch overhead

These are **approximations**, not invoiceable truth. The tool flags this clearly. Always review before sharing.

## What gets tracked

| Event | Captured data |
|---|---|
| `git commit` | Message, hash, branch, files changed, insertions/deletions |
| `git checkout` / `git switch` | Previous and new branch |
| `git merge` | Branch |
| `git push` / `git pull` / `git rebase` | Branch, remote |

Everything is stored locally in `~/.git-timetrack/activity.jsonl`. Nothing is sent anywhere. The file is plain JSON Lines — one object per event — so you can grep it, pipe it, or build your own tools on top.

## Data format

```json
{
  "timestamp": "2025-03-28T14:23:01Z",
  "event": "commit",
  "repo": "acme-website",
  "branch": "main",
  "client": "Acme Corp",
  "commit_message": "fix: resolve checkout page crash on mobile",
  "files_changed": 3,
  "insertions": 42,
  "deletions": 7
}
```

## Files installed

| File | Location | Purpose |
|---|---|---|
| Hook handler | `~/.git-timetrack/hook-handler.py` | Silent watcher that logs git events |
| Global git hooks | `~/.git-timetrack/hooks/` | Post-commit/checkout/merge hooks (git mode) |
| weeklog | `~/.local/bin/weeklog` | Terminal summarizer |
| map-client | `~/.local/bin/map-client` | Project → client mapper |
| Slash command | `~/.claude/commands/weeklog.md` | `/weeklog` for Claude Code (optional) |
| Activity log | `~/.git-timetrack/activity.jsonl` | Your data (created on first commit) |
| Client map | `~/.git-timetrack/clients.json` | Project → client name mapping |

## FAQ

**Does this track my time outside of git?**
No. It only sees git commands. Meetings, code review, debugging without committing — invisible. Your actual work time is almost certainly higher than what the tool reports.

**Does this send my data anywhere?**
No. Everything stays in `~/.git-timetrack/` on your machine. The `/weeklog` slash command uses your existing Claude Code session — no separate API calls.

**Can I use this with a team?**
Each person installs it locally. There's no shared server. If you want to aggregate, you could collect the JSON files, but that's a build-your-own situation for now.

**Will this slow down my commits?**
The hook runs in the background (`&`) and typically finishes in <50ms. You won't notice it.

**What about repos I don't want tracked?**
The git hooks mode tracks all repos. You can add a `~/.git-timetrack/ignore` file (one repo name per line) — the handler respects it. (Claude Code mode only tracks what Claude does, so it's naturally scoped.)

**How do I uninstall?**
```bash
bash install.sh --uninstall
```

## Contributing

Issues and PRs welcome. The codebase is intentionally small — the core handler is ~60 lines of Python, the weeklog is a single bash/python script. Keep it simple.

## License

MIT
