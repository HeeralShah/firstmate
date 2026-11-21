#!/usr/bin/env python3
"""fm_intake.py - fire-and-forget intake: capture, triage, route, and a durable log.

Owned contract (bin/fm-intake.sh is the thin entry point; docs/intake.md is the
prose). The point of this layer is that the model is never in the capture path:

  capture   plain code. Allocates an id (M-0001...), writes the message body and
            one `captured` event, prints the id. No model, no network.
  triage    a model used as a pure function: a headless call with every tool
            disabled and a required JSON reply. It can classify; it cannot act.
            Deterministic prefixes (`@session`, `D<n>:`) skip the model entirely.
            Any triage failure falls back to the primary home and is recorded,
            never dropped.
  route     delivers into the chosen session's home through that home's own
            `fm-inbox.sh note --request-id <id>`, so a repeat is idempotent.
  log       state/intake/log.jsonl is append-only. State is DERIVED from events
            plus the target home's handled/ directory, never from memory.
  check     the fidelity audit: every captured message must be triaged,
            delivered and acknowledged; anything stuck past its bound is named.

Events (one JSON object per line): captured, triaged, delivered,
delivery_failed, applied, apply_failed, acked, closed. A delivered message
whose note sits in the target home's handled/ directory is derived as acked on
every read, so no reader sees an acknowledged message as open; `sync` also
records that as a durable `acked` event.

Answered decisions are written to the session's decisions.md ONLY after
upstream accepted them (fm-send --resolve-key or fm-captain-hold answers), so
a typo, an unknown key, or a model's guess never becomes a "decision made".
"""
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

SELF_DIR = os.path.dirname(os.path.abspath(__file__))
FM_ROOT = os.path.dirname(SELF_DIR)
FM_HOME = os.environ.get("FM_HOME") or FM_ROOT
STATE = os.environ.get("FM_STATE_OVERRIDE") or os.path.join(FM_HOME, "state")
DATA = os.environ.get("FM_DATA_OVERRIDE") or os.path.join(FM_HOME, "data")
CONFIG = os.environ.get("FM_CONFIG_OVERRIDE") or os.path.join(FM_HOME, "config")
INTAKE = os.path.join(STATE, "intake")
LOG = os.path.join(INTAKE, "log.jsonl")
MSGS = os.path.join(INTAKE, "msgs")
SNAPSHOT = os.path.join(INTAKE, "snapshot.json")
LOCK = os.path.join(INTAKE, ".lock")

KINDS = ("new", "follow-up", "decision-answer", "other")
# Bounds, in seconds, before `check` calls a message stuck.
TRIAGE_BOUND = 120
DELIVER_BOUND = 300
ACK_BOUND = 3600
DEDUPE_WINDOW = 120


def die(msg, code=1):
    sys.stderr.write("fm-intake: %s\n" % msg)
    sys.exit(code)


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def epoch(ts):
    return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()


def read_setting(name, default=""):
    path = os.path.join(CONFIG, name)
    try:
        with open(path) as f:
            for line in f:
                line = line.split("#", 1)[0].strip()
                if line:
                    return line
    except OSError:
        pass
    return default


class Locked:
    """Exclusive lock: the intake log by default, or any named lock file."""

    def __init__(self, path=None):
        self.path = path or LOCK

    def __enter__(self):
        os.makedirs(MSGS, exist_ok=True)
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        self.fh = open(self.path, "a+")
        fcntl.flock(self.fh, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.fh, fcntl.LOCK_UN)
        self.fh.close()


def events():
    out = []
    try:
        with open(LOG) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except ValueError:
                    # A torn line is evidence, not a reason to lose the rest.
                    out.append({"event": "corrupt", "raw": line[:200], "at": now()})
    except OSError:
        pass
    return out


def append_locked(ev):
    ev.setdefault("at", now())
    line = json.dumps(ev, separators=(",", ":"), ensure_ascii=False) + "\n"
    fd = os.open(LOG, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, line.encode())
        os.fsync(fd)
    finally:
        os.close(fd)


