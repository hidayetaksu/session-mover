#!/usr/bin/env python3
"""Phase 0 spike: full move of one Claude Code sidebar session between Claude
copies and/or accounts, with backup, journal and undo.

Run through move.sh. Only touches copies listed in SM_ALLOW (default: test1,test2).

  move.sh move  <session> --from <copy> --to <copy> [--to-account UUID] [--to-org UUID] [--no-reopen]
  move.sh undo  <move id>
  move.sh list  <copy>

<copy> is a Claude Profiles slug, or "default" for /Applications/Claude.app.
<session> is local_<id> (or the bare id).
"""
import argparse
import datetime
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time
import uuid

HOME = os.path.expanduser("~")
STATE_DIR = os.path.join(HOME, "Library/Application Support/SessionMoverSpike")
ALLOW = [s for s in os.environ.get("SM_ALLOW", "test1,test2").split(",") if s]
SESSIONS_DIR = os.path.join(HOME, ".claude/sessions")


class Block(Exception):
    pass


def log(msg):
    print(f"[sm] {msg}", flush=True)


# ---------- copies ----------

def copy_info(slug):
    if slug not in ALLOW:
        raise Block(f"copy '{slug}' is not in SM_ALLOW ({','.join(ALLOW)}); refusing to touch it")
    if slug == "default":
        data = os.path.join(HOME, "Library/Application Support/Claude")
        bundle = "com.anthropic.claudefordesktop"
        app = "/Applications/Claude.app"
    else:
        data = os.path.join(HOME, f".claude-profiles/{slug}/Library/Application Support/Claude")
        bundle = f"com.anthropic.claudefordesktop-{slug}"
        app = f"/Applications/Claude-{slug}.app"
    if not os.path.isdir(data):
        raise Block(f"no data folder for '{slug}': {data}")
    version = subprocess.run(["defaults", "read", f"{app}/Contents/Info.plist", "CFBundleShortVersionString"],
                             capture_output=True, text=True).stdout.strip()
    return {"slug": slug, "data": data, "bundle": bundle, "app": app, "version": version}


def signed_in_account(copy):
    # Pull only lastKnownAccountUuid out of config.json; the rest (token caches) is never parsed or printed.
    with open(os.path.join(copy["data"], "config.json"), "rb") as f:
        m = re.search(rb'"lastKnownAccountUuid"\s*:\s*"([0-9a-f-]{36})"', f.read())
    return m.group(1).decode() if m else None


def app_pid(copy):
    exe = f"{copy['app']}/Contents/MacOS/"
    out = subprocess.run(["pgrep", "-f", exe], capture_output=True, text=True).stdout.split()
    # The launcher execs <Name>.real with --user-data-dir; match the main process only.
    for pid in out:
        cmd = subprocess.run(["ps", "-o", "command=", "-p", pid], capture_output=True, text=True).stdout
        if cmd.startswith(exe) and ".real" in cmd.split(" --")[0]:
            return int(pid)
    return None


def quit_copy(copy, timeout=90):
    if app_pid(copy) is None:
        return False
    log(f"quitting {copy['slug']} ({copy['bundle']})")
    subprocess.run(["osascript", "-e", f'tell application id "{copy["bundle"]}" to quit'], check=False)
    for _ in range(timeout):
        if app_pid(copy) is None:
            return True
        time.sleep(1)
    raise Block(f"{copy['slug']} did not quit within {timeout}s (a dialog may be open)")


def reopen_copy(copy):
    log(f"reopening {copy['slug']}")
    subprocess.run(["open", "-b", copy["bundle"]], check=False)


# ---------- sessions ----------

def norm_id(s):
    return s if s.startswith("local_") else f"local_{s}"


def find_entry(copy, sid):
    hits = glob.glob(os.path.join(copy["data"], "claude-code-sessions", "*", "*", f"{sid}.json"))
    if len(hits) > 1:
        raise Block(f"{sid} exists in more than one account/org folder of {copy['slug']}: {hits}")
    return hits[0] if hits else None


