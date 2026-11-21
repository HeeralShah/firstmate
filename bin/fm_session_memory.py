#!/usr/bin/env python3
"""fm_session_memory.py - mechanics of a session's durable memory and guide.

The script owns the mechanical parts only: entry markers, dedupe, ageing,
review cadence, and a cold archive. Judgment (what is worth remembering, what to
merge or rewrite) stays with the agent, exactly as in the stow skill.

Entry markers reuse the stow format as trailing HTML comments:
  <!--a:YYYY-MM-DD-->   aging   (last-reinforced date)
  <!--p:YYYY-MM-DD-->   perishable
  <!--P-->              pinned: never ages
  <!--t:NAME-->         pending capture to an external tier: never archived
Aging entries go stale after `memory-stale-after` (default 30d) and perishable
ones after 14d; stale entries are MOVED to memory-archive.md, never deleted.
Cadence and style live in the session guide as `key: value` lines before the
first heading (memory-review-every, memory-stale-after).
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
    os.replace(tmp, p)


def parse_days(v, default):
    m = re.fullmatch(r"(\d+)\s*([dw]?)", (v or "").strip())
    if not m:
        return default
    return int(m[1]) * (7 if m[2] == "w" else 1)


def guide_setting(sid, key, default):
    for line in read_lines(path(sid, "guide.md")):
        if line.startswith("#"):
            break
        m = re.match(r"^%s:\s*(.+)$" % re.escape(key), line)
        if m:
            return m[1].strip()
    return default


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
    after = parse_days(guide_setting(sid, "memory-stale-after", "30d"), 30)
    res = []
    for i, tier, d, text in entries(sid):
        if tier == "pinned" or d is None:
            continue
        if PENDING.search(text) or PENDING.search(read_lines(path(sid, "memory.md"))[i]):
            continue
        limit = 14 if tier == "perishable" else after
        if (TODAY - d).days > limit:
            res.append((i, tier, d, text))
    return res


def cmd_add(sid, args):
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


def cmd_reinforce(sid, args):
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
    try:
        with open(path(sid, ".last-review")) as f:
            return datetime.strptime(f.read().strip(), "%Y-%m-%d").date()
    except (OSError, ValueError):
        return None


def review_status(sid):
    """(due: bool, message) from the guide's cadence and the last-review stamp."""
    every = parse_days(guide_setting(sid, "memory-review-every", "7d"), 7)
    lr = last_review(sid)
    if lr is None:
        return True, "memory has never been reviewed (cadence: every %dd)" % every
    gap = (TODAY - lr).days
    return gap >= every, "last reviewed %dd ago (cadence: every %dd)" % (gap, every)


def cmd_review(sid, args):
    need_session(sid)
    due, msg = review_status(sid)
    print("REVIEW DUE: %s" % msg if due else "review not due: %s" % msg)
    st = stale(sid)
    for _, tier, d, text in st:
        print("stale (%s, %s): %s" % (tier, d, text[:100]))
    if due or st:
        print("Curate with the stow rules: merge duplicates, rewrite for the current state, reinforce what still "
              "holds, then run `fm-session-memory.sh reviewed %s` (and `archive-stale` for the stale ones)." % sid)
    return 0 if not due else 0


def cmd_reviewed(sid, args):
    need_session(sid)
    with open(path(sid, ".last-review"), "w") as f:
        f.write(TODAY.isoformat() + "\n")
    print("review recorded for %s" % TODAY.isoformat())
    return 0


def cmd_archive_stale(sid, args):
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


def cmd_guide(sid, args):
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


CMDS = {"add": cmd_add, "reinforce": cmd_reinforce, "list": cmd_list, "review": cmd_review,
        "reviewed": cmd_reviewed, "archive-stale": cmd_archive_stale, "guide": cmd_guide}

if __name__ == "__main__":
    if len(sys.argv) < 3 or sys.argv[1] not in CMDS:
        fi.die("usage: fm-session-memory.sh {add|reinforce|list|review|reviewed|archive-stale|guide} <session> ...")
    sys.exit(CMDS[sys.argv[1]](sys.argv[2], sys.argv[3:]))