def append(ev):
    with Locked():
        append_locked(ev)
    write_snapshot()


def msg_path(mid):
    return os.path.join(MSGS, mid + ".txt")


def read_body(mid):
    try:
        with open(msg_path(mid)) as f:
            return f.read()
    except OSError:
        return ""


def valid_id(mid):
    return bool(re.fullmatch(r"M-\d{4,}", mid or ""))


# ------------------------------------------------------------------ sessions

def sessions():
    """Parse data/sessions.md into [{id, kind, repos, home, summary}]."""
    out = []
    rx = re.compile(
        r"^- ([A-Za-z0-9._-]+) - (.+) \(kind:\s*(theme|chores|all);\s*repos:\s*([^;)]*);"
        r"\s*home:\s*([A-Za-z0-9._-]+);\s*added\s+\d{4}-\d{2}-\d{2}\)\s*$"
    )
    try:
        with open(os.path.join(DATA, "sessions.md")) as f:
            for line in f:
                m = rx.match(line.rstrip("\n"))
                if m:
                    out.append({"id": m[1], "summary": m[2], "kind": m[3],
                                "repos": m[4].strip(), "home": m[5]})
    except OSError:
        pass
    return out


def session_home(sess_id):
    """Return the absolute FM_HOME for a session id, or (None, reason)."""
    if sess_id in ("primary", "", None):
        return FM_HOME, None
    for s in sessions():
        if s["id"] == sess_id:
            if s["home"] == "primary":
                return FM_HOME, None
            return secondmate_home(s["home"])
    return None, "unknown session '%s'" % sess_id


def secondmate_home(sm_id):
    try:
        with open(os.path.join(DATA, "secondmates.md")) as f:
            for line in f:
                m = re.match(r"^- %s - .+ \(home:\s*([^;)]*);" % re.escape(sm_id), line)
                if m:
                    return m[1].strip(), None
                if re.match(r"^- %s - .+ \(host:" % re.escape(sm_id), line):
                    return None, "secondmate '%s' is remote; not wired for intake" % sm_id
    except OSError:
        pass
    return None, "secondmate '%s' is not in data/secondmates.md" % sm_id


# ------------------------------------------------------------------- capture

def cmd_add(args):
    source, session, triage, dedupe = "cli", None, True, None
    while args and args[0].startswith("--") and args[0] != "--":
        a = args.pop(0)
        if a == "--source" and args:
            source = args.pop(0)
        elif a == "--session" and args:
            session = args.pop(0)
        elif a == "--no-triage":
            triage = False
        elif a == "--dedupe-key" and args:
            dedupe = args.pop(0)
        else:
            die("unknown option %s" % a)
    if args and args[0] == "--":
        args.pop(0)
    if args == ["-"]:
        body = sys.stdin.read()
    else:
        body = " ".join(args)
    if not body.strip():
        die("usage: fm-intake.sh add [--session <id>] [--source <s>] [--no-triage] <text>... (or: add -)")
    with Locked():
        evs = events()
        if dedupe:
            # The same prompt reaching two registered hooks (project and user
            # settings) within the window is one message, not two.
            for e in reversed(evs):
                if e.get("event") == "captured" and e.get("dedupe") == dedupe and \
                        time.time() - epoch(e["at"]) < DEDUPE_WINDOW:
                    print("Queued %s" % e["id"])
                    return 0
        ids = [int(e["id"][2:]) for e in evs if e.get("event") == "captured" and valid_id(e.get("id"))]
        mid = "M-%04d" % ((max(ids) if ids else 0) + 1)
        tmp = tempfile.NamedTemporaryFile("w", dir=MSGS, delete=False, prefix=".stage-")
        tmp.write(body if body.endswith("\n") else body + "\n")
        tmp.flush()
        os.fsync(tmp.fileno())
        tmp.close()
        os.replace(tmp.name, msg_path(mid))
        ev = {"event": "captured", "id": mid, "source": source,
              "summary": " ".join(body.split())[:100]}
        if session:
            ev["forced_session"] = session
        if dedupe:
            ev["dedupe"] = dedupe
        append_locked(ev)
    write_snapshot()
    print("Queued %s" % mid)
    if triage and os.environ.get("FM_INTAKE_NO_TRIAGE") != "1":
        spawn_triage(mid)
    return 0


