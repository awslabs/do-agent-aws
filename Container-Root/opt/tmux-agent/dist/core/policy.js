/**
 * Policy: safe-by-default control scoping.
 * - read-only mode blocks all mutating verbs
 * - kill/send/exec each gated by allowlists (glob-ish prefix match)
 * - every refusal is an auditable event (caller logs control.denied)
 * Config file: $TMUX_AGENT_HOME/policy.json (or path via env TMUX_AGENT_POLICY). Only a default path with NO ENTRY is
 * silently the permissive {}: a file that exists and cannot be read, a symbolic link whose target is missing,
 * a TMUX_AGENT_POLICY path that cannot be read, or a file that is not this schema is a PolicyError the caller refuses on
 * — exit 78 on every CLI verb (`web` before it binds), the MCP server before initialize is answered (see
 * loadPolicy).
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { danglingLink, readFailure } from "./read-failure.js";
/**
 * What assertAllowed() throws. A plain Error with the same message (the CLI prints `.message`,
 * the MCP server returns it — neither changes) plus the cause, so the caller that ledgers the
 * refusal (header line 5) can record WHICH of the three rules said no without parsing
 * text.
 */
export class PolicyDenied extends Error {
    reason;
    constructor(message, reason) {
        super(message);
        this.reason = reason;
        // Named like the six other classes a covered value throws, so a log line names the class rather than "Error";
        // root-exported, so the class is the handle a consumer catches on instead of the message.
        this.name = "PolicyDenied";
    }
}
/**
 * What loading the policy FILE throws — distinct from PolicyDenied, which is a valid policy saying no. The message names
 * the path and what is wrong with it (for a read failure: the source, the path as given and the OS reason in the lexicon
 * loader's words); the CLI prints it as `policy config error: …` and exits 78 (EX_CONFIG), the MCP server the same before
 * initialize is answered. Until this change (measured 2026-10-13 on an earlier build) the constructor's one bare `catch { this.cfg =
 * {}; }`, meant for the absent default, also covered a malformed file, a directory, a file this user could not read and a
 * TMUX_AGENT_POLICY path that did not exist — every surface open, `explain().source` reading "global default", nothing on
 * stderr. The lexicon loader had refused the same class already; the file THREAT-MODEL finding 1 credits with
 * saving the live instance had not.
 */
export class PolicyError extends Error {
    constructor(message) {
        super(message);
        this.name = "PolicyError";
    }
}
const TOP_KEYS = ["readOnly", "surfaces", "allow", "deny"];
const SURFACE_KEYS = ["readOnly", "allow", "deny"];
const SURFACES = ["web", "mcp", "cli"];
const ACTIONS = ["spawn", "send", "exec", "kill", "adopt"];
const SURFACE_WORDS = "web, mcp or cli";
const ACTION_WORDS = "spawn, send, exec, kill or adopt";
/** The one escape from the closed key sets: an operator's annotation beside the rules (the live home carries a `_note`). */
const NOTE = 'a key beginning with "_" is a note and is ignored';
/** The variable (set is set — an empty value is a file named nothing), else policy.json under the home. */
function resolvePolicyPath() {
    if (process.env.TMUX_AGENT_POLICY !== undefined)
        return { source: "TMUX_AGENT_POLICY", path: process.env.TMUX_AGENT_POLICY };
    return { source: "default path", path: join(process.env.TMUX_AGENT_HOME ?? join(homedir(), ".tmux-agent"), "policy.json") };
}
/** What a wrong value is called in a refusal: primitives as JSON, the two JSON containers by name. */
function describe(v) {
    if (v === null)
        return "null";
    if (Array.isArray(v))
        return "an array";
    if (typeof v === "object")
        return "an object";
    return JSON.stringify(v) ?? String(v);
}
const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
/**
 * Load + validate the policy file. The permissive `{}` is returned in exactly ONE case: nothing was named and the default
 * $TMUX_AGENT_HOME/policy.json has no entry at all (v0.1.0 behaviour, unchanged) — not a symbolic link whose target is
 * missing, which reads ENOENT too and is refused naming the link and its target. Every other failure is a
 * PolicyError — a read failure names the source, the path as given and the OS reason (`TMUX_AGENT_POLICY "<path>": cannot
 * be read — no such file or directory (ENOENT)`); a content failure names the path and the field (validatePolicy).
 * Absent-by-default and named-but-unreadable are told apart HERE, not by the caller, as loadLexicon does.
 */
export function loadPolicy() {
    const { source, path: p } = resolvePolicyPath();
    let raw;
    try {
        raw = readFileSync(p, "utf8");
    }
    catch (e) {
        if (e.code === "ENOENT") {
            // ENOENT is also what a symbolic link whose target is missing reads as — a policy.json linked into a dotfiles
            // checkout that moved. The entry exists, so it is not the absent file: refused, naming the link and its target
            // (Before this fix this was the permissive default with nothing on stderr.)
            const dangling = danglingLink(p);
            if (dangling !== null)
                throw new PolicyError(`${source} ${JSON.stringify(p)}: cannot be read — ${dangling}`);
            // the one silent case: no policy file => the permissive default, ownership checks still apply at the orchestrator
            if (source === "default path")
                return {};
        }
        throw new PolicyError(`${source} ${JSON.stringify(p)}: cannot be read — ${readFailure(e)}`);
    }
    let cfg;
    try {
        cfg = JSON.parse(raw);
    }
    catch (e) {
        // Loud, not silent: a typo'd policy must never look like "no policy".
        throw new PolicyError(`${p}: not valid JSON — ${e.message}`);
    }
    validatePolicy(cfg, p);
    return cfg;
}
/**
 * The schema VERSIONING.md item 5 declares, checked one field at a time so a refusal names the field: the root is an
 * object; the keys are the four declared ones (a key beginning with `_` is a note); `readOnly` is a boolean; `surfaces`
 * is keyed by web/mcp/cli, each entry the same three rule keys; `allow` and `deny` are keyed by the five actions, each an
 * array of session-name patterns. Closed sets refuse the typo that would otherwise never apply — `readonly`, a surface
 * named `dashboard`, an action spelt `spwan` — because here a rule that silently does nothing removes a control.
 */