def running_sessions():
    """hostSessionId and cliSessionId of every live Claude Code process."""
    live = {}
    for f in glob.glob(os.path.join(SESSIONS_DIR, "*.json")):
        try:
            j = json.load(open(f))
            os.kill(int(j["pid"]), 0)
        except (OSError, ValueError, KeyError, json.JSONDecodeError):
            continue
        for k in ("hostSessionId", "sessionId"):
            if j.get(k):
                live[j[k]] = j.get("status", "?")
    return live


def read_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def write_json_atomic(path, obj, mode=0o600, indent=None):
    # The temp name must not start with "local_": Claude restores leftover local_*.json.tmp files on load.
    tmp = os.path.join(os.path.dirname(path), f".sm-{uuid.uuid4().hex}.tmp")
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=indent)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, mode)
    os.rename(tmp, path)


IDX = "archived-sessions.idx"


def idx_update(folder, sid, present):
    p = os.path.join(folder, IDX)
    j = read_json(p)
    if j is None:
        return False  # absent: Claude loads without the hint
    ids = set(j.get("archived", []))
    if (sid in ids) == present:
        return False
    ids.add(sid) if present else ids.discard(sid)
    with open(p + ".sm-tmp", "w") as f:
        f.write(json.dumps({"v": 1, "archived": sorted(ids)}, separators=(",", ":")))
    os.chmod(p + ".sm-tmp", 0o600)
    os.rename(p + ".sm-tmp", p)
    return True


def rewrite_entry(entry, same_org):
    e = dict(entry)
    notes = []
    if "cliBinaryPin" in e:
        e.pop("cliBinaryPin")
        notes.append("cleared cliBinaryPin")
    if not same_org and e.get("remoteMcpServersConfig"):
        e["remoteMcpServersConfig"] = None
        notes.append("cleared remoteMcpServersConfig (other organization)")
    err = (e.get("error") or "")
    if err and re.search(r"usage limit|rate limit|limit reached|weekly limit", err, re.I):
        for k in ("error", "errorAt", "errorRows", "errorCategory"):
            e.pop(k, None)
        notes.append("cleared usage-limit error")
    return e, notes


PREFS = "claude_desktop_config.json"
STARRED = "starred-local-code-sessions"
GROUPS = "dframe-group-scopes"


def epitaxy(prefs):
    return prefs.setdefault("preferences", {}).setdefault("epitaxyPrefs", {})


def starred_in(copy, sid):
    # Pins are an account setting synced from the server; this file only caches it, and edits to it are
    # overwritten on launch. Same account: the pin follows the session id. Other account: it is lost.
    return sid in epitaxy(read_json(os.path.join(copy["data"], PREFS), {}) or {}).get(STARRED, [])


def move_group(src_prefs_path, dst_prefs_path, src_scope, dst_scope, sid):
    """Group membership is local per copy, keyed "<account>/<org>"; group names and order sync per account.
    Moves the session's assignment (and the group's definition when the destination scope lacks it)."""
    key = f"code:{sid}"
    sp = read_json(src_prefs_path, {}) or {}
    s = epitaxy(sp).get(GROUPS, {}).get(src_scope, {})
    gid = s.get("assignments", {}).get(key)
    if not gid:
        return None
    same_file = src_prefs_path == dst_prefs_path
    dp = sp if same_file else (read_json(dst_prefs_path, {}) or {})
    d = epitaxy(dp).setdefault(GROUPS, {}).setdefault(dst_scope, {"groups": [], "assignments": {}, "order": {}})
    group = next((g for g in s.get("groups", []) if g.get("id") == gid), None)
    if group and not any(g.get("id") == gid for g in d.setdefault("groups", [])):
        d["groups"].append(group)
    d.setdefault("assignments", {})[key] = gid
    order = d.setdefault("order", {}).setdefault(gid, [])
    if key not in order:
        order.append(key)
    s["assignments"].pop(key, None)
    if gid in s.get("order", {}):
        s["order"][gid] = [k for k in s["order"][gid] if k != key]
    write_json_atomic(dst_prefs_path, dp, indent=2)
    if not same_file:
        write_json_atomic(src_prefs_path, sp, indent=2)
    return group.get("name") if group else gid