def spawn_triage(mid):
    env = dict(os.environ, FM_INTAKE_TRIAGE="1")
    subprocess.Popen([sys.executable, os.path.abspath(__file__), "triage", mid],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True, env=env)


# -------------------------------------------------------------------- derive

def derive():
    """Fold the log into {id: item}. State is always recomputed, never stored."""
    items = {}
    order = []
    for e in events():
        mid = e.get("id")
        ev = e.get("event")
        if not mid:
            continue
        it = items.get(mid)
        if ev == "captured":
            if it is None:
                order.append(mid)
            items[mid] = {"id": mid, "captured_at": e["at"], "summary": e.get("summary", ""),
                          "source": e.get("source"), "forced_session": e.get("forced_session"),
                          "state": "captured", "triage": None, "delivery": None,
                          "attempts": 0, "history": [(e["at"], "captured")]}
            continue
        if it is None:
            continue
        it["history"].append((e["at"], ev))
        if ev == "triaged":
            it["triage"] = {k: e.get(k) for k in ("kind", "session", "ref", "by", "note")}
            it["state"] = "triaged"
        elif ev == "delivered":
            it["delivery"] = {k: e.get(k) for k in ("session", "home", "note_id")}
            it["state"] = "delivered"
        elif ev == "delivery_failed":
            it["attempts"] += 1
            it["last_error"] = e.get("error")
            it["state"] = "delivery_failed"
        elif ev == "applied":
            it["state"] = "applied"
            it["applied_at"] = e["at"]
        elif ev == "apply_failed":
            it["last_error"] = e.get("error")
        elif ev == "acked":
            it["state"] = "acked"
            it["acked_at"] = e["at"]
        elif ev == "closed":
            it["state"] = "closed"
            it["closed_at"] = e["at"]
    out = [items[m] for m in order]
    for it in out:
        if it["state"] == "delivered" and target_acked(it):
            it["state"] = "acked"
            it["acked_derived"] = True
    return out


SETTLED = ("acked", "closed", "applied")


def last_at(it):
    return epoch(it["history"][-1][0])


def target_acked(it):
    """True if the delivered note sits in the target home's handled/ directory."""
    d = it.get("delivery") or {}
    home, nid = d.get("home"), d.get("note_id")
    if not home or not nid:
        return False
    state = os.path.join(home, "state", "inbox")
    return os.path.exists(os.path.join(state, "handled", nid + ".note"))


def sync():
    """Record a durable `acked` event for messages derived as acked."""
    n = 0
    for it in derive():
        if it.get("acked_derived"):
            append({"event": "acked", "id": it["id"]})
            n += 1
    return n


def write_snapshot():
    """One atomic file a dashboard can render from: every number from one read."""
    try:
        items = derive()
        counts = {}
        for it in items:
            counts[it["state"]] = counts.get(it["state"], 0) + 1
        snap = {"schema": "fm-intake-snapshot.v1", "at": now(), "counts": counts,
                "items": [{k: it.get(k) for k in ("id", "state", "captured_at", "summary",
                                                   "triage", "delivery", "attempts", "last_error")}
                          for it in items]}
        fd, tmp = tempfile.mkstemp(dir=INTAKE, prefix=".snap-")
        with os.fdopen(fd, "w") as f:
            json.dump(snap, f, separators=(",", ":"))
        os.replace(tmp, SNAPSHOT)
    except OSError:
        pass


# -------------------------------------------------------------------- triage

