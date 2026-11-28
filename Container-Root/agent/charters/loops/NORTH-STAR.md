# North Star — Loop Deck and the `loops` spoke

A data-contract-driven, read-only page over an autonomous agent fleet's loops — the schedules, the fire-and-result
evidence and the breakers behind them — that never shows a loop as healthy without evidence of a completed run, never
hides a failed, missing or unobservable one behind an invented number, and never acts on the fleet except through a
gated, audited request a human has switched on; the `loops` spoke is the resident session that keeps that page true
every cycle, validates every refresh at the pinned contract before the page may change, fails closed when it cannot,
and tells `agent` the moment a loop goes RED or the page itself stalls.
