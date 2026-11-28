/**
 * Host vitals — H1 of the health/crash-observability epic (docs/HEALTH-CRASH-OBSERVABILITY.md).
 *
 * The dashboard answers "which session needs me" but not "is the substrate about to die" —
 * and fleet-scale OOM is a documented failure class of the CLIs we run (upstream claude-code:
 * 212 "memory leak" title matches, single processes reaching 120+ GB). These vitals are the
 * first increment: see the pressure before the box does.
 *
 * Sources are node built-ins plus /proc/meminfo. `os.freemem()` on Linux ignores reclaimable
 * page cache and badly under-reports what is actually available, so `MemAvailable` is
 * preferred and the payload names which source produced it (`mode: proc | os-only`). Honest
 * degradation (the activity.ts precedent): no /proc (macOS) → swap reads null, never a faked
 * number.
 */
import { readFileSync, statfsSync } from "node:fs";
import { totalmem, freemem, loadavg, uptime, homedir } from "node:os";
/** Parse the fields we need from /proc/meminfo (values are kB). Null if the shape is wrong. */
export function parseMeminfo(text) {
    const kv = new Map();
    for (const line of text.split("\n")) {
        const m = /^(\w+):\s+(\d+)\s*kB/.exec(line);
        if (m)
            kv.set(m[1], Number(m[2]) * 1024);
    }
    const memTotal = kv.get("MemTotal");
    const memAvailable = kv.get("MemAvailable");
    if (memTotal === undefined || memAvailable === undefined)
        return null;
    return { memTotal, memAvailable, swapTotal: kv.get("SwapTotal") ?? 0, swapFree: kv.get("SwapFree") ?? 0 };
}
/**
 * One sample of host health. Cheap by design (two small file reads + two statfs), so callers
 * may take it per request — no cache, no daemon. `procRoot` is injectable for the os-only
 * degradation test; production callers never pass it.
 */
export function collectHostVitals(agentHome, procRoot = "/proc") {
    let mi = null;
    try {
        mi = parseMeminfo(readFileSync(`${procRoot}/meminfo`, "utf8"));
    }
    catch {
        /* no /proc (macOS) — fall through to os-only */
    }
    const disk = [];
    for (const path of new Set([agentHome, homedir()])) {
        try {
            const s = statfsSync(path);
            disk.push({ path, totalBytes: s.blocks * s.bsize, freeBytes: s.bavail * s.bsize });
        }
        catch {
            /* path not created yet — omit rather than fake a zero */
        }
    }
    const [l1, l5, l15] = loadavg();
    return {
        sampledAt: new Date().toISOString(),
        mode: mi ? "proc" : "os-only",
        mem: mi ? { totalBytes: mi.memTotal, availableBytes: mi.memAvailable } : { totalBytes: totalmem(), availableBytes: freemem() },
        swap: mi ? { totalBytes: mi.swapTotal, freeBytes: mi.swapFree } : null,
        load: [l1, l5, l15],
        uptimeSec: Math.round(uptime()),
        disk,
    };
}