PREFIX_SESSION = re.compile(r"^@([A-Za-z0-9._-]+)\s+(.*)$", re.S)
PREFIX_DECISION = re.compile(r"^(?:answer\s+([A-Za-z0-9_.-]+)|(D-?\d+))\s*:\s+(.*)$", re.S | re.I)


_SNAP_CACHE = {}


def fleet_snapshot(home):
    """Authoritative fleet state from upstream's fm-fleet-snapshot.sh (cached 10 s).

    Current worker state and open decisions come from here, never from a tail of
    state/<id>.status, which upstream documents as a wake-event log."""
    hit = _SNAP_CACHE.get(home)
    if hit and time.time() - hit[0] < 10:
        return hit[1]
    snap = {}
    binary = os.environ.get("FM_SNAPSHOT_BIN") or os.path.join(SELF_DIR, "fm-fleet-snapshot.sh")
    try:
        limit = int(os.environ.get("FM_SNAPSHOT_TIMEOUT") or 60)
    except ValueError:
        limit = 60
    env = {k: v for k, v in os.environ.items() if not k.startswith(("FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_PROJECTS_OVERRIDE"))}
    env["FM_HOME"] = home
    try:
        r = subprocess.run([binary, "--json"], capture_output=True, text=True, timeout=limit, env=env)
        i = r.stdout.find("{")
        snap = json.loads(r.stdout[i:]) if i >= 0 else {}
        if not isinstance(snap, dict) or "tasks" not in snap:
            snap = {"_error": "fleet snapshot returned no task list (exit %d): %s" % (
                r.returncode, (r.stderr.strip() or r.stdout.strip())[:160])}
    except subprocess.TimeoutExpired:
        snap = {"_error": "fleet snapshot timed out after %ds" % limit}
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        snap = {"_error": "fleet snapshot failed: %s" % str(exc)[:160]}
    _SNAP_CACHE[home] = (time.time(), snap)
    return snap


def open_decisions(home):
    """[{key, task, kind, text}] from the snapshot: worker needs-decision keys and captain-held tasks."""
    snap = fleet_snapshot(home)
    out = []
    for t in snap.get("tasks") or []:
        for d in (t.get("hints") or {}).get("open_decisions") or []:
            out.append({"key": d.get("key"), "task": t.get("id"), "kind": "worker",
                        "verb": d.get("verb"), "text": d.get("summary") or "",
                        "project": t.get("project") or ""})
    for r in (snap.get("backlog") or {}).get("records") or []:
        if r.get("captain_actionable"):
            out.append({"key": r.get("id"), "task": r.get("id"), "kind": "hold", "verb": "hold",
                        "text": r.get("hold_reason") or r.get("title") or "",
                        "project": r.get("repo") or ""})
    return [d for d in out if d["key"]]


def apply_decision(home, key, answer, mid):
    """Apply a captain's keyed answer through upstream's own paths; (ok, detail).

    A worker's open decision closes with fm-send --resolve-key (answerer-closes);
    a captain-held backlog task closes through fm-captain-hold.sh answers, the one
    keyed-answer intake. Nothing here invents a resolution record."""
    env = {k: v for k, v in os.environ.items() if not k.startswith(("FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_PROJECTS_OVERRIDE"))}
    env["FM_HOME"] = home
    _SNAP_CACHE.pop(home, None)
    if fleet_snapshot(home).get("_error"):
        return False, fleet_snapshot(home)["_error"]
    match = next((d for d in open_decisions(home) if d["key"] == key), None)
    if match is None:
        return False, "no open decision or captain hold with key '%s'" % key
    if match["kind"] == "worker":
        send = os.environ.get("FM_SEND_BIN") or os.path.join(SELF_DIR, "fm-send.sh")
        r = subprocess.run([send, "fm-%s" % match["task"], "--resolve-key", key, answer],
                           capture_output=True, text=True, env=env)
    else:
        hold = os.environ.get("FM_CAPTAIN_HOLD_BIN") or os.path.join(SELF_DIR, "fm-captain-hold.sh")
        r = subprocess.run([hold, "answers", "--source", "intake:%s" % mid],
                           input="%s\t%s\tintake\n" % (key, answer.replace("\t", " ").replace("\n", " ")),
                           capture_output=True, text=True, env=env)
    _SNAP_CACHE.pop(home, None)
    if r.returncode != 0:
        return False, (r.stderr.strip() or r.stdout.strip() or "exit %d" % r.returncode)[:200]
    return True, match["kind"]


