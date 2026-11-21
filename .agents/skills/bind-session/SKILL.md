---
name: bind-session
description: Turn the current chat into a named Firstmate session, or resume one, when the captain invokes /bind-session [<session-id>] [context] or asks to make this chat a session, set up a session for this work, or continue session <id> here. Works at the start of a chat from the context given, or mid-chat from what this chat has established, and carries the chat's existing committed and uncommitted work into the session without moving, stashing or discarding it.
user-invocable: true
metadata:
  internal: true
---

# bind-session

Set this chat up as one session: its instructions, guide, memory, plan, work ledger and chat binding, so that compaction and restarts reload the session from disk instead of from this chat's memory.
`docs/session-context.md` owns the session files and `docs/intake.md` owns the registry and clones; this skill is the procedure.

## 0. Take the helm first

A `SESSION START` digest for this home must already be visible in this chat.
If it is not, run `bin/fm-session-start.sh` once and read it before anything else.

## 1. Resume or create

`/bind-session <id>` where `<id>` is in `bin/fm-sessions.sh list` resumes that session: run `bin/fm-session-bind.sh bind <id>`, then read `bin/fm-dashboard.sh card <id> --rehydrate` and treat it as the authoritative state of the work.
If this chat has already touched repositories (mid-chat), still run step 4 for them so their work joins the session's ledger.
Then report in three lines (what is open, what waits on the captain, what you will do next) and stop.

Otherwise create a new session with steps 2 to 7.

## 2. Gather only what is established

Use two sources: the text given with the invocation, and, mid-chat, this conversation so far.
Take only what the captain said or what tool output in this chat showed.
Never fill a gap with an assumption: an item you cannot trace to one of those two sources is left out and, if it matters, asked about.

## 3. Draft, write nothing yet

Draft each part:

- **Session id**: short kebab-case naming the business theme (for example `credit-curve-calibration`), never a generic word such as `work`, `misc`, `project` or `session`.
- **Summary**: one sentence with no parentheses or semicolons.
- **Kind and repos**: `theme` with named repos, `chores` across every repo, or `all`. Every repo must appear in `bin/fm-projects-root.sh scan`; if the source folder is not set, ask the captain for it.
- **Home**: `primary`, unless an existing secondmate's `scope:` in `data/secondmates.md` clearly fits. Never provision a secondmate from this skill.
- **Instructions** (`instructions.md`): goal, scope, approach, constraints and what is out of scope, all across repos. Repo-specific maintainer rules stay in each repo's `AGENTS.md` or `CLAUDE.md`.
- **Guide rules**: preferences the captain stated about how to run the session: interaction, answer style, organisation, and review cadence. Only stated ones.
- **Memory**: durable facts the chat established, one line each with its source. Use pinned for hard constraints, perishable for anything with an expiry condition, and aging for the rest.
- **Decisions made in chat**: record them as pinned memory entries worded `Captain decided in chat on <date>: ...`. Never write `decisions.md`: it holds only answers upstream applied, and only `bin/fm-intake.sh` writes it.
- **Plan**: steps marked `[ ]`, `[~]`, `[!]` or `[x]` from what the chat shows.
- **Summary claim** (`summary.md`): where things stand, a few lines.

## 4. Find the work this chat already did

List every repository path this chat edited, ran git in, or named, plus any branch or PR it named.
Run `bin/fm-session-work.sh survey <path>...`, which reads only.
For each repo, note the branch and head, unpushed branches, staged, unstaged and untracked changes, stashes, and worktrees.

Propose handling per repo, and change nothing yet:

- **Always record it.** `fm-session-work.sh record` writes the ledger and a patch copy of uncommitted tracked changes. The repo itself is untouched.
- **Committed but unpushed branches**: offer to adopt them into the session's own clone with `fm-session-checkout.sh create <id> <repo>` and then `fm-session-work.sh adopt <id> <path> --branch <b>`. This changes refs in a firstmate clone, so it needs the captain's explicit approval of that exact operation (AGENTS.md hard rule 1).
- **Uncommitted changes stay where they are.** The patch copy lets a later worker restore them in an isolated copy based on the recorded head. Never apply a patch, stash, reset, check out, commit or delete anything in the original yourself.
- **Untracked files** are listed, never copied. Say so plainly: they exist only in the original.
- **Stashes and other worktrees** are reported, never touched.

## 5. One confirmation

Show the captain the whole draft in one message:

- the session line;
- the instructions;
- the guide rules;
- memory and decisions, each with its source (a short quote, or "tool output");
- the plan;
- the work inventory with the handling proposed for each repo.

Ask one question: confirm, or say what to change.
Write nothing until the captain confirms, and drop anything they reject.

## 6. Write in this order

1. `bin/fm-sessions.sh add <id> --summary "<summary>" --kind <kind> [--repos a,b] [--home <home>]`. This creates the folder and its stubs.
2. Replace the stubs with the confirmed text, using file tools on `data/sessions/<id>/instructions.md`, `plan.md` and `summary.md` only.
   Keep the guide's settings block and add each rule with `bin/fm-session-memory.sh guide <id> add "<rule>"`.
3. `bin/fm-session-memory.sh add <id> [--pin|--perishable] "<entry>"` for each confirmed memory entry.
4. `bin/fm-session-work.sh record <id> <path>...` for every surveyed repo.
5. Only for the adoptions the captain approved: `bin/fm-session-checkout.sh create <id> <repo>`, then `bin/fm-session-work.sh adopt <id> <path> --branch <b>...`.
6. `bin/fm-session-bind.sh bind <id>` to bind this chat.
   If no chat id is available, report that and ask whether to make the session the home default (`--home-default`).

## 7. Verify, then report

1. Read `bin/fm-dashboard.sh card <id> --rehydrate` back and check that every confirmed item is on it. Report any item that is missing, never paper over it.
2. Run `bin/fm-session-work.sh survey` on the original repos again and confirm their heads and changes are unchanged.
3. Report to the captain:
   - the session id;
   - what was written;
   - where each repo's work lives now, and what was deliberately not moved;
   - how to resume in a new chat (`/bind-session <id>`);
   - that running `/compact` now drops this chat's old context, while the session card reloads on its own;
   - that `bin/fm-dashboard.sh serve` shows the session.

When work resumes, brief workers with `bin/fm-brief.sh <task> <repo> --session <id>`.
That brief carries the work ledger, so a worker that must restore uncommitted work starts from the recorded patch and base in its own isolated copy.

## Limits

- `/clear` starts a new chat id. After it, run `/bind-session <id>` again to rebind the chat.
- This skill loads in chats opened in the Firstmate repository. A chat in another repo sees it only if this skill is installed for that repo or for the user.
