#!/usr/bin/env python3
"""
git-timetrack → Finago Busy.

Pushes billable entries to Busy's public API as hour entries.

  busy-push.py lookup                 print projects, tags, tasks and users
  busy-push.py push entries.json      show what would be written (default)
  busy-push.py push entries.json --commit
  busy-push.py undo entries.json --commit     delete what it wrote

Two guards: lines that meet end-to-end on the same project, task and tag are
written as one entry with both descriptions, and a line covering hours already
logged in Busy — by hand, or by an earlier push under another key — stops the
run unless --force.

The entries file is written by the timelog skill: the reader supplies the
clock, the skill supplies the client-facing description. Each entry carries a
`key` that becomes the hour entry's externalId, so a re-run updates the entry
it wrote before instead of adding a second one.

Auth: an API token from Busy's workspace settings → integrations, in
~/.git-timetrack/busy-token (or $BUSY_TOKEN). Scopes needed: hourEntries:read,
hourEntries:write, projects:read, tags:read, tasks:read, users:read.
"""

import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

DIR     = Path.home() / ".git-timetrack"
TOKEN   = DIR / "busy-token"
CONFIG  = DIR / "busy.json"

PROD    = "https://api.busy.no"
DEMO    = "https://api.demo.busy.no"

PAGE    = 100
TIMEOUT = 30

# ── API ─────────────────────────────────────────────────────

def load_token():
    import os
    token = os.environ.get("BUSY_TOKEN", "").strip()
    if token:
        return token
    if not TOKEN.exists():
        sys.exit(f"No API token. Put one in {TOKEN} or set $BUSY_TOKEN.")
    for line in TOKEN.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            return line
    sys.exit(f"{TOKEN} holds no token — add it on a line of its own.")


class Busy:
    def __init__(self, token, base=PROD):
        self.token = token
        self.base = base.rstrip("/")

    def request(self, method, path, params=None, body=None):
        url = f"{self.base}{path}"
        if params:
            pairs = []
            for key, value in params.items():
                for item in (value if isinstance(value, (list, tuple)) else [value]):
                    if item is not None:
                        pairs.append((key, item))
            url += "?" + urllib.parse.urlencode(pairs)

        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/json",
            **({"Content-Type": "application/json"} if data else {}),
        })
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
                raw = response.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as error:
            detail = error.read().decode(errors="replace")[:800]
            if error.code == 401:
                sys.exit("401 from Busy — the token is missing, wrong or expired.")
            if error.code == 403:
                sys.exit(f"403 from Busy — the token lacks a scope for {method} {path}.\n{detail}")
            if error.code == 429:
                sys.exit("429 from Busy — rate limited. Wait and re-run; nothing partial is left behind "
                         "because entries are keyed by externalId.")
            sys.exit(f"{error.code} from Busy on {method} {path}:\n{detail}")
        except urllib.error.URLError as error:
            sys.exit(f"Could not reach {self.base}: {error.reason}")

    def get_all(self, path, params=None):
        """Every page of a list endpoint."""
        items, offset = [], 0
        while True:
            page = self.request("GET", path, {**(params or {}), "limit": PAGE, "offset": offset})
            batch = page.get("data", page) if isinstance(page, dict) else page
            if not batch:
                return items
            items.extend(batch)
            if len(batch) < PAGE:
                return items
            offset += PAGE

# ── Lookup ──────────────────────────────────────────────────