def open_context(exclude=None):
    """Open messages and open decision keys the triage model may refer to."""
    open_items = [{"id": it["id"], "summary": it["summary"],
                   "session": (it["triage"] or {}).get("session")}
                  for it in derive() if it["state"] not in SETTLED and it["id"] != exclude][-15:]
    home, _ = session_home("primary")
    keys = [{"task": d["task"], "key": d["key"]} for d in open_decisions(home or FM_HOME)]
    return open_items, keys[:15]


SCHEMA = {
    "type": "object",
    "properties": {
        "kind": {"type": "string", "enum": list(KINDS)},
        "session": {"type": "string"},
        "ref": {"type": "string"},
        "note": {"type": "string"},
    },
    "required": ["kind", "session"],
    "additionalProperties": False,
}


def model_triage(body, mid=None):
    sess = sessions()
    # The message being triaged is never one of its own "open items".
    open_items, keys = open_context(exclude=mid)
    prompt = (
        "You classify one captain message for a work-routing system. You cannot act, "
        "run tools or answer the message; you only label it.\n"
        "kind: new = a new piece of work; follow-up = adds to or changes an open item "
        "(set ref to that item's id); decision-answer = answers an open decision "
        "(set ref to the decision key); other = a question, chat, or unclear.\n"
        "session: the id of the best session below, or 'primary' if none fits.\n"
        "Reply with JSON only: {\"kind\":..., \"session\":..., \"ref\":\"\", \"note\":\"<=15 words why\"}.\n\n"
        "SESSIONS:\n%s\n\nOPEN ITEMS:\n%s\n\nOPEN DECISIONS:\n%s\n\nMESSAGE:\n%s\n"
        % ("\n".join("- %s (%s; repos %s): %s" % (s["id"], s["kind"], s["repos"], s["summary"]) for s in sess) or "(none)",
           json.dumps(open_items) or "[]", json.dumps(keys) or "[]", body[:4000])
    )
    cmd = ["claude", "-p", "--tools", "", "--disable-slash-commands", "--no-session-persistence",
           "--output-format", "json", "--json-schema", json.dumps(SCHEMA)]
    model = read_setting("intake-triage-model")
    if model:
        cmd += ["--model", model]
    with tempfile.TemporaryDirectory() as cwd:
        r = subprocess.run(cmd, input=prompt, capture_output=True, text=True, timeout=120, cwd=cwd)
    try:
        outer = json.loads(r.stdout)
    except ValueError:
        outer = {}
    if r.returncode != 0 or outer.get("is_error") or outer.get("terminal_reason") == "api_error":
        why = outer.get("terminal_reason") or outer.get("result") or r.stderr.strip()
        raise RuntimeError("claude exit %d: %s" % (r.returncode, str(why)[:160]))
    out = outer.get("structured_output")
    if out is None:
        text = outer.get("result", "")
        m = re.search(r"\{.*\}", text, re.S)
        if not m:
            raise RuntimeError("no JSON in triage reply")
        out = json.loads(m[0])
    return out


