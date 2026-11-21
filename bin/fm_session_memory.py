#!/usr/bin/env python3
"""fm_session_memory.py - mechanics of a session's durable memory and guide.

The script owns the mechanical parts only: entry markers, dedupe, ageing,
review cadence, and a cold archive. Judgment (what is worth remembering, what to
merge or rewrite) stays with the agent, exactly as in the stow skill.

Entry markers are the stow skill's (.agents/skills/stow/SKILL.md), reused
unchanged; the day horizons match stow's (stale at >= 30 days aging, >= 7
days perishable). The message horizon below is this layer's own addition and
is under review; set it high in the guide to rely on days and size alone.
Entry markers, as trailing HTML comments:
  <!--a:YYYY-MM-DD-->   aging   (last-reinforced date)
  <!--p:YYYY-MM-DD-->   perishable
  <!--P-->              pinned: never ages
  <!--t:NAME-->         pending capture to an external tier: never archived
Staleness follows stow's own pattern of two horizons, "whichever is reached
first", but the second horizon is session ACTIVITY (messages captured for the
session since the entry was last reinforced), not a pass count, because a busy
session outruns any calendar window. The day horizon stays only as a floor for
quiet sessions, where facts rot with time rather than with traffic. Size is a
third trigger: memory over `memory-max-words` is due for review. Stale entries
are MOVED to memory-archive.md, never deleted.
Settings are `key: value` lines above the first `##` heading of the session guide:
  memory-review-every-messages (40)   memory-review-every-days (14)
  memory-stale-after-messages (120)   memory-stale-after-days (30)
  memory-max-words (600)
Perishable entries use a quarter of the message horizon and stow's 7 days.
"""
import os
import re
import sys
from datetime import date, datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fm_intake as fi  # noqa: E402

TODAY = date.today()
MARK = re.compile(r"\s*<!--(a|p):(\d{4}-\d{2}-\d{2})(?:/(\d+))?-->\s*$")
PIN = re.compile(r"\s*<!--P-->\s*$")
PENDING = re.compile(r"<!--t:[^>]+-->")


def sdir(sid):
    return os.path.join(fi.DATA, "sessions", sid)


def path(sid, name):
    return os.path.join(sdir(sid), name)


def need_session(sid):
    if not sid or not os.path.isdir(sdir(sid)):
        fi.die("no session folder for '%s' (create it with fm-sessions.sh add)" % sid)


def read_lines(p):
    try:
        with open(p) as f:
            return f.read().splitlines()
    except OSError:
        return []


def write_lines(p, lines):
    tmp = p + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(lines) + "\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, p)


def locked(sid):
    """One writer at a time per session folder: read-modify-write is never interleaved."""
    return fi.Locked(os.path.join(sdir(sid), ".memory.lock"))


def parse_days(v, default):
    m = re.fullmatch(r"(\d+)\s*([dw]?)", (v or "").strip())
    if not m:
        return default
    return int(m[1]) * (7 if m[2] == "w" else 1)


def guide_setting(sid, key, default):
    for line in read_lines(path(sid, "guide.md")):
        if line.startswith("## "):
            break  # settings sit above the first section heading
        m = re.match(r"^%s:\s*(.+)$" % re.escape(key), line)
        if m:
            return m[1].strip()
    return default


def int_setting(sid, key, default):
    try:
        return int(guide_setting(sid, key, str(default)))
    except ValueError:
        return default


def session_messages(sid):
    """[date] of every intake message captured for this session (log is the record)."""
    out = []
    for it in fi.derive():
        tri = it["triage"] or {}
        if (tri.get("session") or it.get("forced_session") or "primary") == sid:
            out.append(datetime.strptime(it["captured_at"][:10], "%Y-%m-%d").date())
    return out


def memory_words(sid):
    return sum(len(l.split()) for l in read_lines(path(sid, "memory.md")) if l.startswith("- "))