def lookup(api):
    users = api.get_all("/v2/users/", {"isActive": "true"})
    print(f"USERS ({len(users)})")
    for user in users:
        print(f"  {user['id']}  {user.get('displayName') or ''}  {user.get('email') or ''}")

    tags = api.get_all("/v2/tags/", {"isActive": "true"})
    print(f"\nTAGS ({len(tags)})")
    for tag in tags:
        print(f"  {tag['id']}  [{tag.get('type')}]  {tag.get('name')}")

    clients = {c["id"]: c.get("name") for c in api.get_all("/v2/clients/", {"isActive": "true"})}
    projects = api.get_all("/v2/projects/", {"isActive": "true"})
    print(f"\nPROJECTS ({len(projects)})")
    for project in sorted(projects, key=lambda p: (clients.get(p.get("clientId")) or "", p.get("name") or "")):
        flags = []
        if project.get("isTaskBased"):
            flags.append("task-based")
        if not project.get("isBillable"):
            flags.append("non-billable")
        if not project.get("isOpen"):
            flags.append("closed")
        label = f" ({', '.join(flags)})" if flags else ""
        print(f"  {project['id']}  {project.get('name')}"
              f"  — client: {clients.get(project.get('clientId')) or '—'}{label}")
        tasks = [t for t in api.get_all(f"/v2/projects/{project['id']}/tasks", {"isActive": "true"})
                 if t.get("allowTimeTracking")]
        for task in tasks:
            print(f"      task {task['id']}  {task.get('name')}  [{task.get('state')}]")

# ── Push ────────────────────────────────────────────────────

def load_config():
    if not CONFIG.exists():
        sys.exit(f"No client mapping at {CONFIG}. Run `busy-push.py lookup` and write one.")
    config = json.loads(CONFIG.read_text())
    if not config.get("user_id"):
        sys.exit(f"{CONFIG} has no user_id.")
    return config


class Names:
    """Resolves the tag and task names an entry may use instead of ids."""

    def __init__(self, api):
        self.api = api
        self._tags = None
        self._tasks = {}
        self._projects = {}

    def tag(self, name):
        if self._tags is None:
            self._tags = {str(t["id"]): t for t in self.api.get_all("/v2/tags/", {"isActive": "true"})}
        if str(name) in self._tags:
            return str(name), None
        matches = [t for t in self._tags.values() if (t.get("name") or "").lower() == str(name).lower()]
        if len(matches) == 1:
            return str(matches[0]["id"]), None
        if not matches:
            return None, f"no active tag named {name!r}"
        return None, f"tag name {name!r} is ambiguous ({len(matches)} matches) — use the id"

    def task(self, project_id, name):
        if project_id not in self._tasks:
            self._tasks[project_id] = self.api.get_all(
                f"/v2/projects/{project_id}/tasks", {"isActive": "true"})
        tasks = self._tasks[project_id]
        by_id = {str(t["id"]): t for t in tasks}
        task = by_id.get(str(name))
        if task is None:
            matches = [t for t in tasks if (t.get("name") or "").lower() == str(name).lower()]
            if not matches:
                return None, (f"project {project_id} has no active task {name!r} "
                              f"(has: {', '.join(t.get('name') or '' for t in tasks) or 'none'})")
            if len(matches) > 1:
                return None, f"task name {name!r} is ambiguous in project {project_id} — use the id"
            task = matches[0]
        if not task.get("allowTimeTracking"):
            return None, f"task {task.get('name')!r} does not allow time tracking"
        return str(task["id"]), None

    def project(self, project_id):
        if project_id not in self._projects:
            body = self.api.request("GET", f"/v2/projects/{project_id}")
            self._projects[project_id] = body.get("data", body) if isinstance(body, dict) else body
        return self._projects[project_id]


def resolve(entry, config, names):
    """Project from the client mapping; tag and task from the entry, then the mapping."""
    client = entry["client"]
    mapping = (config.get("clients") or {}).get(client)
    if not mapping:
        return None, f"no mapping for client {client!r} in {CONFIG}"
    project = mapping.get("project_id")
    if not project:
        return None, f"mapping for {client!r} has no project_id"

    wanted_tag = entry.get("tag") or entry.get("tag_id") or mapping.get("tag_id") \
        or config.get("default_tag_id")
    if not wanted_tag:
        return None, f"{client!r} has no tag on the entry, the mapping or default_tag_id"
    tag, problem = names.tag(wanted_tag)
    if problem:
        return None, problem

    task = None
    wanted_task = entry.get("task") or entry.get("task_id") or mapping.get("task_id")
    if wanted_task:
        task, problem = names.task(str(project), wanted_task)
        if problem:
            return None, problem
    elif names.project(str(project)).get("isTaskBased"):
        return None, (f"project {project} is task-based, so the entry needs a task — "
                      f"set `task` on it or task_id in the mapping")

    return {"project_id": str(project), "tag_id": tag, "task_id": task,
            "billable": bool(names.project(str(project)).get("isBillable"))}, None


