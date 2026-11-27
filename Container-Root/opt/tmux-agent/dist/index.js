export { Tmux, TmuxError, sessionTarget, paneTarget } from "./core/tmux.js";
// The two refusals the driver throws at a consumer — `new Tmux({ socket })` judges its socket name and
// sessionTarget()/paneTarget() their session name, each before any server is asked — were nameable from the
// root by nobody until they were exported here. The product's own instanceof sites reach them through `../core/tmux.js`, a
// path the exports map refuses to a consumer, so the only handle a library caller had was err.message, whose
// wording is NOT covered. The class is the stable handle; the message may still change.
export { SessionNameError, SocketNameError } from "./core/tmux.js";
export { Ledger } from "./core/ledger.js";
// Incremental reader of the ledger format VERSIONING item 3 covers. An embedder consuming the
// ledger (their own dashboard, a supervisor) would otherwise re-parse every .ndjson per poll —
// the exact cost this class exists to remove. VERSIONING item 6 had promised it since
// 2026-08-25 without it ever being exported.
export { LedgerIndex } from "./analytics/ledger-index.js";
export { Orchestrator } from "./core/orchestrator.js";
// What `Orchestrator.spawn()` throws for a directory the session cannot be born in.
export { CwdError } from "./core/orchestrator.js";
export { Policy } from "./core/policy.js";
// What `Policy.assertAllowed()` throws, and the one field it carries: `reason` is WHICH of the three rules said
// no — the value the orchestrator ledgers a refusal under — so a consumer discriminating on it needs the union's
// name as much as the class's. The three literals are held to the ones the built policy.js constructs
// the class with, in test/versioning-contract.test.js.
export { PolicyDenied } from "./core/policy.js";
export { Monitor, claudeCodeProfile, codexProfile, aiderProfile, genericShellProfile, resolveProfiles, profileFromLexicon } from "./core/monitor.js";
// What `Monitor.snapshot(session, profileName)` — and fleet(), fleetReport(), fleetFast({ profileName }) through it —
// throws for a profile name this Monitor does not hold; before ProfileNameError existed an unknown name silently fell back to the
// auto chain. The eighth error class of VERSIONING.md item 6, root-exported for the same reason as the classes above.
export { ProfileNameError } from "./core/monitor.js";
// `Monitor.activity` is a documented test seam (src/core/monitor.ts: "Public so a test can substitute a
// tracker with scripted samples"), so substituting a tracker is supported — and until these exports a consumer
// doing it could name none of the three types involved: not the class, not the `thresholds` its
// constructor takes, not the `sample` reading it accepts. The class was invisible to the closure's
// declaration index, which took the two interfaces behind it down with it.
export { ActivityTracker } from "./core/activity.js";
// Per-fleet vocabulary (docs/AGNOSTIC-DESIGN.md). Exported because an embedder driving the
// library directly — not via the CLI — must be able to honour the operator's lexicon too;
// otherwise their fleet is classified with our vocabulary and redacted with our patterns.
export { loadLexicon, validateLexicon, LexiconError } from "./core/lexicon.js";
export { calibrate } from "./core/calibrate.js";
export { CaptureWatchdog } from "./core/watchdog.js";
export { redact, configureRedaction } from "./core/redact.js";
export { configureEngagement } from "./core/engagement.js";
export { Mailbox } from "./adapters/messaging/mailbox.js";
// What `Mailbox.send()` throws for a <from> or <to> that is not an agent name.
export { AgentNameError } from "./adapters/messaging/mailbox.js";
export { SlackWebhookSink, ConsoleSink } from "./adapters/notify/slack.js";
export { publishStatus, wasteReport } from "./analytics/status.js";
// What `publishStatus()` throws for a FILE it cannot write, and `wasteReport()` for a `since` it cannot read.
export { OutPathError, SinceError } from "./analytics/status.js";