def entries(sid):
    """[(line_index, tier, date|None, text)] for every bullet entry."""
    out = []
    for i, line in enumerate(read_lines(path(sid, "memory.md"))):
        if not line.startswith("- "):
            continue
        if PIN.search(line):
            out.append((i, "pinned", None, PIN.sub("", line[2:])))
            continue
        m = MARK.search(line)
        if m:
            out.append((i, "aging" if m[1] == "a" else "perishable",
                        datetime.strptime(m[2], "%Y-%m-%d").date(), MARK.sub("", line[2:])))
        else:
            out.append((i, "aging", None, line[2:]))  # unmarked: treated as undated
    return out


def stale(sid):
    days_after = int_setting(sid, "memory-stale-after-days", 30)
    msgs_after = int_setting(sid, "memory-stale-after-messages", 120)
    msgs = session_messages(sid)
    lines = read_lines(path(sid, "memory.md"))
    res = []
    for i, tier, d, text in entries(sid):
        if tier == "pinned" or d is None or PENDING.search(lines[i]):
            continue
        quiet_days = 7 if tier == "perishable" else days_after
        quiet_msgs = max(1, msgs_after // 4) if tier == "perishable" else msgs_after
        # Only messages AFTER the entry's day count: a busy morning must not
        # make a fact recorded that afternoon stale. Days match stow (>=).
        since = sum(1 for m in msgs if m > d)
        if (TODAY - d).days >= quiet_days or since >= quiet_msgs:
            res.append((i, tier, d, text))
    return res


def _cmd_add(sid, args):
    need_session(sid)
    pin = "--pin" in args
    perish = "--perishable" in args
    text = " ".join(a for a in args if a not in ("--pin", "--perishable")).strip()
    if not text or "\n" in text:
        fi.die("usage: fm-session-memory.sh add <session> [--pin|--perishable] <one-line text>")
    if any(t.strip() == text for _, _, _, t in entries(sid)):
        print("already remembered (use reinforce to refresh its date)")
        return 0
    mark = "<!--P-->" if pin else "<!--%s:%s-->" % ("p" if perish else "a", TODAY.isoformat())
    lines = read_lines(path(sid, "memory.md"))
    lines.append("- %s %s" % (text, mark))
    write_lines(path(sid, "memory.md"), lines)
    print("remembered (%s)" % ("pinned" if pin else "perishable" if perish else "aging"))
    return 0


def _cmd_reinforce(sid, args):
    need_session(sid)
    needle = " ".join(args).strip().lower()
    if not needle:
        fi.die("usage: fm-session-memory.sh reinforce <session> <substring>")
    lines = read_lines(path(sid, "memory.md"))
    hits = [e for e in entries(sid) if needle in e[3].lower() and e[1] != "pinned"]
    if len(hits) != 1:
        fi.die("%d entries match '%s'; be more specific" % (len(hits), needle))
    i, tier, _, text = hits[0]
    lines[i] = "- %s <!--%s:%s-->" % (text, "p" if tier == "perishable" else "a", TODAY.isoformat())
    write_lines(path(sid, "memory.md"), lines)
    print("reinforced: %s" % text[:80])
    return 0


def cmd_list(sid, args):
    need_session(sid)
    for _, tier, d, text in entries(sid):
        print("%-10s %-10s %s" % (tier, d or "-", text))
    return 0


def last_review(sid):
    """(date, messages-at-review) from the stamp, or (None, 0)."""
    try:
        with open(path(sid, ".last-review")) as f:
            parts = f.read().split()
        return datetime.strptime(parts[0], "%Y-%m-%d").date(), int(parts[1]) if len(parts) > 1 else 0
    except (OSError, ValueError, IndexError):
        return None, 0


def review_status(sid):
    """(due, message): due on activity, size, or (as a floor) calendar time, whichever first."""
    every_msgs = int_setting(sid, "memory-review-every-messages", 40)
    every_days = int_setting(sid, "memory-review-every-days", 14)
    max_words = int_setting(sid, "memory-max-words", 600)
    lr, at_count = last_review(sid)
    total = len(session_messages(sid))
    words = memory_words(sid)
    why = []
    if lr is None:
        why.append("never reviewed")
    else:
        if total - at_count >= every_msgs:
            why.append("%d messages since the last review (limit %d)" % (total - at_count, every_msgs))
        if (TODAY - lr).days >= every_days:
            why.append("%d days since the last review (floor %d)" % ((TODAY - lr).days, every_days))
    if words > max_words:
        why.append("memory is %d words (limit %d)" % (words, max_words))
    if why:
        return True, "; ".join(why)
    return False, "%d messages and %d words since/in the last review (limits %d / %d)" % (total - at_count, words, every_msgs, max_words)


def cmd_review(sid, args):
    need_session(sid)
    due, msg = review_status(sid)
    print("REVIEW DUE: %s" % msg if due else "review not due: %s" % msg)
    st = stale(sid)
    for _, tier, d, text in st:
        print("stale (%s, %s): %s" % (tier, d, text[:100]))
    if due or st:
        print("Run /stow (it covers this session's memory under the same tier rules), reinforce what still holds, "
              "then `fm-session-memory.sh archive-stale %s` for the stale ones and `fm-session-memory.sh reviewed %s`." % (sid, sid))
    return 0 if not due else 0


def cmd_reviewed(sid, args):
    need_session(sid)
    with open(path(sid, ".last-review"), "w") as f:
        f.write("%s %d\n" % (TODAY.isoformat(), len(session_messages(sid))))
    print("review recorded for %s" % TODAY.isoformat())
    return 0


def _cmd_archive_stale(sid, args):
    need_session(sid)
    st = stale(sid)
    if not st:
        print("nothing stale")
        return 0
    lines = read_lines(path(sid, "memory.md"))
    arch = read_lines(path(sid, "memory-archive.md")) or ["# Session %s memory archive (cold; stale entries moved here, never deleted)" % sid]
    drop = set()
    for i, tier, d, text in st:
        arch.append("- %s <!--archived:%s was:%s:%s-->" % (text, TODAY.isoformat(), tier[0], d))
        drop.add(i)
    write_lines(path(sid, "memory-archive.md"), arch)
    write_lines(path(sid, "memory.md"), [l for i, l in enumerate(lines) if i not in drop])
    print("archived %d stale entr%s" % (len(st), "y" if len(st) == 1 else "ies"))
    return 0


def _cmd_guide(sid, args):
    """guide <session> add <one-line rule>: record a dated meta-rule under ## Rules."""
    need_session(sid)
    if not args or args[0] != "add" or len(args) < 2:
        fi.die("usage: fm-session-memory.sh guide <session> add <one-line rule>")
    rule = " ".join(args[1:]).strip()
    lines = read_lines(path(sid, "guide.md"))
    if any(rule == re.sub(r"^- \d{4}-\d{2}-\d{2}: ", "", l) for l in lines):
        print("rule already in the guide")
        return 0
    if "## Rules" not in lines:
        lines += ["", "## Rules"]
    lines.append("- %s: %s" % (TODAY.isoformat(), rule))
    write_lines(path(sid, "guide.md"), lines)
    n = sum(1 for l in lines if l.startswith("- "))
    print("rule added (%d rules)%s" % (n, "; the guide is getting long, rewrite it down to the rules that still hold" if n > 25 else ""))
    return 0


def cmd_add(sid, args):
    need_session(sid)
    with locked(sid):
        return _cmd_add(sid, args)


def cmd_reinforce(sid, args):
    need_session(sid)
    with locked(sid):
        return _cmd_reinforce(sid, args)


def cmd_archive_stale(sid, args):
    need_session(sid)
    with locked(sid):
        return _cmd_archive_stale(sid, args)


def cmd_guide(sid, args):
    need_session(sid)
    with locked(sid):
        return _cmd_guide(sid, args)


CMDS = {"add": cmd_add, "reinforce": cmd_reinforce, "list": cmd_list, "review": cmd_review,
        "reviewed": cmd_reviewed, "archive-stale": cmd_archive_stale, "guide": cmd_guide}

if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in CMDS:
        fi.die("usage: fm-session-memory.sh {add|reinforce|list|review|reviewed|archive-stale|guide} <session> ...")
    sys.exit(CMDS[sys.argv[1]](sys.argv[2], sys.argv[3:]))
