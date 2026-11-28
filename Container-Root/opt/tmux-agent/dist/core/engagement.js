import { compileParentRules } from "./lexicon.js";
/**
 * A parent that is a PROCESS rather than a tmux session (a watchdog, a cron, the human
 * operator) will never appear in `tmux list-sessions`. Treating "parent not in the live
 * session list" as orphaned mislabelled 27 of 31 real sessions on first run — their owners
 * are watchdog processes and the human `operator`, all of which are legitimate
 * non-session supervisors. Orphaned means "lineage points at a tmux session that is gone",
 * not "lineage points at something that was never a session".
 */
const NON_SESSION_PARENTS = new Set(["operator", "user", "cron", "systemd", "unknown"]);
const NON_SESSION_PARENT_RE = /watchdog|daemon|supervisor|-loop$|^loop-/i;
/**
 * ...and those names are OURS. An adopter whose supervisors are called `boss`,
 * `orchestrator-1`, or `k8s-job` inherits the identical 27-of-31 wrongness on their first run,
 * with no fix short of forking. `lexicon.json` (`parents.nonSession` /
 * `parents.nonSessionPattern`) extends this list per fleet; the built-ins stay unless the
 * operator explicitly sets `parents.replace`.
 *
 * Mutable module state, installed once at startup by configureEngagement(), because the check
 * runs per-session inside a hot poll loop and threading config through every call site would
 * touch every caller for no behavioural gain.
 */
let parentIsProcessFn = (parent) => NON_SESSION_PARENTS.has(parent.toLowerCase()) || NON_SESSION_PARENT_RE.test(parent);
/** Install lexicon parent rules. Returns the resolved predicate (handy for tests/doctor). */
export function configureEngagement(cfg) {
    parentIsProcessFn = compileParentRules(cfg, NON_SESSION_PARENTS, NON_SESSION_PARENT_RE);
    return parentIsProcessFn;
}
function parentIsProcess(parent) {
    return parentIsProcessFn(parent);
}
const DRIVE_TYPES = new Set(["input.sent", "exec.done", "exec.timeout", "session.spawned", "message.sent"]);
/**
 * @param activeWindowSecs how recently a drive event counts as "still being driven".
 *        Default 15 min: long enough to cover a supervisor thinking between turns, short
 *        enough that yesterday's work does not read as live engagement.
 */
export function computeEngagement(sessions, index, activeWindowSecs = 900, now = Date.now()) {
    // one pass over the recent ledger tail, bucketed per session
    const drives = new Map();
    for (const e of index.events(undefined, 2000, true)) {
        if (!e.session || !DRIVE_TYPES.has(e.type))
            continue;
        // A session spawning itself is not "being driven"; the actor must be someone else.
        const by = e.actor ?? null;
        const prev = drives.get(e.session);
        drives.set(e.session, { at: e.ts, by, count: (prev?.count ?? 0) + 1 });
    }
    const live = new Set(sessions.map((s) => s.session));
    const out = new Map();
    for (const s of sessions) {
        const d = drives.get(s.session);
        const drivenAgoSecs = d ? Math.max(0, Math.round((now - Date.parse(d.at)) / 1000)) : null;
        const recentlyDriven = drivenAgoSecs !== null && drivenAgoSecs <= activeWindowSecs;
        let engagement;
        if (recentlyDriven) {
            engagement = "ACTIVE";
        }
        else if (s.attached) {
            engagement = "ATTACHED";
        }
        else if (!d && s.parent && !live.has(s.parent) && !parentIsProcess(s.parent)) {
            // lineage names a tmux session that no longer exists, and nothing ever drove it:
            // the quiet-rot case. A process-parent (watchdog/operator/cron) is NOT orphaned.
            engagement = "ORPHANED";
        }
        else if (!d && !s.parent) {
            engagement = "ORPHANED"; // no lineage recorded at all — nobody claims it
        }
        else if (s.state === "WORKING") {
            engagement = "AUTONOMOUS";
        }
        else {
            engagement = "PARKED";
        }
        out.set(s.session, {
            engagement,
            lastDrivenAt: d?.at ?? null,
            lastDrivenBy: d?.by ?? null,
            drivenAgoSecs,
            driveCount: d?.count ?? 0,
        });
    }
    return out;
}
/** Sort weight: the sessions an operator should look at first come first. */
export const ENGAGEMENT_RANK = {
    ACTIVE: 0,
    ATTACHED: 1,
    AUTONOMOUS: 2,
    PARKED: 3,
    ORPHANED: 4,
};
