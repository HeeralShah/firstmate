#!/usr/bin/env python3
"""fm_dashboard.py - per-session dashboard, state card, and the local decision server.

Everything shown is DERIVED from durable files on each request, never held in
memory: the intake log, data/sessions/<id>/{plan,summary}.md, the session home's
state/*.status lines, and read-only git queries on the session's repos. A refresh
can therefore never disagree with disk, and a restart loses nothing.

  card <id> [--rehydrate]   compact markdown state card (no model). --rehydrate
                            prefixes the session instructions and a rule to trust
                            the card over conversation memory; this is what a
                            Claude Code SessionStart hook (matcher: compact)
                            prints so a compacted chat resumes from facts.
  render <id> [--out FILE]  one static HTML page (read-only snapshot).
  serve [--port N]          127.0.0.1 server: overview, per-session pages, and the
                            decision/note endpoints that write to the intake log.

Contract: docs/session-context.md.
"""
import html
import json
import os
import re
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fm_intake as fi  # noqa: E402  (shares log, sessions, routing)

PROJECTS = os.environ.get("FM_PROJECTS_OVERRIDE") or os.path.join(fi.FM_HOME, "projects")
STEP_MARK = {"x": "accepted", "~": "review", "!": "blocked", " ": "todo"}
CARD_WORDS = 700


# ----------------------------------------------------------------- data layer

def sdir(sid):
    return os.path.join(fi.DATA, "sessions", sid)


def read_text(path, limit=6000):
    try:
        with open(path) as f:
            return f.read(limit)
    except OSError:
        return ""


def plan(sid):
    """Steps from data/sessions/<id>/plan.md: `- [x|~|!| ] text`."""
    steps = []
    for line in read_text(os.path.join(sdir(sid), "plan.md")).splitlines():
        m = re.match(r"^\s*[-*]\s*\[([x~! ])\]\s+(.*\S)\s*$", line, re.I)
        if m:
            steps.append({"state": STEP_MARK[m[1].lower()], "text": m[2]})
    return steps


def session_info(sid):
    for s in fi.sessions():
        if s["id"] == sid:
            return s
    return None


def home_state(sid):
    home, _ = fi.session_home(sid)
    return os.path.join(home or fi.FM_HOME, "state")


def workers(sid):
    """Last status line per task in the session's home, newest first."""
    out, st = [], home_state(sid)
    try:
        names = [n for n in os.listdir(st) if n.endswith(".status")]
    except OSError:
        return out
    for n in names:
        p = os.path.join(st, n)
        last = ""
        for line in read_text(p, 200000).splitlines():
            if line.strip():
                last = line.strip()
        m = re.search(r"\b(needs-decision|working|blocked|paused|done|failed|resolved|fix-review|checks-passed)\b[^:]*:?\s*(.*)$", last)
        out.append({"task": n[:-7], "state": (m[1] if m else "unknown"), "text": (m[2] if m else last)[:300],
                    "age": int(time.time() - os.path.getmtime(p)), "line": last})
    return sorted(out, key=lambda w: w["age"])


def decisions(sid):
    """Open decision keys (needs-decision lines) minus those answered via intake."""
    answered = set()
    for i in fi.derive():
        tri = i["triage"] or {}
        if tri.get("kind") == "decision-answer":
            answered.add(tri.get("ref"))
        else:  # not triaged yet: the captured text itself already names the key
            m = fi.PREFIX_DECISION.match(re.sub(r"^@\S+\s+", "", fi.read_body(i["id"]).strip()))
            if m:
                answered.add(m[1] or m[2])
    out = []
    for w in workers(sid):
        m = re.search(r"needs-decision.*?\[key=([^\]]+)\]\s*:?\s*(.*)", w["line"])
        if m and m[1] not in answered:
            out.append({"key": m[1], "task": w["task"], "text": m[2][:600] or w["text"]})
    return out


def session_items(sid):
    out = []
    for it in fi.derive():
        tri = it["triage"] or {}
        if (tri.get("session") or it.get("forced_session") or "primary") == sid or \
                (sid == "primary" and not tri.get("session")):
            out.append(it)
    return out


