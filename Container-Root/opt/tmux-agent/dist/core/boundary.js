export function installErrorBoundary(ledger, component) {
    const record = (kind, err) => {
        const e = err;
        const detail = {
            component,
            kind,
            message: String(e?.message ?? err).slice(0, 400),
            stack: e?.stack?.split("\n").slice(0, 4).join(" | ").slice(0, 600) ?? null,
        };
        try {
            ledger.emit({ type: "control.denied", actor: component, data: { boundary: detail } });
        }
        catch {
            /* ledger itself failed — nothing left to do but stay alive */
        }
        console.error(`[${component}] ${kind}: ${detail.message}`);
    };
    process.on("unhandledRejection", (reason) => record("unhandledRejection", reason));
    process.on("uncaughtException", (err) => record("uncaughtException", err));
}