def classify(mid):
    """Return (triage dict, error-or-None). Never raises; never returns nothing."""
    body = read_body(mid).strip()
    forced = next((e.get("forced_session") for e in events()
                   if e.get("event") == "captured" and e.get("id") == mid), None)
    valid = {s["id"] for s in sessions()} | {"primary"}
    m = PREFIX_SESSION.match(body)
    if forced or (m and m[1] in valid):
        sid = forced or m[1]
        if sid not in valid:
            return {"kind": "other", "session": "primary", "by": "fallback",
                    "note": "forced session '%s' unknown" % sid}, None
        text = body if forced else m[2]
        d = PREFIX_DECISION.match(text)
        if d:
            return {"kind": "decision-answer", "session": sid, "ref": d[1] or d[2], "by": "rule"}, None
        return {"kind": "new", "session": sid, "by": "rule", "note": "explicit @session"}, None
    d = PREFIX_DECISION.match(body)
    if d:
        return {"kind": "decision-answer", "session": "primary", "ref": d[1] or d[2], "by": "rule"}, None
    if read_setting("intake-triage", "model") == "rules" or not shutil_which("claude"):
        return {"kind": "new", "session": "primary", "by": "fallback",
                "note": "no model triage available"}, None
    try:
        out = model_triage(body, mid)
        kind = out.get("kind")
        sid = out.get("session") or "primary"
        if kind not in KINDS:
            raise RuntimeError("bad kind %r" % kind)
        if (out.get("ref") or "") == mid:
            out["ref"] = None  # a message cannot follow up on itself
        if sid not in valid:
            sid = "primary"
        return {"kind": kind, "session": sid, "ref": out.get("ref") or None,
                "note": (out.get("note") or "")[:120], "by": "model"}, None
    except Exception as exc:  # noqa: BLE001 - triage must degrade, never lose the message
        return {"kind": "new", "session": "primary", "by": "fallback",
                "note": "triage failed: %s" % str(exc)[:100]}, str(exc)


def shutil_which(name):
    for p in os.environ.get("PATH", "").split(os.pathsep):
        f = os.path.join(p, name)
        if os.path.isfile(f) and os.access(f, os.X_OK):
            return f
    return None


def record_decision(mid, sid, key, answer, question, via):
    """Append an ACCEPTED decision to the session's decisions.md (once per message id).

    Called only after upstream accepted the answer. Appends under a lock with
    O_APPEND, so concurrent writers cannot drop a line and a crash cannot
    truncate the file."""
    d = os.path.join(DATA, "sessions", sid)
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, "decisions.md")
    with Locked(os.path.join(d, ".decisions.lock")):
        try:
            with open(path) as f:
                existing = f.read()
        except OSError:
            existing = ""
        if "(%s)" % mid in existing:
            return
        chunk = ""
        if not existing:
            chunk += "# Session %s decisions (appended by script after upstream accepted the answer)\n" % sid
        elif not existing.endswith("\n"):
            chunk += "\n"
        chunk += "- %s %s: %s%s [via %s] (%s)\n" % (now()[:10], key, " ".join(answer.split())[:300],
                                                  (" [asked: %s]" % question[:160]) if question else "", via, mid)
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, chunk.encode())
            os.fsync(fd)
        finally:
            os.close(fd)


def try_apply(it, tri):
    """Auto-apply only an EXPLICIT answer: a rule-matched prefix or a dashboard click.

    A model-triaged decision-answer is a guess, so it is delivered to the first
    mate as a note instead. On any failure the message falls through to delivery,
    so an answer is never lost."""
    if tri.get("kind") != "decision-answer" or not tri.get("ref"):
        return False
    explicit = tri.get("by") == "rule" or it.get("source") == "dashboard-decision"
    if not explicit:
        return False
    home, why = session_home(tri.get("session") or "primary")
    if home is None:
        return False
    body = " ".join(read_body(it["id"]).split())
    body = re.sub(r"^(?:@\S+\s+)?(?:answer\s+\S+|D-?\d+)\s*:\s*", "", body, flags=re.I) or body
    question = next((d["text"] for d in open_decisions(home) if d["key"] == tri["ref"]), "")
    ok, detail = apply_decision(home, tri["ref"], body, it["id"])
    if ok:
        append({"event": "applied", "id": it["id"], "ref": tri["ref"], "via": detail})
        record_decision(it["id"], tri.get("session") or "primary", tri["ref"], body, question,
                        "fm-send --resolve-key" if detail == "worker" else "fm-captain-hold answers")
        return True
    append({"event": "apply_failed", "id": it["id"], "ref": tri["ref"], "error": detail})
    return False


