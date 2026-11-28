#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# docker spoke - ONE read-only cycle (charter.md beside this file): the build substrate - the BuildKit daemon at
# BUILDKIT_HOST and the registry at BUILD_REGISTRY - and the disk, into STATUS.md, STATUS.html, status.json and
# prev.json in the working directory, a "HUB: " line on stdout for each change agent should hear about (the
# supervisor journals each one as a notice from the spoke), and exit. The supervisor runs it at the cadence its registry
# entry sets; this script never sleeps, loops or reads an interval.
#
# Environment: DOCKER_SPOKE_WD (default ${SPOKE_DIR:-/wd/docker}); BUILDKIT_HOST and BUILD_REGISTRY, which ./run.sh sets
# when it started the substrate (unset: STATUS.md says this target has none); DOCKER_MIN_FREE_GB (default 20);
# AGENT_DIR (default /agent, for md2html.py). Reads: buildctl debug info, debug workers and du (read-only calls), the
# registry's /v2/ API (GET only), the free space of this container's root filesystem, builds.jsonl (the helper's).
# Writes only the working directory: STATUS.md, STATUS.html, status.json and prev.json, each through a .tmp beside it.
set -uo pipefail
WD="${DOCKER_SPOKE_WD:-${SPOKE_DIR:-/wd/docker}}"
mkdir -p "${WD:?}" || { echo "docker loop: cannot create ${WD}" >&2; exit 2; }
WD="${WD}" TS="$(date -u +%FT%TZ)" MD2HTML="${AGENT_DIR:-/agent}/md2html.py" python3 -I - << 'PY'
import json, os, re, shutil, subprocess, urllib.parse, urllib.request
WD, TS = os.environ["WD"], os.environ["TS"]
HOST, REG = os.environ.get("BUILDKIT_HOST") or "", os.environ.get("BUILD_REGISTRY") or ""
try:
    MIN_GB = float(os.environ.get("DOCKER_MIN_FREE_GB") or 20)
except ValueError:
    MIN_GB = 20.0

def cell(text):
    # a table cell: one line, no pipe (an error text could carry either)
    return " ".join(str(text).replace("|", "/").split())

def size(n):
    n = float(n or 0)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024

def buildctl(*args):
    try:
        r = subprocess.run(["buildctl", "--addr", HOST, "--timeout", "5", *args], capture_output=True, text=True, timeout=30)
        return r.returncode, r.stdout, (r.stderr.strip().splitlines() or [""])[-1][:200]
    except FileNotFoundError:
        return 127, "", "buildctl is not installed in this image"
    except subprocess.TimeoutExpired:
        return 124, "", "no answer within 30 s"

get = urllib.request.build_opener(urllib.request.ProxyHandler({}))   # the stack's registry is never behind a proxy
def http(path, accept=None):
    req = urllib.request.Request(f"http://{REG}{path}", headers={"Accept": accept} if accept else {})
    with get.open(req, timeout=10) as r:
        return r.status, r.headers, r.read()

status = {"generated_utc": TS, "configured": bool(HOST and REG), "daemon": {}, "registry": {}, "cache": {}, "disk": {},
          "images": [], "builds": []}
