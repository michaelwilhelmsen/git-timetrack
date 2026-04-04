---
name: import
description: "Import past git activity into the time tracking log. Use when the user wants to backfill historical commits, import old work, or just installed the plugin and wants to capture recent activity."
---

# Import — Backfill activity from git history

Import past commits from git repositories into `~/.git-timetrack/activity.jsonl`.

## Task

1. Determine which repos to import from:
   - If `$ARGUMENTS` specifies a path or repo, use that
   - If `$ARGUMENTS` specifies a time range (e.g. "last 2 weeks", "march"), use the current working directory
   - If no arguments, ask the user which repos to import — suggest the current directory and any repos already in `activity.jsonl`
2. Determine the date range:
   - If specified in `$ARGUMENTS`, use that
   - Default: last 2 weeks
3. For each repo, run `git log` to extract commits in the date range:
   ```bash
   git -C <repo-path> log --after="<from-date>" --before="<to-date>" --format="%H|%h|%s|%aI|%D" --shortstat
   ```
4. For each commit, build an activity entry matching the standard format:
   - `timestamp`: from the commit's author date, converted to UTC ISO format
   - `event`: "commit"
   - `repo`: derived from `git remote get-url origin` (fall back to directory name)
   - `branch`: from the ref names in the log, or the branch the commit was on
   - `client`: look up from `~/.git-timetrack/clients.json`
   - `commit_hash`: short hash
   - `commit_message`: subject line
   - `files_changed`, `insertions`, `deletions`: from `--shortstat`
   - `new_branch`: ""
   - `command`: "imported from git log"
   - `cwd`: the repo path
5. Read existing `activity.jsonl` and collect all commit hashes already logged
6. Skip any commits whose hash is already in the log (dedup)
7. Append new entries to `activity.jsonl`, sorted by timestamp
8. Report: how many commits imported, date range covered, which repos

## Rules

- Always show the user what will be imported before writing (repo name, date range, commit count)
- Ask for confirmation before appending to the log
- Never overwrite existing entries — append only, with dedup by commit hash
- Use the git author date (not committer date) for timestamps — it reflects when the work was done
- Detect the repo name from `git remote get-url origin`, same as the hook handler does
- If a repo has no remote, use the directory name
- Handle repos with no commits in range gracefully — just say "no commits found"

## Edge cases

- Repo path doesn't exist or isn't a git repo → say so, ask for the correct path
- No `activity.jsonl` yet → create it (the data directory should already exist from the plugin)
- All commits already imported → report "already up to date, N commits already in log"
- Multiple repos → process them one at a time, report totals at the end
- Merge commits → include them, they represent work integration