def family_of(copy, sid, entry):
    """Sessions in the same copy linked to this one (parent or children)."""
    links = []
    for key in ("forkedFromSessionId",):
        if entry.get(key):
            links.append((key, entry[key]))
    if isinstance(entry.get("spawnedFrom"), dict):
        links.append(("spawnedFrom", entry["spawnedFrom"].get("sessionId")))
    for f in glob.glob(os.path.join(copy["data"], "claude-code-sessions", "*", "*", "local_*.json")):
        try:
            j = json.load(open(f))
        except Exception:
            continue
        if j.get("forkedFromSessionId") == sid or (isinstance(j.get("spawnedFrom"), dict) and j["spawnedFrom"].get("sessionId") == sid):
            links.append(("child", j.get("sessionId")))
    return links


# ---------- move ----------

def cmd_move(a):
    sid = norm_id(a.session)
    src, dst = copy_info(a.src), copy_info(a.dst)
    src_path = find_entry(src, sid)
    if not src_path:
        raise Block(f"{sid} not found in {src['slug']}")
    src_folder = os.path.dirname(src_path)
    src_org = os.path.basename(src_folder)
    src_acct = os.path.basename(os.path.dirname(src_folder))
    entry = read_json(src_path)
    if entry.get("sessionId") != sid:
        raise Block(f"{src_path} has sessionId {entry.get('sessionId')}")

    dst_acct = a.to_account or signed_in_account(dst)
    if not dst_acct:
        raise Block(f"{dst['slug']} has no signed-in account; pass --to-account")
    dst_org = a.to_org
    if not dst_org:
        orgs = [os.path.basename(p) for p in glob.glob(os.path.join(dst["data"], "claude-code-sessions", dst_acct, "*")) if os.path.isdir(p)]
        if src_org in orgs or not orgs:
            dst_org = src_org
        elif len(orgs) == 1:
            dst_org = orgs[0]
        else:
            raise Block(f"{dst['slug']}/{dst_acct} has several organizations {orgs}; pass --to-org")
    dst_folder = os.path.join(dst["data"], "claude-code-sessions", dst_acct, dst_org)
    dst_path = os.path.join(dst_folder, f"{sid}.json")
    same_copy = src["data"] == dst["data"]

    # --- preflight
    warn = []
    if same_copy and src_folder == dst_folder:
        raise Block("destination is the source")
    clash = dst_path if os.path.exists(dst_path) else (None if same_copy else find_entry(dst, sid))
    if clash:
        raise Block(f"{sid} already exists in {dst['slug']}: {clash}")
    live = running_sessions()
    status = live.get(sid) or live.get(entry.get("cliSessionId"))
    if status == "busy":
        raise Block(f"{sid} is busy (a turn is running); wait for it to finish")
    if status:
        warn.append(f"open and {status}: quitting the copy closes it")
    if src["version"] != dst["version"]:
        warn.append(f"versions differ: {src['slug']} {src['version']} vs {dst['slug']} {dst['version']}")
    if not os.path.isdir(entry.get("cwd", "")):
        warn.append(f"working folder is gone: {entry.get('cwd')}")
    src_wt = read_json(os.path.join(src["data"], "git-worktrees.json"), {}) or {}
    dst_wt = read_json(os.path.join(dst["data"], "git-worktrees.json"), {}) or {}
    leases = {k: v for k, v in (src_wt.get("worktrees") or {}).items() if isinstance(v, dict) and v.get("leasedBy") == sid}
    if not same_copy:
        for name in leases:
            other = (dst_wt.get("worktrees") or {}).get(name)
            if other and other.get("leasedBy") not in (None, sid):
                raise Block(f"{dst['slug']} already leases worktree '{name}' to {other.get('leasedBy')}")
    for kind, other in family_of(src, sid, entry):
        warn.append(f"linked session stays behind: {kind} {other}")
    if starred_in(src, sid) and dst_acct != src_acct:
        warn.append("pinned: pins are kept per account, so it arrives unpinned in the other account")
    for w in warn:
        log(f"warning: {w}")
    if a.dry_run:
        log(f"dry run: {src_path} -> {dst_path}; leases {list(leases)}")
        return

    # --- quiesce
    was_running = []
    for c in ([src] if same_copy else [src, dst]):
        if quit_copy(c):
            was_running.append(c["slug"])
    for _ in range(10):
        live = running_sessions()
        if sid not in live and entry.get("cliSessionId") not in live:
            break
        time.sleep(1)
    else:
        for slug in was_running:
            reopen_copy(copy_info(slug))
        raise Block(f"{sid} still has a Claude Code process after quitting (another copy or a terminal?); nothing changed")

    # --- journal and back up
    move_id = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:6]
    bdir = os.path.join(STATE_DIR, "backups", move_id)
    os.makedirs(bdir)
    touched = [src_path, dst_path,
               os.path.join(src["data"], "git-worktrees.json"), os.path.join(dst["data"], "git-worktrees.json"),
               os.path.join(src_folder, IDX), os.path.join(dst_folder, IDX),
               os.path.join(src["data"], PREFS), os.path.join(dst["data"], PREFS)]
    cli = entry.get("cliSessionId", sid[len("local_"):])
    wi_src = sorted(glob.glob(os.path.join(src_folder, "waiting-input", f"{sid}*")) + glob.glob(os.path.join(src_folder, "waiting-input", f"{cli}*")))
    notes_src = os.path.join(src["data"], "side-session-notes", sid)
    files = []
    for p in dict.fromkeys(touched):
        rec = {"path": p, "existed": os.path.exists(p)}
        if rec["existed"]:
            rec["backup"] = os.path.join(bdir, f"{len(files):02d}-{os.path.basename(p)}")
            shutil.copy2(p, rec["backup"])
        files.append(rec)
    journal = {"id": move_id, "state": "started", "session": sid, "from": src["slug"], "to": dst["slug"],
               "src": src_path, "dst": dst_path, "files": files, "moved_dirs": [], "was_running": was_running,
               "versions": {src["slug"]: src["version"], dst["slug"]: dst["version"]}}
    jpath = os.path.join(bdir, "journal.json")
    write_json_atomic(jpath, journal, mode=0o600, indent=1)

    try:
        # --- write destination entry
        new_entry, notes = rewrite_entry(entry, same_org=(src_org == dst_org))
        os.makedirs(dst_folder, mode=0o700, exist_ok=True)
        write_json_atomic(dst_path, new_entry)
        for n in notes:
            log(n)

        # --- worktree lease
        if leases and not same_copy:
            for name in leases:
                src_wt["worktrees"].pop(name)
            dst_wt.setdefault("schemaVersion", src_wt.get("schemaVersion", 2))
            dst_wt.setdefault("worktrees", {}).update(leases)
            write_json_atomic(os.path.join(dst["data"], "git-worktrees.json"), dst_wt, indent="\t")
            write_json_atomic(os.path.join(src["data"], "git-worktrees.json"), src_wt, indent="\t")
            log(f"lease moved: {', '.join(leases)}")

        # --- sidebar group membership
        g = move_group(os.path.join(src["data"], PREFS), os.path.join(dst["data"], PREFS),
                       f"{src_acct}/{src_org}", f"{dst_acct}/{dst_org}", sid)
        if g:
            log(f"group membership moved: {g}")

        # --- archive hints
        if idx_update(src_folder, sid, False):
            log("removed from source archived-sessions.idx")
        if entry.get("isArchived") and idx_update(dst_folder, sid, True):
            log("added to destination archived-sessions.idx")

        # --- per-session side files that Claude deletes when the id is not in that folder
        for p in wi_src:
            q = os.path.join(dst_folder, "waiting-input", os.path.basename(p))
            os.makedirs(os.path.dirname(q), mode=0o700, exist_ok=True)
            shutil.copytree(p, q) if os.path.isdir(p) else shutil.copy2(p, q)
            journal["moved_dirs"].append({"from": p, "to": q})
        if not same_copy and os.path.isdir(notes_src):
            q = os.path.join(dst["data"], "side-session-notes", sid)
            if not os.path.exists(q):
                shutil.copytree(notes_src, q)
                journal["moved_dirs"].append({"from": notes_src, "to": q})

        # --- verify, then remove the source
        if read_json(dst_path) != new_entry:
            raise Block("destination entry did not read back")
        os.remove(src_path)
        for d in journal["moved_dirs"]:
            if d["from"] != notes_src:
                shutil.rmtree(d["from"]) if os.path.isdir(d["from"]) else os.remove(d["from"])
            # side-session notes are copied, not removed: other sessions in the source may still point at them
        journal["state"] = "done"
        write_json_atomic(jpath, journal, mode=0o600, indent=1)
        log(f"moved {sid}: {src['slug']}/{src_acct[:8]}/{src_org[:8]} -> {dst['slug']}/{dst_acct[:8]}/{dst_org[:8]}  (move id {move_id})")
    except Exception as ex:
        log(f"failed ({ex}); rolling back")
        restore(journal)
        journal["state"] = "rolled_back"
        write_json_atomic(jpath, journal, mode=0o600, indent=1)
        raise
    finally:
        if not a.no_reopen:
            for slug in was_running:
                reopen_copy(copy_info(slug))