export function validatePolicy(cfg, where) {
    if (!isObject(cfg))
        throw new PolicyError(`${where}: expected a JSON object`);
    checkRules(cfg, where, "", TOP_KEYS);
    if (cfg.surfaces === undefined)
        return;
    if (!isObject(cfg.surfaces)) {
        throw new PolicyError(`${where}: surfaces must be an object keyed by surface — ${SURFACE_WORDS} (got ${describe(cfg.surfaces)})`);
    }
    for (const [name, entry] of Object.entries(cfg.surfaces)) {
        if (name.startsWith("_"))
            continue;
        if (!SURFACES.includes(name))
            throw new PolicyError(`${where}: surfaces.${name} is not a surface — ${SURFACE_WORDS}`);
        if (!isObject(entry))
            throw new PolicyError(`${where}: surfaces.${name} must be an object (got ${describe(entry)})`);
        checkRules(entry, where, `surfaces.${name}.`, SURFACE_KEYS);
    }
}
/** One rule set — the top level or one surface entry: its keys, its readOnly, its allow and deny lists. */
function checkRules(rules, where, prefix, known) {
    for (const key of Object.keys(rules)) {
        if (key.startsWith("_") || known.includes(key))
            continue;
        const at = prefix ? `${prefix.slice(0, -1)}: ` : "";
        throw new PolicyError(`${where}: ${at}unknown key ${JSON.stringify(key)} — the keys are ${known.join(", ")}; ${NOTE}`);
    }
    if (rules.readOnly !== undefined && typeof rules.readOnly !== "boolean") {
        throw new PolicyError(`${where}: ${prefix}readOnly must be true or false (got ${describe(rules.readOnly)})`);
    }
    for (const list of ["allow", "deny"]) {
        const v = rules[list];
        if (v === undefined)
            continue;
        if (!isObject(v))
            throw new PolicyError(`${where}: ${prefix}${list} must be an object keyed by action — ${ACTION_WORDS} (got ${describe(v)})`);
        for (const [action, patterns] of Object.entries(v)) {
            if (action.startsWith("_"))
                continue;
            if (!ACTIONS.includes(action))
                throw new PolicyError(`${where}: ${prefix}${list}.${action} is not an action — ${ACTION_WORDS}`);
            if (!Array.isArray(patterns)) {
                throw new PolicyError(`${where}: ${prefix}${list}.${action} must be an array of session-name patterns (got ${describe(patterns)})`);
            }
            patterns.forEach((pat, i) => {
                if (typeof pat !== "string")
                    throw new PolicyError(`${where}: ${prefix}${list}.${action}[${i}] must be a string (got ${describe(pat)})`);
            });
        }
    }
}
export class Policy {
    cfg;
    /** the surface this instance speaks for; scoped rules are resolved against it */
    surface;
    /** `cfg` given: taken as is (an embedder's object, the tests'). Else the file — loadPolicy, which throws PolicyError. */
    constructor(cfg, surface = "cli") {
        this.surface = surface;
        this.cfg = cfg ?? loadPolicy();
    }
    /** Rules in effect for this surface (surface entry overrides the global default). */
    rules() {
        const s = this.cfg.surfaces?.[this.surface];
        if (!s)
            return { readOnly: this.cfg.readOnly, allow: this.cfg.allow, deny: this.cfg.deny };
        return {
            readOnly: s.readOnly ?? this.cfg.readOnly,
            allow: s.allow ?? this.cfg.allow,
            deny: s.deny ?? this.cfg.deny,
        };
    }
    isReadOnly() {
        return !!this.rules().readOnly;
    }
    /** Human-readable explanation of what this surface may not do, and why. */
    explain() {
        const r = this.rules();
        const hidden = r.readOnly ? ["spawn", "send", "exec", "kill", "adopt"] : [];
        return {
            surface: this.surface,
            readOnly: !!r.readOnly,
            hiddenActions: hidden,
            source: this.cfg.surfaces?.[this.surface] ? `surfaces.${this.surface}` : "global default",
        };
    }
    /** Throws PolicyDenied when this surface may not perform `action` on `session`; the caller ledgers it. */
    assertAllowed(action, session, actor) {
        const r = this.rules();
        if (r.readOnly) {
            throw new PolicyDenied(`policy: ${this.surface} surface is read-only — ${action} on ${session} denied (actor ${actor}). ` +
                `Set surfaces.${this.surface}.readOnly=false in the policy file to allow it.`, "read-only surface");
        }
        const denies = r.deny?.[action];
        if (denies && denies.some((p) => match(p, session))) {
            throw new PolicyDenied(`policy: ${action} on ${session} denied by deny-list (actor ${actor})`, "deny-list");
        }
        const allows = r.allow?.[action];
        if (allows && !allows.some((p) => match(p, session))) {
            throw new PolicyDenied(`policy: ${action} on ${session} not in allow-list (actor ${actor})`, "allow-list");
        }
    }
}
function match(pattern, name) {
    if (pattern === "*")
        return true;
    if (pattern.endsWith("*"))
        return name.startsWith(pattern.slice(0, -1));
    return pattern === name;
}