def repos_for(sid):
    s = session_info(sid)
    if s and s["repos"] != "*":
        names = [r.strip() for r in s["repos"].split(",") if r.strip()]
    else:
        try:
            names = sorted(n for n in os.listdir(PROJECTS) if os.path.exists(os.path.join(PROJECTS, n, ".git")))
        except OSError:
            names = []
    return names


def git(repo, *args):
    try:
        r = subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True, timeout=20)
        return r.stdout if r.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def code_changes(sid):
    """Read-only: fm/* task branches per repo, commits ahead of the default branch, files by dir."""
    out = []
    for name in repos_for(sid):
        repo = os.path.join(PROJECTS, name)
        base = (git(repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD").strip().split("/", 1) + [""])[-1] \
            or next((b for b in ("main", "master") if git(repo, "rev-parse", "--verify", "-q", b).strip()), "")
        if not base:
            continue
        branches = [b.strip() for b in git(repo, "branch", "--list", "fm/*", "--format=%(refname:short)").splitlines() if b.strip()]
        for b in branches:
            ahead = git(repo, "rev-list", "--count", "%s..%s" % (base, b)).strip() or "0"
            dirs = {}
            for line in git(repo, "diff", "--numstat", "%s...%s" % (base, b)).splitlines():
                parts = line.split("\t")
                if len(parts) == 3:
                    top = parts[2].split("/", 1)[0] if "/" in parts[2] else "(root)"
                    d = dirs.setdefault(top, {"files": 0, "add": 0, "del": 0})
                    d["files"] += 1
                    d["add"] += int(parts[0]) if parts[0].isdigit() else 0
                    d["del"] += int(parts[1]) if parts[1].isdigit() else 0
            head = git(repo, "log", "-1", "--format=%h %s", b).strip()
            out.append({"repo": name, "branch": b, "base": base, "ahead": ahead, "head": head, "dirs": dirs})
    return out


def facts(sid):
    steps = plan(sid)
    counts = {k: sum(1 for s in steps if s["state"] == k) for k in ("accepted", "review", "blocked", "todo")}
    open_items = [i for i in session_items(sid) if i["state"] not in ("acked", "closed")]
    ds = decisions(sid)
    attention = len(ds) + counts["blocked"] + sum(1 for w in workers(sid) if w["state"] in ("blocked", "failed"))
    return {"id": sid, "info": session_info(sid), "steps": steps, "counts": counts, "decisions": ds,
            "workers": workers(sid), "items": session_items(sid), "open_items": open_items,
            "attention": attention, "summary": read_text(os.path.join(sdir(sid), "summary.md")).strip(),
            "changes": code_changes(sid)}


# ----------------------------------------------------------------------- card

def card(sid, rehydrate=False):
    f = facts(sid)
    info = f["info"] or {"kind": "primary", "repos": "*", "summary": "primary home"}
    L = ["# Session %s state card" % sid,
         "Built %s from disk (log, plan, status lines, git). Facts below are authoritative." % fi.now(),
         "Scope: %s; repos: %s." % (info.get("summary"), info.get("repos"))]
    c = f["counts"]
    if f["steps"]:
        L.append("\n## Progress: %d accepted, %d in review, %d blocked, %d todo" % (c["accepted"], c["review"], c["blocked"], c["todo"]))
        for s in f["steps"]:
            if s["state"] != "accepted":
                L.append("- [%s] %s" % (s["state"], s["text"]))
    if f["decisions"]:
        L.append("\n## Open decisions (answer via the dashboard or `D<n>: ...` intake)")
        for d in f["decisions"]:
            L.append("- %s (task %s): %s" % (d["key"], d["task"], d["text"][:200]))
    if f["open_items"]:
        L.append("\n## Open intake messages")
        for i in f["open_items"][-10:]:
            L.append("- %s [%s] %s" % (i["id"], i["state"], i["summary"][:100]))
    if f["workers"]:
        L.append("\n## Workers (latest status)")
        for w in f["workers"][:8]:
            L.append("- %s: %s %s" % (w["task"], w["state"], w["text"][:120]))
    if f["changes"]:
        L.append("\n## Branches")
        for ch in f["changes"][:8]:
            L.append("- %s %s: %s ahead of %s; head %s" % (ch["repo"], ch["branch"], ch["ahead"], ch["base"], ch["head"]))
    if f["summary"]:
        L.append("\n## Captain/agent summary (a claim, written at a checkpoint; facts above win)\n" + f["summary"][:1500])
    text = "\n".join(L)
    words = text.split()
    if len(words) > CARD_WORDS:
        text = " ".join(words[:CARD_WORDS]) + "\n[card truncated: run `fm-dashboard.sh card %s` for the full card]" % sid
    if not rehydrate:
        return text + "\n"
    ins = read_text(os.path.join(fi.DATA, "sessions", sid + ".md"), 8000)
    return ("SESSION CONTEXT, rebuilt from disk after compaction or restart. Trust this over anything remembered "
            "from earlier in the conversation; if they disagree, this is right and the conversation is stale. "
            "Do not act on a remembered fact this card does not confirm; re-check it.\n\n"
            "## Session instructions (task-level, across repos)\n%s\n\n%s\n" % (ins.strip() or "(none)", text))


# ----------------------------------------------------------------------- html

CSS = """
:root{--bg:#fff;--fg:#1b1f24;--mut:#59636e;--line:#d0d7de;--card:#f6f8fa;--ok:#1a7f37;--warn:#9a6700;--bad:#cf222e;--info:#0969da}
@media(prefers-color-scheme:dark){:root{--bg:#0d1117;--fg:#e6edf3;--mut:#8b949e;--line:#30363d;--card:#161b22;--ok:#3fb950;--warn:#d29922;--bad:#f85149;--info:#58a6ff}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,sans-serif}
main{max-width:1100px;margin:0 auto;padding:20px 16px 60px}h1{font-size:24px;margin:0 0 4px}h2{font-size:17px;margin:28px 0 10px}
.mut{color:var(--mut);font-size:13px}.banner{background:var(--bad);color:#fff;padding:8px 16px;display:none}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:10px;margin:14px 0}
.tile{background:var(--card);border:1px solid var(--line);border-left:4px solid var(--line);border-radius:8px;padding:10px 12px}
.tile b{font-size:26px;display:block}.t-bad{border-left-color:var(--bad)}.t-warn{border-left-color:var(--warn)}.t-ok{border-left-color:var(--ok)}.t-info{border-left-color:var(--info)}
.bar{display:flex;height:10px;border-radius:5px;overflow:hidden;background:var(--line);margin:8px 0}.bar i{display:block}
.steps{display:flex;gap:10px;overflow-x:auto;padding-bottom:8px}.step{min-width:170px;max-width:210px;background:var(--card);border:1px solid var(--line);border-top:4px solid var(--line);border-radius:8px;padding:8px 10px;font-size:13px}
.s-accepted{border-top-color:var(--ok)}.s-review{border-top-color:var(--warn)}.s-blocked{border-top-color:var(--bad)}
.pill{display:inline-block;border:1px solid var(--line);border-radius:12px;padding:0 8px;font-size:12px;margin-right:4px}
.p-ok{color:var(--ok);border-color:var(--ok)}.p-warn{color:var(--warn);border-color:var(--warn)}.p-bad{color:var(--bad);border-color:var(--bad)}.p-info{color:var(--info);border-color:var(--info)}
.box{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:12px;margin:8px 0}
.dec{border-left:4px solid var(--warn)}textarea,input[type=text]{width:100%;background:var(--bg);color:var(--fg);border:1px solid var(--line);border-radius:6px;padding:8px;font:inherit}
button{background:var(--info);color:#fff;border:0;border-radius:6px;padding:7px 14px;font:inherit;cursor:pointer;margin:6px 6px 0 0}button.alt{background:var(--card);color:var(--fg);border:1px solid var(--line)}
details summary{cursor:pointer}pre{white-space:pre-wrap;word-break:break-word;margin:6px 0}table{border-collapse:collapse;width:100%}td,th{border-bottom:1px solid var(--line);padding:4px 8px;text-align:left;font-size:13px}
code{background:var(--card);padding:0 4px;border-radius:4px}a{color:var(--info)}
"""

JS = """
const sid=document.body.dataset.sid;
async function post(path,body){const r=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json','X-FM-Dashboard':'1'},body:JSON.stringify(body)});
 const j=await r.json().catch(()=>({}));if(!r.ok)throw new Error(j.error||r.status);return j}
async function decide(key,btn){const box=btn.closest('.dec');const ans=box.querySelector('textarea').value.trim()||btn.dataset.ans||'';
 if(!ans){alert('Write an answer first');return}
 btn.disabled=true;try{const j=await post('/api/decision',{session:sid,key:key,answer:ans});box.innerHTML='<b>Sent '+j.id+'</b> for '+key+'. It is in the log and routed to the session.'}catch(e){alert('Failed: '+e.message);btn.disabled=false}}
async function note(btn){const t=document.getElementById('note').value.trim();if(!t)return;btn.disabled=true;
 try{const j=await post('/api/note',{session:sid,text:t});document.getElementById('note').value='';document.getElementById('noteout').textContent='Queued '+j.id}catch(e){alert('Failed: '+e.message)}btn.disabled=false}
const born=Date.now();
async function refresh(){const a=document.activeElement;if(a&&(a.tagName==='TEXTAREA'||a.tagName==='INPUT'))return;
 try{const r=await fetch(location.href,{cache:'no-store'});if(!r.ok)throw 0;const d=new DOMParser().parseFromString(await r.text(),'text/html');
  document.getElementById('live').innerHTML=d.getElementById('live').innerHTML;document.getElementById('stale').style.display='none'}
 catch(e){document.getElementById('stale').style.display='block'}}
setInterval(refresh,15000);
"""


def e(s):
    return html.escape(str(s), quote=True)


def age(sec):
    return "%ds" % sec if sec < 90 else "%dm" % (sec // 60) if sec < 5400 else "%dh" % (sec // 3600)


def pill(state):
    cls = {"accepted": "ok", "done": "ok", "review": "warn", "blocked": "bad", "failed": "bad",
           "needs-decision": "warn", "working": "info"}.get(state, "")
    return '<span class="pill p-%s">%s</span>' % (cls, e(state)) if cls else '<span class="pill">%s</span>' % e(state)


def page_live(f):
    c = f["counts"]
    total = max(1, len(f["steps"]))
    parts = []
    tiles = [("bad", f["attention"], "need attention"), ("warn", len(f["decisions"]), "decisions for you"),
             ("info", len([w for w in f["workers"] if w["state"] == "working"]), "workers active"),
             ("ok", c["accepted"], "steps accepted"), ("warn", len(f["open_items"]), "open messages")]
    parts.append('<div class="tiles">%s</div>' % "".join(
        '<div class="tile t-%s"><b>%d</b>%s</div>' % (k, n, e(lbl)) for k, n, lbl in tiles))
    parts.append("<h2>Progress</h2>")
    if f["steps"]:
        parts.append('<div class="mut">%d accepted, %d in review, %d blocked, %d to do, of %d steps</div>' % (
            c["accepted"], c["review"], c["blocked"], c["todo"], len(f["steps"])))
        parts.append('<div class="bar">%s</div>' % "".join(
            '<i style="width:%.1f%%;background:var(--%s)"></i>' % (100.0 * c[k] / total, col)
            for k, col in (("accepted", "ok"), ("review", "warn"), ("blocked", "bad"))))
        parts.append('<div class="steps">%s</div>' % "".join(
            '<div class="step s-%s"><span class="mut">%d</span> %s<br>%s</div>' % (s["state"], i + 1, e(s["text"]), pill(s["state"]))
            for i, s in enumerate(f["steps"])))
    else:
        parts.append('<div class="mut">No plan yet. Add steps to <code>data/sessions/%s/plan.md</code> as <code>- [ ] step</code> (<code>[~]</code> review, <code>[!]</code> blocked, <code>[x]</code> accepted).</div>' % e(f["id"]))
    parts.append("<h2>Decisions <span class='pill p-warn'>%d need your call</span></h2>" % len(f["decisions"]))
    for d in f["decisions"]:
        parts.append('<div class="box dec"><b>%s</b> <span class="mut">task %s</span><pre>%s</pre>'
                     '<textarea rows="2" placeholder="Your decision (this is sent to the session and logged)"></textarea>'
                     '<button onclick="decide(%s,this)">Send decision</button>'
                     '<button class="alt" data-ans="Approved as proposed" onclick="decide(%s,this)">Approve as proposed</button>'
                     '<button class="alt" data-ans="Rejected; stop this work" onclick="decide(%s,this)">Reject</button></div>' % (
                         e(d["key"]), e(d["task"]), e(d["text"]), e(json.dumps(d["key"])), e(json.dumps(d["key"])), e(json.dumps(d["key"]))))
    if not f["decisions"]:
        parts.append('<div class="mut">Nothing is waiting on you.</div>')
    parts.append("<h2>Session summary</h2>")
    parts.append('<div class="box"><pre>%s</pre></div>' % e(f["summary"] or "(no summary yet: write data/sessions/%s/summary.md at a checkpoint)" % f["id"]))
    parts.append("<h2>Workers</h2>")
    if f["workers"]:
        parts.append("<table><tr><th>Task</th><th>State</th><th>Latest</th><th>Age</th></tr>%s</table>" % "".join(
            "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>" % (e(w["task"]), pill(w["state"]), e(w["text"][:160]), age(w["age"]))
            for w in f["workers"]))
    else:
        parts.append('<div class="mut">No workers recorded for this session.</div>')
    parts.append("<h2>Code changes</h2>")
    if f["changes"]:
        for ch in f["changes"]:
            rows = "".join("<tr><td>%s/</td><td>%d files</td><td style='color:var(--ok)'>+%d</td><td style='color:var(--bad)'>-%d</td></tr>" % (
                e(d), v["files"], v["add"], v["del"]) for d, v in sorted(ch["dirs"].items()))
            parts.append("<details class='box'><summary><b>%s</b> <code>%s</code> %s commits ahead of %s <span class='mut'>%s</span></summary><table>%s</table></details>" % (
                e(ch["repo"]), e(ch["branch"]), e(ch["ahead"]), e(ch["base"]), e(ch["head"]), rows or "<tr><td class='mut'>no file changes</td></tr>"))
    else:
        parts.append('<div class="mut">No <code>fm/*</code> task branches in this session\'s repos.</div>')
    parts.append("<h2>Messages</h2>")
    items = f["items"][-15:][::-1]
    parts.append("<table>%s</table>" % "".join(
        "<tr><td>%s</td><td>%s</td><td>%s</td></tr>" % (e(i["id"]), pill(i["state"]), e(i["summary"][:90])) for i in items)
        if items else "<tr><td class='mut'>None yet.</td></tr>")
    return "".join(parts)


def page(sid):
    f = facts(sid)
    info = f["info"]
    title = (info["summary"] if info else "Primary home")
    return ("<!doctype html><html lang=en><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
            "<title>%s: progress</title><style>%s</style><body data-sid='%s'><div id=stale class=banner>Dashboard cannot reach the server: what you see may be stale.</div><main>"
            "<h1>%s</h1><div class=mut>Session <code>%s</code> · rendered %s · updates every 15 s · <a href='/'>all sessions</a></div>"
            "<div id=live>%s</div>"
            "<h2>Send a note to this session</h2><div class=box><textarea id=note rows=2 placeholder='Fire and forget: it is logged and triaged'></textarea>"
            "<button onclick='note(this)'>Queue it</button> <span id=noteout class=mut></span></div>"
            "</main><script>%s</script></body></html>") % (e(title), CSS, e(sid), e(title), e(sid), fi.now(), page_live(f), JS)


def overview():
    rows = [("primary", "Primary home", "all")] + [(s["id"], s["summary"], s["repos"]) for s in fi.sessions()]
    body = "".join("<div class=box><a href='/s/%s'><b>%s</b></a> <span class=mut>%s</span> %s</div>" % (
        e(sid), e(sid), e(repos), "<span class='pill p-warn'>%d decisions</span>" % len(decisions(sid)) if decisions(sid) else "")
        for sid, _t, repos in rows)
    return "<!doctype html><html lang=en><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><title>Sessions</title><style>%s</style><main><h1>Sessions</h1>%s</main>" % (CSS, body)


# --------------------------------------------------------------------- server

class Handler(BaseHTTPRequestHandler):
    server_version = "fm-dashboard"

    def log_message(self, *a):  # quiet
        pass

    def _send(self, code, body, ctype="text/html; charset=utf-8"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urlparse(self.path).path
        try:
            if path == "/":
                return self._send(200, overview())
            m = re.fullmatch(r"/s/([A-Za-z0-9._-]+)", path)
            if m:
                if m[1] != "primary" and not session_info(m[1]):
                    return self._send(404, "unknown session")
                return self._send(200, page(m[1]))
            if path == "/api/health":
                return self._send(200, json.dumps({"ok": True, "at": fi.now()}), "application/json")
        except Exception as exc:  # noqa: BLE001 - show the failure on the page, never a blank one
            return self._send(500, "<pre>render failed: %s</pre>" % e(exc))
        self._send(404, "not found")

    def _json(self, code, obj):
        self._send(code, json.dumps(obj), "application/json")

    def do_POST(self):
        host = (self.headers.get("Origin") or "").split("//")[-1].split(":")[0]
        if self.headers.get("X-FM-Dashboard") != "1" or (host and host not in ("127.0.0.1", "localhost")):
            return self._json(403, {"error": "forbidden"})
        try:
            n = int(self.headers.get("Content-Length") or 0)
            req = json.loads(self.rfile.read(min(n, 20000)) or b"{}")
        except ValueError:
            return self._json(400, {"error": "bad json"})
        sid = req.get("session") or "primary"
        if sid != "primary" and not session_info(sid):
            return self._json(404, {"error": "unknown session"})
        if self.path == "/api/decision":
            key, ans = str(req.get("key", "")).strip(), str(req.get("answer", "")).strip()
            if not re.fullmatch(r"[A-Za-z0-9_.-]+", key) or not ans:
                return self._json(400, {"error": "key and answer required"})
            text, extra = "answer %s: %s" % (key, ans), "dashboard-decision"
        elif self.path == "/api/note":
            text, extra = str(req.get("text", "")).strip(), "dashboard"
            if not text:
                return self._json(400, {"error": "empty"})
        else:
            return self._json(404, {"error": "no such endpoint"})
        env_args = ["--source", extra, "--session", sid, "-"]
        r = subprocess.run([sys.executable, os.path.join(fi.SELF_DIR, "fm_intake.py"), "add"] + env_args,
                           input=text, capture_output=True, text=True, env=dict(os.environ))
        m = re.search(r"Queued (M-\d+)", r.stdout)
        if r.returncode != 0 or not m:
            return self._json(500, {"error": (r.stderr or r.stdout).strip()[:200]})
        return self._json(200, {"id": m[1]})


def cmd_serve(args):
    port = int(fi.read_setting("dashboard-port", "8787"))
    if "--port" in args:
        port = int(args[args.index("--port") + 1])
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print("dashboard: http://127.0.0.1:%d/  (Ctrl-C to stop)" % port, flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


def cmd_card(args):
    if not args:
        fi.die("usage: fm-dashboard.sh card <session|primary> [--rehydrate]")
    sys.stdout.write(card(args[0], "--rehydrate" in args))
    return 0


def cmd_render(args):
    if not args:
        fi.die("usage: fm-dashboard.sh render <session|primary> [--out FILE]")
    out = args[args.index("--out") + 1] if "--out" in args else None
    doc = page(args[0])
    if out:
        tmp = out + ".tmp"
        with open(tmp, "w") as f:
            f.write(doc)
        os.replace(tmp, out)
        print(out)
    else:
        sys.stdout.write(doc)
    return 0


if __name__ == "__main__":
    cmds = {"serve": cmd_serve, "card": cmd_card, "render": cmd_render}
    if len(sys.argv) < 2 or sys.argv[1] not in cmds:
        fi.die("usage: fm-dashboard.sh {serve|card|render} ...")
    sys.exit(cmds[sys.argv[1]](sys.argv[2:]))