JOIN = " · "


def to_payload(row, config):
    start = row["start"]
    stop = start + timedelta(hours=row["hours"])
    payload = {
        "userId": config["user_id"],
        "projectId": row["target"]["project_id"],
        "tagId": row["target"]["tag_id"],
        "description": JOIN.join(row["descriptions"]),
        "startTime": start.isoformat(timespec="seconds"),
        "stopTime": stop.isoformat(timespec="seconds"),
        "billableMinutes": round(row["hours"] * 60),
        "externalId": row["keys"][0],
    }
    if row["target"]["task_id"]:
        payload["taskId"] = row["target"]["task_id"]
    return payload


CHECKED = ("projectId", "tagId", "taskId", "description",
           "startTime", "stopTime", "billableMinutes")


def differs(existing, payload, billable=True):
    """Fields the server holds differently.

    A non-billable project stores billableMinutes as 0 whatever is sent, so
    comparing it there would report an update on every run."""
    changed = []
    for field in CHECKED:
        if field == "billableMinutes" and not billable and not existing.get(field):
            continue
        want = payload.get(field)
        have = existing.get(field)
        if field in ("startTime", "stopTime") and want and have:
            if datetime.fromisoformat(want) == datetime.fromisoformat(have):
                continue
        if want != have:
            changed.append(field)
    return changed


def plan(entries, config, names):
    """Resolve each line, then join the ones that meet end-to-end.

    Busy shows one card per hour entry, so two lines that touch on the same
    project, task and tag belong in one card with both descriptions. Only
    exactly contiguous lines are joined — anything looser would change the
    billed total, which is the reader's to decide, not this script's."""
    rows, excluded, failed = [], [], []

    for entry in sorted(entries, key=lambda e: (e["date"], e["start"])):
        if entry["client"] in (config.get("exclude") or []):
            excluded.append(entry)
            continue
        target, problem = resolve(entry, config, names)
        if problem:
            failed.append((entry, problem))
            continue
        rows.append({
            "entry": entry,
            "target": target,
            "start": datetime.strptime(f"{entry['date']} {entry['start']}",
                                       "%Y-%m-%d %H:%M").astimezone(),
            "hours": float(entry["hours"]),
            "keys": [entry["key"]],
            "descriptions": [entry["description"]],
        })

    merged = []
    for row in rows:
        joinable = next((m for m in merged
                         if m["target"] == row["target"]
                         and m["start"] + timedelta(hours=m["hours"]) == row["start"]), None)
        if joinable:
            joinable["hours"] += row["hours"]
            joinable["keys"] += row["keys"]
            joinable["descriptions"] += row["descriptions"]
        else:
            merged.append(row)
    return merged, excluded, failed


def clashes_with_existing(api, config, rows):
    """Hours already in Busy for this user covering the same wall-clock time.

    The externalId check only ever finds this script's own entries, so without
    this an hour logged by hand — or by an earlier push under another key —
    is silently doubled."""
    if not rows:
        return {}

    ours = {key for row in rows for key in row["keys"]}
    first = min(row["start"] for row in rows) - timedelta(days=1)
    last = max(row["start"] + timedelta(hours=row["hours"]) for row in rows)

    others = []
    for found in api.get_all("/v2/hourEntries/", {
            "userIdIn": config["user_id"],
            "startTimeFrom": first.isoformat(timespec="seconds"),
            "startTimeTo": last.isoformat(timespec="seconds"),
            "isActive": "true"}):
        if (found.get("externalId") or "") in ours:
            continue
        try:
            # The API answers in UTC; every time this script prints or
            # compares is local, so convert on the way in.
            start = datetime.fromisoformat(found["startTime"]).astimezone()
            stop = datetime.fromisoformat(found["stopTime"]).astimezone()
        except (KeyError, TypeError, ValueError):
            continue
        others.append((start, stop, found))

    found = {}
    for row in rows:
        start = row["start"]
        stop = start + timedelta(hours=row["hours"])
        hits = [other for other in others if other[0] < stop and other[1] > start]
        if hits:
            found[row["keys"][0]] = hits
    return found


