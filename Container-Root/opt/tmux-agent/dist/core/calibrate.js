/** Escape a literal for safe inclusion in a proposed regex. */
export function escapeRegex(s) {
    return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
/**
 * Prompt-glyph detection. We look for a leading non-alphanumeric marker followed by a numbered
 * option or a yes/no — the shape EVERY agent CLI we have seen uses for "awaiting human", while
 * differing in the exact glyph (`❯` claude-code, `›` codex, `(Y)es/(N)o` aider). Matching the
 * SHAPE rather than the glyph is what lets this find a CLI nobody has profiled.
 */
const NUMBERED_OPTION = /^\s*([^\w\s])\s*\d+[.)]\s+\S/;
const YES_NO = /\((?:y|Y)\)?(?:es)?\s*\/\s*\(?(?:n|N)\)?(?:o)?\)|\[y\/n\]|\(y\/n\)/i;
/**
 * Credential-shape screening. This reports SHAPES, never values: a high-entropy token adjacent to
 * a credential-ish keyword is described by charset and length so a human can decide, and the
 * secret itself is never copied into the report. Anything the built-in redactor already caught is
 * invisible here by construction (input arrives redacted), so what surfaces is precisely the gap.
 */
const KEYVAL = /\b([A-Za-z][A-Za-z0-9_-]{2,30})\s*[=:]\s*(\S{16,})/g;
const CRED_HINT = /key|secret|token|pass|cred|auth|sig|bearer|api/i;
function describeShape(v) {
    const cls = [
        /[a-z]/.test(v) ? "a-z" : null,
        /[A-Z]/.test(v) ? "A-Z" : null,
        /\d/.test(v) ? "0-9" : null,
        /[-_]/.test(v) ? "-_" : null,
        /[^A-Za-z0-9_-]/.test(v) ? "punct" : null,
    ].filter(Boolean);
    const prefix = /^[A-Za-z]{2,6}[-_]/.exec(v)?.[0] ?? null;
    return `${v.length} chars, charset [${cls.join(" ")}]${prefix ? `, prefix "${prefix}"` : ""}`;
}
/** Shannon entropy per char — cheap way to tell a token from a word. */
export function entropy(s) {
    const freq = new Map();
    for (const c of s)
        freq.set(c, (freq.get(c) ?? 0) + 1);
    let h = 0;
    for (const n of freq.values()) {
        const p = n / s.length;
        h -= p * Math.log2(p);
    }
    return h;
}
/**
 * The deterministic pass. Pure function of its input so it is trivially testable and produces
 * identical output for identical fleets.
 */
export function calibrate(inputs, now = new Date().toISOString()) {
    const notes = [];
    const liveSessions = new Set(inputs.map((i) => i.session));
    // ── parents: lineage pointing at something that is not a live session ──
    const parentCounts = new Map();
    for (const i of inputs) {
        if (!i.parent || liveSessions.has(i.parent))
            continue;
        const prev = parentCounts.get(i.parent);
        parentCounts.set(i.parent, { count: (prev?.count ?? 0) + 1, example: prev?.example ?? i.session });
    }
    const parents = [...parentCounts.entries()]
        // A name shared by several children is a supervisor; one child is more likely a dead session.
        .filter(([, v]) => v.count >= 2)
        .sort((a, b) => b[1].count - a[1].count)
        .map(([name, v]) => ({
        name,
        evidence: { sample: `@agent_parent=${name}`, session: v.example, seenInSessions: v.count },
        reason: `${v.count} live sessions name "${name}" as parent but no tmux session by that name exists — a shared non-session owner (watchdog/cron/operator) rather than ${v.count} orphans`,
    }));
    if (parentCounts.size > 0 && parents.length === 0) {
        notes.push("every unresolved parent was named by exactly one session — those may be genuine orphans, so none were proposed");
    }
    // ── prompts: recurring blocking-prompt SHAPES at pane tails ──
    const promptSeen = new Map();
    for (const i of inputs) {
        for (const line of i.tail.slice(-4)) {
            const m = NUMBERED_OPTION.exec(line);
            const isYesNo = YES_NO.test(line);
            if (!m && !isYesNo)
                continue;
            const glyph = m?.[1] ?? null;
            const key = glyph ? `glyph:${glyph}` : "yesno";
            const e = promptSeen.get(key) ?? { sessions: new Set(), glyph };
            e.sessions.add(i.session);
            promptSeen.set(key, e);
        }
    }
    const prompts = [...promptSeen.entries()].map(([key, v]) => ({
        line: key,
        suggestedPattern: v.glyph ? `(^|\\s)${escapeRegex(v.glyph)}\\s*\\d+\\.` : "\\(y/n\\)|\\[y/n\\]",
        evidence: { sample: key, session: [...v.sessions][0], seenInSessions: v.sessions.size },
    }));
    // ── secret shapes the built-in redactor did NOT catch ──
    const shapes = new Map();
    for (const i of inputs) {
        const text = i.tail.join("\n");
        for (const m of text.matchAll(KEYVAL)) {
            const [, key, value] = m;
            if (!CRED_HINT.test(key))
                continue;
            // already-redacted values are the built-ins working; skip them
            if (value.includes("[REDACTED"))
                continue;
            if (entropy(value) < 3.2)
                continue; // prose, not a token
            const name = `${key.toLowerCase()}-shape`;
            if (!shapes.has(name)) {
                shapes.set(name, {
                    suggestedName: name,
                    shape: describeShape(value),
                    evidence: { sample: `${key}=<${describeShape(value)}>`, session: i.session, seenInSessions: 1 },
                    reason: `"${key}" reads as a credential and its value survived built-in redaction — if this is a secret, the built-ins do not know its shape`,
                });
            }
            else {
                shapes.get(name).evidence.seenInSessions++;
            }
        }
    }
    const secretShapes = [...shapes.values()];
    if (secretShapes.length) {
        notes.push(`${secretShapes.length} credential-shaped value(s) survived redaction. Values are NEVER copied into this report — only length/charset. Review before adding, and prefer a narrow anchored pattern.`);
    }
    const draft = { version: 1 };
    if (parents.length)
        draft.parents = { nonSession: parents.map((p) => p.name) };
    if (prompts.length) {
        draft.profiles = [
            {
                name: "calibrated-local",
                // Only BLOCKED is proposed: it is the state whose signal is unambiguous from a pane tail.
                // WORKING/ERROR vocabulary needs a human or an agent to read the CLI's own wording, and
                // guessing them would produce exactly the confident wrongness this file exists to avoid.
                blocked: prompts.map((p) => p.suggestedPattern),
            },
        ];
        notes.push("the proposed profile covers BLOCKED only — WORKING/ERROR wording is CLI-specific and needs a human or an agent to name it; a guess there would misclassify confidently");
    }
    notes.push("NOTHING here has been applied. Review, edit, then copy into $TMUX_AGENT_HOME/lexicon.json and re-run `tmux-agent doctor` to confirm it loaded.");
    return {
        generatedAt: now,
        sampled: { sessions: inputs.length, parents: parentCounts.size },
        parents,
        prompts,
        secretShapes,
        draft,
        notes,
    };
}
