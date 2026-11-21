---
name: running
description: Show everything running right now in Firstmate - the fleet's workers, queue and secondmates, the sessions with the chats bound to each, pending intake messages, and the local dashboard and triage services - when the captain invokes /running or asks what is running, what is in flight, or what is happening across the fleet and sessions.
user-invocable: true
metadata:
  internal: true
---

# running

Give the captain one view of what is in flight, read-only.

1. Run `"$FM/bin/fm-running.sh"`, where `$FM` is the Firstmate root (the same lookup as the `bind-session` skill, step 0).
   It takes no lock, drains no wake and changes nothing, so it is safe to run while another session supervises.
2. Read the output and summarise it in the captain's terms: what is under way, what waits on the captain, which session each chat follows, and anything in intake not yet settled.
   Do not paste the raw sections back; relay the outcome and the next decision.
3. If a section says "no answer within Ns", say which part did not answer and that the rest is still accurate.
   Do not retry in a loop and do not start services to fill the gap.

The view covers only this Firstmate home.
A session whose repos live in another home shows there, not here.
For the narrative digest of fleet work, use `/bearings`.