def restore(journal):
    for rec in journal["files"]:
        if rec["existed"]:
            shutil.copy2(rec["backup"], rec["path"])
        elif os.path.exists(rec["path"]):
            os.remove(rec["path"])
    for d in journal.get("moved_dirs", []):
        if os.path.exists(d["to"]) and not os.path.exists(d["from"]):
            shutil.move(d["to"], d["from"])
        elif os.path.exists(d["to"]):
            shutil.rmtree(d["to"]) if os.path.isdir(d["to"]) else os.remove(d["to"])


def cmd_undo(a):
    jpath = os.path.join(STATE_DIR, "backups", a.move_id, "journal.json")
    j = read_json(jpath)
    if not j:
        raise Block(f"no journal {jpath}")
    copies = [copy_info(j["from"]), copy_info(j["to"])]
    if os.path.exists(j["dst"]):
        cur = read_json(j["dst"])
        if cur.get("lastActivityAt") != read_json(next(r["backup"] for r in j["files"] if r["path"] == j["src"])).get("lastActivityAt"):
            log("warning: the destination entry was used after the move; undo drops those entry changes (history is unaffected)")
    was = [c for c in copies if quit_copy(c)]
    restore(j)
    j["state"] = "undone"
    write_json_atomic(jpath, j, mode=0o600, indent=1)
    log(f"undid {a.move_id}")
    for c in was:
        reopen_copy(c)