if status["configured"]:
    rc, out, err = buildctl("debug", "info")
    m = re.search(r"BuildKit:\s+\S+\s+(v\S+)", out)
    status["daemon"] = {"state": "up" if rc == 0 else "down", "address": HOST, "version": m.group(1) if m else None,
                        "detail": None if rc == 0 else err or f"buildctl exited {rc}"}
    if rc == 0:
        rc, out, err = buildctl("debug", "workers", "--format", "{{json .}}")
        try:
            status["daemon"]["platforms"] = sorted({f"{p.get('OS') or p.get('os')}/{p.get('Architecture') or p.get('architecture')}"
                                                    for w in json.loads(out or "[]") for p in (w.get("platforms") or [])})
        except ValueError:
            pass
        rc, out, err = buildctl("du", "--format", "{{json .}}")
        try:
            recs = json.loads(out or "[]") or []
            status["cache"] = {"records": len(recs), "bytes": sum(int(r.get("size") or 0) for r in recs),
                               "reclaimable_bytes": sum(int(r.get("size") or 0) for r in recs if not r.get("inUse") and not r.get("shared"))}
        except ValueError:
            status["cache"] = {"detail": f"buildctl du gave no readable answer ({err})"}
    try:
        code, _, _ = http("/v2/")
        status["registry"] = {"state": "up" if code == 200 else "down", "address": REG, "detail": None if code == 200 else f"HTTP {code}"}
    except OSError as e:
        status["registry"] = {"state": "down", "address": REG, "detail": str(e)[:200]}
    if status["registry"]["state"] == "up":
        accept = ", ".join(["application/vnd.oci.image.manifest.v1+json", "application/vnd.docker.distribution.manifest.v2+json",
                            "application/vnd.oci.image.index.v1+json", "application/vnd.docker.distribution.manifest.list.v2+json"])
        try:
            repos = json.loads(http("/v2/_catalog?n=1000")[2]).get("repositories") or []
            for repo in repos[:200]:
                tags = json.loads(http(f"/v2/{urllib.parse.quote(repo)}/tags/list")[2]).get("tags") or []
                for tag in sorted(tags)[:100]:
                    _, h, body = http(f"/v2/{urllib.parse.quote(repo)}/manifests/{urllib.parse.quote(tag)}", accept)
                    man = json.loads(body or b"{}")
                    total = None
                    if man.get("layers") is not None:
                        total = int((man.get("config") or {}).get("size") or 0) + sum(int(l.get("size") or 0) for l in man["layers"])
                    status["images"].append({"ref": f"{REG}/{repo}:{tag}", "digest": h.get("Docker-Content-Digest"),
                                             "bytes": total, "index": man.get("manifests") is not None})
        except (OSError, ValueError) as e:
            status["registry"]["detail"] = f"the inventory read stopped: {str(e)[:160]}"
    du = shutil.disk_usage("/")
    status["disk"] = {"free_bytes": du.free, "total_bytes": du.total, "min_free_gb": MIN_GB, "low": du.free < MIN_GB * 1024 ** 3}
try:
    lines = open(os.path.join(WD, "builds.jsonl"), encoding="utf-8").read().splitlines()
    for l in lines[-5:]:
        try:
            status["builds"].append(json.loads(l))
        except ValueError:
            pass
except OSError:
    pass

# what changed since the previous cycle: the notices for agent ("HUB: " lines); a first cycle tells only what is wrong
try:
    prev = json.load(open(os.path.join(WD, "prev.json")))
except (OSError, ValueError):
    prev = None
cur = {"daemon": status["daemon"].get("state"), "registry": status["registry"].get("state"),
       "disk_low": status["disk"].get("low"), "images": {i["ref"]: i["digest"] for i in status["images"]}}
changes = []
for part, label in (("daemon", "the BuildKit daemon"), ("registry", "the registry")):
    was, now = (prev or {}).get(part), cur[part]
    if now == "down" and was != "down":
        changes.append(f"{label} does not answer ({status[part].get('detail')}): builds fail until it is back - ./docker.sh status on the host")
    elif now == "up" and was == "down":
        changes.append(f"{label} answers again")
if cur["disk_low"] and not (prev or {}).get("disk_low"):
    changes.append(f"the disk where Docker keeps the build cache and the images has {size(status['disk']['free_bytes'])} free, under DOCKER_MIN_FREE_GB={MIN_GB:g} GB")
elif prev and prev.get("disk_low") and cur["disk_low"] is False:
    changes.append(f"the disk is back above DOCKER_MIN_FREE_GB ({size(status['disk']['free_bytes'])} free)")
if prev is not None and status["registry"].get("state") == "up" and not status["registry"].get("detail"):
    before = prev.get("images") or {}
    for ref, digest in cur["images"].items():
        if ref not in before:
            changes.append(f"new image in the registry: {ref}@{digest}")
        elif before[ref] != digest:
            changes.append(f"{ref} now points at {digest} (was {before[ref]})")
    for ref in before:
        if ref not in cur["images"]:
            changes.append(f"{ref} is no longer in the registry")
status["changes_since_previous_cycle"] = changes

md = [f"# Docker - build substrate and images, {TS}", "",
      "Written by the docker spoke's cycle every 5 minutes. Images are built with `/agent/image-build.sh <context dir> "
      "<Dockerfile> <name:tag>`, which pushes only to the stack's registry; a push anywhere else is a person's step.", ""]
if not status["configured"]:
    md += ["No build substrate on this target: `BUILDKIT_HOST` and `BUILD_REGISTRY` are unset. `./run.sh` on the docker target "
           "starts it with `SPOKE_DOCKER=true` (docs/manual/agents.md \"Docker agent\").", ""]