def push(api, entries, commit, force=False):
    config = load_config()
    names = Names(api)
    rows, excluded, failed = plan(entries, config, names)

    keys = [key for row in rows for key in row["keys"]]
    existing = {}
    for i in range(0, len(keys), 50):
        for found in api.get_all("/v2/hourEntries/",
                                 {"externalIdIn": keys[i:i + 50], "isActive": "all"}):
            if found.get("externalId"):
                existing[found["externalId"]] = found

    clashes = clashes_with_existing(api, config, rows)

    def label_of(row):
        return (f"{row['start']:%Y-%m-%d %H:%M} {row['hours']:>4.1f}h  "
                f"{row['entry']['client']}")

    for entry in excluded:
        print(f"  EXCLUDE {entry['date']} {entry['start']} {float(entry['hours']):>4.1f}h  "
              f"{entry['client']}  — not tracked in Busy")
    for entry, problem in failed:
        print(f"  SKIP    {entry['date']} {entry['start']} {float(entry['hours']):>4.1f}h  "
              f"{entry['client']}  — {problem}")

    if clashes and not force:
        print()
        for row in rows:
            hits = clashes.get(row["keys"][0])
            if not hits:
                continue
            print(f"  OVERLAP {label_of(row)}  {JOIN.join(row['descriptions'])}")
            for start, stop, other in hits:
                mark = " (invoiced)" if other.get("invoiceId") else ""
                print(f"            already logged {start:%d.%m %H:%M}-{stop:%H:%M}  "
                      f"{other.get('description') or '(no text)'}{mark}")
        print(f"\n{len(clashes)} of {len(rows)} entries cover hours you have already logged. "
              f"Nothing was written.")
        print("Remove those lines from the entries file, or pass --force to write them anyway.")
        return 1

    created = updated = unchanged = removed = 0
    for row in rows:
        label = label_of(row)
        payload = to_payload(row, config)
        if len(row["keys"]) > 1:
            print(f"  JOIN    {label}  — {len(row['keys'])} adjacent lines in one entry")

        current = existing.get(row["keys"][0])
        if current is not None and not current.get("isActive", True):
            # Someone deleted this in Busy on purpose. Bringing it back
            # because the reader still reports the hours would undo their
            # cleanup every time the week is pushed again.
            if not force:
                print(f"  DELETED {label}  — deleted in Busy, left alone")
                unchanged += 1
                continue
            print(f"  REVIVE  {label}  — deleted in Busy, restoring it (--force)")
            if commit:
                api.request("PATCH", f"/v2/hourEntries/{current['id']}",
                            body={**{k: payload[k] for k in CHECKED if k in payload},
                                  "isActive": True})
            updated += 1
        elif current is None:
            print(f"  CREATE  {label}  {payload['description']}")
            if commit:
                api.request("POST", "/v2/hourEntries/", body=payload)
            created += 1
        elif current.get("locked") or current.get("invoiceId"):
            print(f"  LOCKED  {label}  — already locked or invoiced in Busy, leaving it alone")
            unchanged += 1
        else:
            changed = differs(current, payload, row["target"]["billable"])
            if changed:
                print(f"  UPDATE  {label}  — {', '.join(changed)}")
                if commit:
                    api.request("PATCH", f"/v2/hourEntries/{current['id']}",
                                body={k: payload[k] for k in CHECKED if k in payload})
                updated += 1
            else:
                print(f"  OK      {label}")
                unchanged += 1

        # A line that used to stand alone and is now joined leaves its own
        # entry behind; it has to go, or the hours are counted twice.
        for key in row["keys"][1:]:
            stale = existing.get(key)
            if stale is None or not stale.get("isActive", True):
                continue
            if stale.get("locked") or stale.get("invoiceId"):
                print(f"  LOCKED  {label}  — {key} was joined into this entry but is "
                      f"invoiced in Busy; remove it by hand")
                continue
            print(f"  DELETE  {label}  — {key} is now part of this entry")
            if commit:
                api.request("PATCH", f"/v2/hourEntries/{stale['id']}", body={"isActive": False})
            removed += 1

    verb = "wrote" if commit else "would write"
    print(f"\n{verb} {created} new, {updated} updated, {removed} deleted; "
          f"{unchanged} already correct, {len(excluded)} excluded, {len(failed)} skipped")
    if force and clashes:
        print(f"--force: wrote {len(clashes)} entries over hours you had already logged.")
    if not commit and (created or updated or removed):
        print("Add --commit to write these to Busy.")
    return 1 if failed else 0


