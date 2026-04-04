---
name: import
description: "Import past git activity into the time tracking log. Use when the user wants to backfill historical commits, import old work, or just installed the plugin and wants to capture recent activity."
---

# Import — Backfill activity from git history

Import past commits from git repositories into `~/.git-timetrack/activity.jsonl`.

## Task

1. Determine which repos to import from:
   - If `$ARGUMENTS` specifies a path or repo, use that
   - Otherwise, find the user's repos by scanning for git directories. Start by asking: **"Where do you keep your projects?"** Suggest common locations (`~/Documents`, `~/Development`, `~/Projects`, `~/Sites`, `~/code`, `~/repos`, `~/work`). Then scan the confirmed paths for git repos (look for `.git` directories, max 2 levels deep to avoid scanning node_modules etc.)
   - Present the discovered repos as a checklist and let the user pick which ones to import
   - Also check `activity.jsonl` for repos already tracked and include their paths if known from the `cwd` field
2. Determine the date range:
   - If specified in `$ARGUMENTS`, use that
   - Default: last 2 weeks
3. Filter to only commits by the current git user. Get the user's identity from `git config user.email` and only import commits matching that email. This prevents importing teammates' commits in shared repos.
4. For each selected repo, run `git log` to extract commits in the date range:
   ```bash
   git -C <repo-path> log --author="<user-email>" --after="<from-date>" --before="<to-date>" --format="%H|%h|%s|%aI|%D" --shortstat
   ```
5. For each commit, build an activity entry matching the standard format:
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
6. Read existing `activity.jsonl` and collect all commit hashes already logged
7. Skip any commits whose hash is already in the log (dedup)
8. Append new entries to `activity.jsonl`, sorted by timestamp
9. Report summary: total commits imported, per-repo breakdown, date range covered
10. If any imported repos are unmapped to clients, mention it and suggest `/map-client`

## Rules

- Always show the user what will be imported before writing (repos, date range, commit counts per repo)
- Ask for confirmation before appending to the log
- Never overwrite existing entries — append only, with dedup by commit hash
- Use the git author date (not committer date) for timestamps — it reflects when the work was done
- Only import the user's own commits (filter by `git config user.email`)
- Detect the repo name from `git remote get-url origin`, same as the hook handler does
- If a repo has no remote, use the directory name
- Handle repos with no commits in range gracefully — just skip them silently

## Edge cases

- Repo path doesn't exist or isn't a git repo → say so, ask for the correct path
- No `activity.jsonl` yet → create it (the data directory should already exist from the plugin)
- All commits already imported → report "already up to date, N commits already in log"
- Multiple repos → process them all, report totals at the end
- Merge commits → include them, they represent work integration
- No git user.email configured → ask the user for their email to filter by
