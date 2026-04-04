# Git Timetrack

It's Friday. You have no idea what you did this week.

You know you _worked_ — you were in the zone, fixing things, shipping things. But now your PM wants a status update, your client needs a time report, and you're staring at a blank email trying to reconstruct five days from memory. So you skim through git logs, guess at hours, and write something that feels vaguely dishonest.

**Git Timetrack** fixes this. It silently watches your git activity — commits, branch switches, merges — and logs everything to a local file. No timers to start. No buttons to press. You just code.

Then you ask Claude, and get:

- Per-project activity grouped by day
- Time estimates based on commit patterns
- Client-ready email drafts in any language

## Requirements

- [Claude Code](https://claude.ai/code)
- Python 3.6+

## Install

```
/plugin marketplace add michaelwilhelmsen/git-timetrack
/plugin install git-timetrack@git-timetrack
```

That's it. The plugin hooks into your git commands automatically — no configuration needed.

## Usage

### Time reports

Use `/timelog` to summarize your activity. Claude reads your git history and writes human-friendly reports.

```
/timelog
/timelog today
/timelog this week for acme
/timelog last month, invoice format
/timelog in german, professional tone
```

> You can also use the full name `/git-timetrack:timelog`.

Claude translates `fix: MutationObserver feedback loop in cart widget` into `Fixed an issue where the shopping cart wasn't updating correctly` — and writes a complete email draft you can review and send.

You can have a conversation about it: _"Combine those first two bullets."_ _"Make it more formal."_ _"Skip the infrastructure stuff, the client doesn't care."_

### Map projects to clients

Use `/map-client` to associate repos with client names. Claude walks through your unmapped repos and suggests mappings.

```
/map-client
/map-client my-repo "Acme Corp"
```

> You can also use the full name `/git-timetrack:map-client`.

## How time estimation works

The tool doesn't know when you _started_ working — only when you committed. So it uses heuristics:

- Commits within **2 hours** of each other → the gap counts as work time
- **Isolated commits** → estimated at 30min–2hr based on diff size
- **Branch switches** → +5 minutes for context-switch overhead

These are **approximations**, not invoiceable truth. The tool flags this clearly. Always review before sharing.

## What gets tracked

| Event                                   | Captured data                                              |
| --------------------------------------- | ---------------------------------------------------------- |
| `git commit`                            | Message, hash, branch, files changed, insertions/deletions |
| `git checkout` / `git switch`           | New branch                                                 |
| `git merge`                             | Branch                                                     |
| `git push` / `git pull` / `git rebase`  | Branch                                                     |

Everything is stored locally in `~/.git-timetrack/activity.jsonl`. Nothing is sent anywhere. The file is plain JSON Lines — one object per event — so you can grep it, pipe it, or build your own tools on top.

## Data format

```json
{
  "timestamp": "2025-03-28T14:23:01Z",
  "event": "commit",
  "repo": "acme-website",
  "branch": "main",
  "client": "Acme Corp",
  "commit_hash": "a1b2c3d",
  "commit_message": "fix: resolve checkout page crash on mobile",
  "files_changed": 3,
  "insertions": 42,
  "deletions": 7,
  "new_branch": "",
  "command": "git commit -m '...'",
  "cwd": "/Users/you/projects/acme-website"
}
```

## Data storage

| File         | Location                          | Purpose                                              |
| ------------ | --------------------------------- | ---------------------------------------------------- |
| Activity log | `~/.git-timetrack/activity.jsonl` | Append-only event log (created on first git event)   |
| Client map   | `~/.git-timetrack/clients.json`   | Repo → client name mapping                           |
| Ignore list  | `~/.git-timetrack/ignore`         | Repos to exclude (one name per line)                 |

## FAQ

**Does this track my time outside of git?**
No. It only sees git commands run inside Claude Code sessions. Meetings, code review, debugging without committing — invisible. Your actual work time is almost certainly higher than what the tool reports.

**Does this send my data anywhere?**
No. Everything stays in `~/.git-timetrack/` on your machine.

**What about repos I don't want tracked?**
Add the repo name to `~/.git-timetrack/ignore` (one per line). The handler checks this file before logging.

**How do I uninstall?**
```
/plugin uninstall git-timetrack@git-timetrack
```
Your activity data in `~/.git-timetrack/` is preserved. Delete it manually if you want.

## Contributing

Issues and PRs welcome at [github.com/michaelwilhelmsen/git-timetrack](https://github.com/michaelwilhelmsen/git-timetrack).

## License

MIT