def cmd_triage(args):
    if not args or not valid_id(args[0]):
        die("usage: fm-intake.sh triage M-NNNN")
    mid = args[0]
    # One triage per message at a time: the background triage, `retry` and the
    # dashboard can race, and a decision must never be applied twice.
    with Locked(os.path.join(INTAKE, "triage-locks", mid + ".lock")):
        it = {i["id"]: i for i in derive()}.get(mid)
        if it is None:
            die("no message %s" % mid)
        if it["state"] == "captured":
            tri, _ = classify(mid)
            append(dict(tri, event="triaged", id=mid))
            it = {i["id"]: i for i in derive()}[mid]
            if try_apply(it, tri):
                return 0
        if it["state"] in ("triaged", "delivery_failed"):
            deliver(it)
    return 0


# ------------------------------------------------------------------- deliver

def deliver(it):
    tri = it["triage"] or {"kind": "new", "session": "primary"}
    sid = tri.get("session") or "primary"
    home, why = session_home(sid)
    if home is None:
        append({"event": "delivery_failed", "id": it["id"], "error": why})
        return False
    head = "[intake %s kind=%s session=%s%s]" % (
        it["id"], tri.get("kind"), sid, (" ref=%s" % tri["ref"]) if tri.get("ref") else "")
    ifile = os.path.join(DATA, "sessions", sid, "instructions.md")
    if sid != "primary" and os.path.exists(ifile):
        head += "\nsession-instructions: %s (pass --session %s to fm-brief.sh)" % (ifile, sid)
    body = head + "\n" + read_body(it["id"])
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_PROJECTS_OVERRIDE"))}
    env["FM_HOME"] = home
    r = subprocess.run([os.path.join(SELF_DIR, "fm-inbox.sh"), "note", "--request-id", it["id"], "--json", "-"],
                       input=body, capture_output=True, text=True, env=env)
    saved = None
    try:
        saved = json.loads(r.stdout.strip().splitlines()[-1]) if r.stdout.strip() else None
    except ValueError:
        saved = None
    if saved and saved.get("saved"):
        # exit 3 = saved but wake failed: still durable on disk, so record it as
        # delivered and let `check` surface the missing acknowledgement.
        append({"event": "delivered", "id": it["id"], "session": sid, "home": home,
                "note_id": saved.get("id"), "woken": bool(saved.get("announced"))})
        return True
    append({"event": "delivery_failed", "id": it["id"],
            "error": (r.stderr.strip() or r.stdout.strip() or "fm-inbox exit %d" % r.returncode)[:200]})
    return False


def cmd_retry(args):
    """Re-run triage/delivery for every message that is not in a settled state."""
    n = 0
    for it in derive():
        if it["state"] in ("captured", "triaged", "delivery_failed"):
            cmd_triage([it["id"]])
            n += 1
    print("retried %d message(s)" % n)
    return 0


def cmd_route(args):
    """Manually re-route a message: route M-NNNN <session> (e.g. after a mis-triage)."""
    if len(args) != 2 or not valid_id(args[0]):
        die("usage: fm-intake.sh route M-NNNN <session-id|primary>")
    mid, sid = args
    if sid != "primary" and sid not in {s["id"] for s in sessions()}:
        die("unknown session '%s'" % sid)
    it = {i["id"]: i for i in derive()}.get(mid)
    if it is None:
        die("no message %s" % mid)
    tri = dict(it["triage"] or {"kind": "new"}, session=sid, by="captain")
    with Locked(os.path.join(INTAKE, "triage-locks", mid + ".lock")):
        append(dict(tri, event="triaged", id=mid))
        deliver({i["id"]: i for i in derive()}[mid])
    return 0


