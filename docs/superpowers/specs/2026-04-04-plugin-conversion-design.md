# Git Timetrack — Claude Code Plugin Conversion

## Goal

Convert git-timetrack from a bash installer that generates files across the filesystem into a Claude Code plugin. Remove global git hooks mode entirely. Focus exclusively on Claude Code users.

## Plugin Structure

```
git-timetrack/
├── .claude-plugin/
│   └── plugin.json
├── hooks/
│   └── hooks.json
├── bin/
│   └── hook-handler.py
├── skills/
│   ├── timelog/
│   │   └── SKILL.md
│   └── map-client/
│       └── SKILL.md
├── README.md
├── CLAUDE.md
└── LICENSE
```

## Components

### 1. Plugin Manifest (`.claude-plugin/plugin.json`)

```json
{
  "name": "git-timetrack",
  "version": "1.0.0",
  "description": "Passive time tracking from git activity. Logs commits, checkouts, merges, and generates time reports with client billing summaries.",
  "author": { "name": "Michael Wilhelmsen" },
  "repository": "https://github.com/michaelwilhelmsen/git-timetrack",
  "license": "MIT",
  "keywords": ["git", "time-tracking", "billing", "productivity"]
}
```

### 2. Hook Configuration (`hooks/hooks.json`)

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "if": "Bash(git *)",
            "command": "python3 \"${CLAUDE_PLUGIN_ROOT}/bin/hook-handler.py\"",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

### 3. Hook Handler (`bin/hook-handler.py`)

Extracted from the current `install.sh` HANDLER_PY heredoc with these changes:

**Remove:**
- `handle_git_hook()` function
- `GIT_HOOK_EVENTS` constant
- CLI args dispatch in `__main__`
- All references to git hook mode

**Keep:**
- `handle_claude_code()` as the sole entry point (rename to `main()`)
- `gather_git_state()` — runs git commands to get commit info
- `detect_git_command()` — identifies which git command was run
- `make_entry()` / `log_entry()` — builds and writes JSONL entries
- `is_duplicate()` / `read_last_entry()` — dedup logic
- `parse_diffstat()` — extracts file change stats
- `get_client()` / `is_ignored()` — client lookup and ignore list
- File locking via `fcntl`
- All data paths (`~/.git-timetrack/activity.jsonl`, `clients.json`, `ignore`)

**Add:**
- Auto-create `~/.git-timetrack/` directory, `clients.json`, and `ignore` file on first run if they don't exist

### 4. Timelog Skill (`skills/timelog/SKILL.md`)

Replaces the old `/weeklog` slash command and the terminal `weeklog` script. Claude reads the raw data and summarizes conversationally.

The skill prompt instructs Claude to:
- Read `~/.git-timetrack/activity.jsonl` and `~/.git-timetrack/clients.json`
- Default to "today" if no time range specified (not "this week" — more useful default)
- Support natural language: "today", "this week", "last 3 days", "march", "last month"
- Group by client, then by day
- Estimate hours using the same heuristics (commits <2hrs apart = continuous, isolated = 30min-2hr by diff size, branch switches = +5min)
- Generate client-friendly summaries translating technical commits to business outcomes
- Draft emails when asked
- Respond to follow-up instructions ("make it more formal", "skip the infrastructure stuff")

### 5. Map-Client Skill (`skills/map-client/SKILL.md`)

Replaces the `map-client` CLI. Claude reads `activity.jsonl` to find repos, reads `clients.json` for existing mappings, identifies unmapped repos, and asks the user conversationally to map them. Claude can suggest likely client names based on repo names.

The skill instructs Claude to:
- Read both files
- Show current mappings
- Identify unmapped repos from activity
- Ask the user to map them (or accept suggestions)
- Write updates to `clients.json`

## Data Storage

All data stays at `~/.git-timetrack/`:

| File | Purpose | Created by |
|---|---|---|
| `activity.jsonl` | Append-only event log | hook-handler.py on first git event |
| `clients.json` | Repo-to-client mapping | hook-handler.py (empty `{}`) on first run |
| `ignore` | Repos to exclude | hook-handler.py (with comments) on first run |

## What Gets Deleted

- `install.sh` — replaced by plugin install
- Global git hooks (`post-commit`, `post-checkout`, `post-merge`)
- `weeklog.sh` (terminal CLI) — replaced by timelog skill
- `map-client.sh` (terminal CLI) — replaced by map-client skill
- All installer logic (mode selection, PATH checks, settings.json manipulation, uninstaller)

## Distribution

1. Self-hosted marketplace at `michaelwilhelmsen/claude-plugins` (immediate)
2. Submit to official Anthropic marketplace (later)

Users install with:
```
/plugin marketplace add michaelwilhelmsen/claude-plugins
/plugin install git-timetrack@claude-plugins
```

## Migration for Existing Users

Existing `~/.git-timetrack/activity.jsonl` data is fully compatible — the data format is unchanged. Users just need to:
1. Run `bash install.sh --uninstall` (old version)
2. Install the plugin

The old hook config in `~/.claude/settings.json` should be removed manually or by the uninstaller.