def cmd_list(a):
    c = copy_info(a.copy)
    live = running_sessions()
    for p in sorted(glob.glob(os.path.join(c["data"], "claude-code-sessions", "*", "*", "local_*.json"))):
        j = read_json(p)
        acct, org = p.split("/")[-3], p.split("/")[-2]
        flags = "".join(["A" if j.get("isArchived") else "-", "*" if j.get("isStarred") else "-",
                         "W" if j.get("worktreePath") else "-", "R" if j.get("sessionId") in live else "-"])
        print(f"{acct[:8]}/{org[:8]} {flags} {j.get('sessionId')}  {j.get('title')!r}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("move")
    m.add_argument("session")
    m.add_argument("--from", dest="src", required=True)
    m.add_argument("--to", dest="dst", required=True)
    m.add_argument("--to-account")
    m.add_argument("--to-org")
    m.add_argument("--no-reopen", action="store_true")
    m.add_argument("--dry-run", action="store_true")
    u = sub.add_parser("undo")
    u.add_argument("move_id")
    l = sub.add_parser("list")
    l.add_argument("copy")
    a = ap.parse_args()
    try:
        {"move": cmd_move, "undo": cmd_undo, "list": cmd_list}[a.cmd](a)
    except Block as b:
        log(f"blocked: {b}")
        sys.exit(2)


if __name__ == "__main__":
    main()