else:
    d, r, c, k = status["daemon"], status["registry"], status["cache"], status["disk"]
    dd = (f"BuildKit {d.get('version')}, platforms {', '.join(d.get('platforms') or []) or '-'}" if d["state"] == "up" else d.get("detail") or "")
    nrepo, ntag = len({i['ref'].rsplit(':', 1)[0] for i in status['images']}), len(status['images'])
    rd = (f"{nrepo} {'repository' if nrepo == 1 else 'repositories'}, {ntag} {'tag' if ntag == 1 else 'tags'}" if r["state"] == "up" else "")
    rd = "; ".join(x for x in (rd, r.get("detail")) if x)
    cd = (f"{size(c['bytes'])} in {c['records']} records, {size(c['reclaimable_bytes'])} reclaimable (buildctl du)" if "bytes" in c
          else c.get("detail") or "not read (the daemon does not answer)")
    kd = f"{size(k['free_bytes'])} free of {size(k['total_bytes'])} where Docker keeps the volumes, as this container sees it; the threshold is {MIN_GB:g} GB (DOCKER_MIN_FREE_GB)"
    md += ["## Substrate", "", "| part | state | detail |", "|---|---|---|",
           f"| BuildKit daemon | {d['state'].upper()} | {cell(dd)} ({HOST}) |",
           f"| registry | {r['state'].upper()} | {REG}: {cell(rd)} |",
           f"| build cache | {'READ' if 'bytes' in c else '-'} | {cell(cd)} |",
           f"| disk | {'LOW' if k['low'] else 'OK'} | {cell(kd)} |", ""]
    md += ["## Images in the registry", ""]
    if status["images"]:
        md += ["| image | digest | size |", "|---|---|---|"]
        md += [f"| {i['ref']} | {i['digest'] or '-'} | {'an index' if i['index'] else size(i['bytes']) if i['bytes'] is not None else '-'} |" for i in status["images"]]
    else:
        md += ["none yet" if r["state"] == "up" else "not read (the registry does not answer)"]
    md += [""]
md += ["## Last builds", ""]
if status["builds"]:
    md += ["| time | image | digest | seconds | result |", "|---|---|---|---|---|"]
    md += [f"| {b.get('ts')} | {b.get('ref')} | {b.get('digest') or '-'} | {b.get('seconds')} | {'pushed' if b.get('rc') == 0 else 'FAILED, exit ' + str(b.get('rc'))} |"
           for b in reversed(status["builds"])]
else:
    md += ["none recorded in builds.jsonl"]
md += ["", "## Changes since the previous cycle", ""] + ([f"- {x}" for x in changes] or ["- none" if prev is not None else "- the first cycle: nothing to compare"]) + [""]
md += ["---", "Written by loop.sh (read-only: buildctl debug info, debug workers and du; the registry's /v2/ API, GET only). "
       "Writes: STATUS.md, STATUS.html, status.json and prev.json in this directory only.", ""]

def put(name, text):
    tmp = os.path.join(WD, name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, os.path.join(WD, name))

# carry the last good image inventory forward when this cycle could not read the registry fully, so the next good
# cycle does not announce every image as new after a down or partial read (the change block above guards this
# cycle's own notices; this guards what the NEXT cycle compares against)
read_ok = status["registry"].get("state") == "up" and not status["registry"].get("detail")
persist = dict(cur)
if not read_ok:
    persist["images"] = (prev or {}).get("images", {})
put("STATUS.md", "\n".join(md))
put("status.json", json.dumps(status, indent=1, sort_keys=True) + "\n")
put("prev.json", json.dumps(persist, sort_keys=True) + "\n")
r = subprocess.run(["python3", "-I", os.environ["MD2HTML"], os.path.join(WD, "STATUS.md"), "--title", "Docker",
                    "--subtitle", f"the docker spoke's page, {TS}"], capture_output=True, text=True)
if r.returncode == 0:
    put("STATUS.html", r.stdout)
else:
    print(f"docker loop: STATUS.html not rendered ({(r.stderr.strip().splitlines() or ['md2html failed'])[-1]})")
for x in changes:
    print("HUB: " + x)
if status["configured"]:
    print(f"docker spoke {TS}: daemon {status['daemon']['state']}, registry {status['registry']['state']}, "
          f"{len(status['images'])} tags, disk {'LOW' if status['disk']['low'] else 'ok'}; changes: {len(changes)}")
else:
    print(f"docker spoke {TS}: no build substrate on this target")
PY
rc=$?
rm -f "${WD:?}/STATUS.md.tmp" "${WD:?}/STATUS.html.tmp" "${WD:?}/status.json.tmp" "${WD:?}/prev.json.tmp"
exit ${rc}
