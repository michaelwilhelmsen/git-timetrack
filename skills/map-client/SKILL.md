---
name: map-client
description: "Map git repos to client names for time tracking reports. Use when the user wants to set up client mappings, has unmapped repos, or mentions map-client."
---

# Map Client — Manage repo-to-client mappings

Read `~/.git-timetrack/clients.json` and `~/.git-timetrack/activity.jsonl`.

## Task

1. Read the current client mappings from `clients.json`
2. Read `activity.jsonl` to find all unique repo names that have been tracked
3. Identify repos with no client mapping
4. Present the current state: show existing mappings and list unmapped repos
5. For unmapped repos, suggest likely client names based on the repo name and ask the user to confirm or provide the correct name
6. Write the updated mappings to `clients.json`

## Rules

- Show existing mappings first so the user has context
- For each unmapped repo, suggest a client name if the repo name hints at one (e.g. "acme-website" → "Acme")
- Accept user corrections and preferences without pushback
- If `$ARGUMENTS` is a direct mapping (e.g. "my-repo Acme Corp"), just apply it without the interactive flow
- Preserve existing mappings — only add or update, never remove unless explicitly asked
- Write valid JSON to `clients.json` with proper formatting

## Edge cases

- No activity log yet → explain that tracking starts automatically with git commands in Claude Code
- All repos already mapped → confirm everything is mapped, show the list
- Empty `$ARGUMENTS` → run the interactive flow
