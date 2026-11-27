# North Star — the `sessions` spoke

A read-only bookkeeper over an autonomous agent fleet's tmux sessions that reports no state it did not read from the
dashboard's census, with the census's own provenance and time; it never upgrades UNKNOWN to anything, never reads an
unreachable tmux server as an empty fleet or an unreachable dashboard as a quiet one, and never spawns, sends to or
kills a session. It records who owns what and whether it is working, idle, blocked, stalled or dead, recommends keep or
close with the evidence, tells `agent` only what changed, and corrects itself in the next cycle the moment a fact it
reported stops being true.
