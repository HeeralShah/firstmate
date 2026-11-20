# Fire-and-forget intake, sessions, and the projects root

This page is the operator guide for three connected pieces: a message log you can fire into and forget, named sessions that own lanes of work across projects, and a shared projects folder.

## Why intake is separate from chat

A chat agent will always try to deal with a message the moment it arrives, and it keeps item state in its own context, so items get lost when the context fills.
Intake keeps the model out of capture entirely:

1. **Capture is plain code.** `fm-intake.sh add "text"` allocates an id (`M-0001`), writes the body to `state/intake/msgs/`, appends a `captured` event to `state/intake/log.jsonl`, and prints the id. It makes no model call and no network call.
2. **Triage is a function, not an agent.** A headless `claude -p` call with every tool disabled must return JSON: `kind` (`new`, `follow-up`, `decision-answer`, `other`), the target `session`, and an optional `ref`. It can label a message but cannot act on it. Deterministic prefixes skip the model: `@<session> text` routes to that session, and `D3: text` or `answer <key>: text` is a decision answer.
3. **Delivery reuses the inbox.** The message is written into the target session's home through that home's own `fm-inbox.sh note --request-id <id>`, so a retry never duplicates it.
4. **State is derived, never remembered.** A message is `captured`, `triaged`, `delivered`, `acked`, or `closed`, computed from the log plus the target home's `state/inbox/handled/` directory (the receiving agent acknowledging a note moves it there).
5. **`fm-intake.sh check` is the fidelity audit.** It exits non-zero and names any message that was never triaged, never delivered, failed delivery, lost its body file, or sits unacknowledged past the bound.

Triage never drops a message: if the model is unavailable or answers badly, the message goes to the primary home with `by: fallback` recorded and a note saying why.
`fm-intake.sh route M-0007 <session>` overrides a mis-triage, and `close` retires a message answered elsewhere.
`state/intake/snapshot.json` is rewritten atomically after every event so a dashboard can render every number from one read.

Config in the gitignored `config/`: `intake-triage` (`model`, the default, or `rules` for prefixes only) and `intake-triage-model` (a model id for the triage call).

## Sending from chat or a terminal

Register the hook once in `~/.claude/settings.json` (firstmate never edits that file for you):

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "/absolute/path/to/firstmate/bin/fm-intake-hook.sh" }] }
    ]
  }
}
```

A prompt starting with `>>` (change it in `config/intake-prefix`) is captured and blocked, and you see `Queued M-0042`; every other prompt goes to Claude untouched.
The check is a plain string comparison, and the hook fails open: if capture fails, the prompt reaches Claude and the error is shown.
From a plain terminal, use an alias such as `alias fm='/absolute/path/to/firstmate/bin/fm-intake.sh add'`.
Verify the block with a canary: send `>> remember the word pineapple`, then ask Claude what word you mentioned; it must not know.

## Sessions

A session is a named lane of work that can span several projects: a theme (`quant` across three repos), a catch-all (`chores` across every repo), or the whole fleet.
`data/sessions.md` holds one line per session:

```markdown
- quant - Quant model work across the model repos (kind: theme; repos: maths-phys, hs-cv; home: primary; added 2026-11-20)
```

`kind` is `theme`, `chores`, or `all`; `repos: *` means every registered project; `home` is `primary` or the id of an existing secondmate in `data/secondmates.md`.
`fm-sessions.sh add` records the route and validates it: it refuses an unknown secondmate and any repo that is not a directory under the projects root.
It never creates or launches a secondmate; to give a session its own isolated home, provision the secondmate first (the `secondmate-provisioning` skill) and point `--home` at it.
A session with `home: primary` is a routing label on the main home, useful for grouping and for triage.

### Session instructions

Each session also has a task-level instruction file at `data/sessions/<id>.md`, which `fm-sessions.sh add` creates as a stub and you edit.
It holds what applies to all work in that session across its repos: the goal, the approach, theme conventions, what to verify.
It is a separate layer from each repo's `AGENTS.md` or `CLAUDE.md`, which stays the repo-maintainer layer; on a conflict about repo mechanics the repo file wins.
`fm-brief.sh <id> --session <session-id>` inlines the file into the worker's brief (a missing file is an error), so the worker never needs a path outside its worktree.
An intake delivery to a session whose file exists carries its path and the `--session` hint.
`fm-sessions.sh instructions <session-id>` prints the path, and `remove` leaves the file in place.
The file is private under `data/` and is never committed to any project.

## Projects root

Firstmate reads clones from `$FM_HOME/projects`.
`fm-projects-root.sh set ~/Projects` makes `projects/` a symlink to your shared folder so firstmate sees those repos in place, with no second copy.
It refuses to replace a `projects/` that already holds clones, and it registers nothing: `scan` lists git repos under the root and whether each is in `data/projects.md`, and registering one (delivery mode, consent) stays with the `project-management` skill.
Firstmate still only reads projects; workers change code in isolated task worktrees.
A secondmate home keeps its own `projects/`, so link it separately if a secondmate should see the shared folder.

## Limits

- Triage by model needs a working headless `claude` login; without one every message falls back to the primary home and the log says so.
- Delivery to a remote secondmate is not wired; such a session fails delivery visibly rather than guessing.
- Intake delivers a note; the receiving firstmate still decides how to act on it under the usual authority rules.