def undo(api, entries, commit):
    """Mark the entries this tool wrote as deleted in Busy."""
    keys = [e["key"] for e in entries]
    found = {}
    for i in range(0, len(keys), 50):
        for row in api.get_all("/v2/hourEntries/",
                               {"externalIdIn": keys[i:i + 50], "isActive": "all"}):
            if row.get("externalId"):
                found[row["externalId"]] = row

    removed = 0
    for entry in sorted(entries, key=lambda e: (e["date"], e["start"])):
        label = f"{entry['date']} {entry['start']} {float(entry['hours']):>4.1f}h  {entry['client']}"
        row = found.get(entry["key"])
        if row is None:
            print(f"  ABSENT  {label}")
            continue
        if not row.get("isActive", True):
            print(f"  GONE    {label}")
            continue
        if row.get("locked") or row.get("invoiceId"):
            print(f"  LOCKED  {label}  — locked or invoiced, leaving it alone")
            continue
        print(f"  DELETE  {label}")
        if commit:
            api.request("PATCH", f"/v2/hourEntries/{row['id']}", body={"isActive": False})
        removed += 1

    print(f"\n{'deleted' if commit else 'would delete'} {removed}")
    if not commit and removed:
        print("Add --commit to delete these in Busy.")
    return 0


def read_entries(path):
    data = json.loads(Path(path).read_text())
    entries = data.get("entries", data) if isinstance(data, dict) else data
    required = {"key", "client", "date", "start", "hours", "description"}
    for i, entry in enumerate(entries):
        missing = required - set(entry)
        if missing:
            sys.exit(f"entry {i} is missing {', '.join(sorted(missing))}")
        if not str(entry["description"]).strip():
            sys.exit(f"entry {i} ({entry['key']}) has an empty description")
    seen = set()
    for entry in entries:
        if len(entry["key"]) > 50:
            sys.exit(f"key {entry['key']!r} is longer than Busy's 50-character externalId")
        if entry["key"] in seen:
            sys.exit(f"duplicate key {entry['key']} — keys must be unique")
        seen.add(entry["key"])
    return entries

# ── Main ────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--demo", action="store_true",
                        help=f"use the demo environment ({DEMO}) instead of production")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("lookup", help="print projects, tags, tasks and users for the mapping")
    for name, help_text in (("push", "push entries from a JSON file"),
                            ("undo", "delete the entries in a JSON file from Busy")):
        command = sub.add_parser(name, help=help_text)
        command.add_argument("entries", help="path to the entries JSON")
        command.add_argument("--commit", action="store_true",
                             help="actually write to Busy (default is a dry run)")
        if name == "push":
            command.add_argument("--force", action="store_true",
                                 help="write entries that overlap hours already logged")
    args = parser.parse_args()

    api = Busy(load_token(), DEMO if args.demo else PROD)
    if args.command == "lookup":
        lookup(api)
        return 0
    entries = read_entries(args.entries)
    if args.command == "undo":
        return undo(api, entries, args.commit)
    return push(api, entries, args.commit, args.force)


if __name__ == "__main__":
    sys.exit(main())