def cmd_close(args):
    if not args or not valid_id(args[0]):
        die("usage: fm-intake.sh close M-NNNN [reason...]")
    append({"event": "closed", "id": args[0], "reason": " ".join(args[1:])[:200]})
    print("closed %s" % args[0])
    return 0


# --------------------------------------------------------------------- views

def fmt_item(it):
    tri = it["triage"] or {}
    dest = tri.get("session") or "-"
    return "%-7s %-15s %-12s %s  %s" % (it["id"], it["state"], dest, it["captured_at"], it["summary"][:60])


def cmd_list(args):
    sync()
    show_all = "--all" in args
    as_json = "--json" in args
    items = derive()
    if not show_all:
        items = [i for i in items if i["state"] not in SETTLED]
    if as_json:
        print(json.dumps([{k: i.get(k) for k in ("id", "state", "captured_at", "summary", "triage", "delivery")}
                          for i in items], indent=1))
        return 0
    if not items:
        print("(nothing open)" if not show_all else "(empty log)")
    for it in items:
        print(fmt_item(it))
    return 0


def cmd_show(args):
    if not args or not valid_id(args[0]):
        die("usage: fm-intake.sh show M-NNNN")
    sync()
    it = {i["id"]: i for i in derive()}.get(args[0])
    if it is None:
        die("no message %s" % args[0])
    print("%s  %s" % (it["id"], it["state"]))
    print("triage: %s" % json.dumps(it["triage"]))
    print("delivery: %s" % json.dumps(it["delivery"]))
    for at, ev in it["history"]:
        print("  %s  %s" % (at, ev))
    print("--")
    sys.stdout.write(read_body(it["id"]))
    return 0


def cmd_check(args):
    """Fidelity audit. Exit 0 only if nothing is stuck, lost, or unaccounted for."""
    sync()
    t = time.time()
    problems = []
    corrupt = [e for e in events() if e.get("event") == "corrupt"]
    for e in corrupt:
        problems.append("corrupt log line: %s" % e["raw"])
    items = derive()
    for it in items:
        age = t - last_at(it)
        st = it["state"]
        if not os.path.exists(msg_path(it["id"])):
            problems.append("%s: body file missing (message text lost)" % it["id"])
        if st == "captured" and age > TRIAGE_BOUND:
            problems.append("%s: captured %ds ago, never triaged (run: fm-intake.sh retry)" % (it["id"], age))
        elif st == "triaged" and age > DELIVER_BOUND:
            problems.append("%s: triaged but not delivered (run: fm-intake.sh retry)" % it["id"])
        elif st == "delivery_failed":
            problems.append("%s: delivery failed (%s); run: fm-intake.sh retry" % (it["id"], it.get("last_error")))
        elif st == "delivered" and age > ACK_BOUND:
            d = it["delivery"] or {}
            problems.append("%s: delivered to %s %ds ago, still unacknowledged" % (it["id"], d.get("session"), age))
    counts = {}
    for it in items:
        counts[it["state"]] = counts.get(it["state"], 0) + 1
    print("messages: %d  %s" % (len(items), " ".join("%s=%d" % kv for kv in sorted(counts.items()))))
    if problems:
        for p in problems:
            print("PROBLEM " + p)
        return 1
    print("ok: every captured message is accounted for")
    return 0


def cmd_snapshot(args):
    sync()
    write_snapshot()
    print(SNAPSHOT)
    return 0


COMMANDS = {"add": cmd_add, "triage": cmd_triage, "retry": cmd_retry, "route": cmd_route,
            "close": cmd_close, "list": cmd_list, "show": cmd_show, "check": cmd_check,
            "snapshot": cmd_snapshot}


def main(argv):
    if not argv or argv[0] not in COMMANDS:
        die("usage: fm-intake.sh {add|list|show|check|retry|route|close|snapshot} ...")
    os.makedirs(MSGS, exist_ok=True)
    return COMMANDS[argv[0]](list(argv[1:]))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
