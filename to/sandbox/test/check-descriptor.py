#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Check the sandbox kit descriptor (and optionally sbxenv.yaml) against the
delivery's invariants. Prints one line per violation and exits 1 if there is
any, 0 otherwise. Used by test1.sh (with planted violations) and by e2e.sh
preflight. These are this delivery's rules on top of the v3 grammar, which the
kit frontend and kit-tck enforce (test2.sh):

  - first line selects the v3 frontend; schemaVersion "3"; kind workload
  - sbx@1 present (the host launches the agent and honors the image user)
  - resources@1 declares an explicit cpu and memory
  - network-policy@1 has a runtime allow list without wildcards and opens
    nothing for an install phase
  - every credential is named by service, proxy managed, and injected only
    into hosts the allow list admits, each inject naming a header (not blank)
    and a format with %s (an empty header injects nothing: that is the shape of
    sbx's built-in claude-bedrock agent, whose credentials reach it another
    way, which sbx 0.47.0 did not provide to this kit)
  - no port@1 (nothing is published), no volume or host mount, no
    privileged@1 (sbx does not apply it, and the delivery does not need it)
  - sbxenv.yaml, when given: no workspace, ports or literal secret values; its
    cpus/memory equal the kit's; its bindings stay inside the kit's allow list
"""
import re
import sys

try:
    import yaml
except ImportError:
    print("check-descriptor.py: PyYAML is required (pip install pyyaml)")
    sys.exit(2)

FORBIDDEN = {
    "com.docker.sandbox/port@1": "publishes a port",
    "com.docker.sandbox/volume@1": "declares a volume",
    "com.docker.sandbox/host-mount@1": "mounts a host path",
    "com.docker.sandbox/privileged@1": "requests privilege (sbx does not apply it; not needed)",
}


def host_of(pattern):
    return pattern.rsplit(":", 1)[0] if re.search(r":\d+$", pattern) else pattern


def check_descriptor(path):
    errors = []
    with open(path) as f:
        text = f.read()
    if not text.startswith("# syntax=docker/sandbox-kit:3\n"):
        errors.append("first line must be '# syntax=docker/sandbox-kit:3'")
    d = yaml.safe_load(text) or {}
    if d.get("schemaVersion") != "3":
        errors.append(f"schemaVersion must be \"3\", got {d.get('schemaVersion')!r}")
    if d.get("kind") != "workload":
        errors.append(f"kind must be workload, got {d.get('kind')!r}")
    caps = d.get("capabilities") or []
    by_type = {}
    for c in caps:
        by_type.setdefault(c.get("type"), []).append(c)
    if "com.docker.sandbox/sbx@1" not in by_type:
        errors.append("missing com.docker.sandbox/sbx@1")
    for t, why in FORBIDDEN.items():
        if t in by_type:
            errors.append(f"{t} {why}; the delivery must not")
    res = (by_type.get("com.docker.sandbox/resources@1") or [{}])[0].get("config") or {}
    if not res.get("cpu") or not res.get("memory"):
        errors.append("resources@1 must declare cpu and memory")
    allow = []
    np = by_type.get("com.docker.sandbox/network-policy@1") or []
    if len(np) != 1:
        errors.append("exactly one network-policy@1 is required")
    else:
        cfg = np[0].get("config") or {}
        if cfg.get("install"):
            errors.append("network-policy@1 must not open an install phase")
        allow = (cfg.get("runtime") or {}).get("allow") or []
        if not allow:
            errors.append("network-policy@1 runtime.allow is empty")
        for a in allow:
            if "*" in a:
                errors.append(f"wildcard in the allow list: {a}")
    allowed_hosts = {host_of(a) for a in allow}
    for c in by_type.get("com.docker.sandbox/credential@1") or []:
        cfg = c.get("config") or {}
        if not cfg.get("service"):
            errors.append("credential@1 without a service name")
        key = cfg.get("apiKey") or {}
        if key and key.get("proxyManaged") is not True:
            errors.append(f"credential {cfg.get('service')}: apiKey must be proxyManaged")
        for inj in key.get("inject") or []:
            if inj.get("domain") not in allowed_hosts:
                errors.append(f"credential {cfg.get('service')}: inject domain {inj.get('domain')} is not in the allow list")
            if not str(inj.get("header") or "").strip() or "%s" not in str(inj.get("format") or ""):
                errors.append(f"credential {cfg.get('service')}: inject for {inj.get('domain')} names no header or no %s format, so the proxy writes no credential")
    return d, res, allowed_hosts, errors


def mem_bytes(s):
    m = re.fullmatch(r"(\d+)\s*([kmgt]?)i?b?", str(s).strip().lower())
    if not m:
        return None
    return int(m.group(1)) * 1024 ** "_kmgt".index(m.group(2) or "_")


def check_env(path, res, allowed_hosts):
    errors = []
    with open(path) as f:
        e = yaml.safe_load(f) or {}
    if e.get("schemaVersion") != "1":
        errors.append(f"sbxenv schemaVersion must be \"1\", got {e.get('schemaVersion')!r}")
    for k in ("workspace", "additionalWorkspaces", "ports", "registries", "mcp"):
        if k in e:
            errors.append(f"sbxenv declares {k}; the delivery must not")
    for name, s in (e.get("secrets") or {}).items():
        if isinstance(s, dict) and "value" in s:
            errors.append(f"sbxenv secret {name} carries a literal value")
    opts = e.get("sandboxOptions") or {}
    if opts.get("cpus") != res.get("cpu"):
        errors.append(f"sbxenv cpus {opts.get('cpus')!r} differs from the kit's cpu {res.get('cpu')!r}")
    if mem_bytes(opts.get("memory")) != mem_bytes(res.get("memory")):
        errors.append(f"sbxenv memory {opts.get('memory')!r} differs from the kit's memory {res.get('memory')!r}")
    for svc, b in (e.get("bindings") or {}).items():
        for mech in ("apiKey", "oauth"):
            for dom in ((b or {}).get(mech) or {}).get("domains") or []:
                if dom not in allowed_hosts:
                    errors.append(f"sbxenv binding {svc}.{mech} approves {dom}, which the kit does not allow")
    return errors


def main():
    if len(sys.argv) not in (2, 3):
        print("usage: check-descriptor.py KIT_DESCRIPTOR [SBXENV_YAML]")
        return 2
    _, res, allowed_hosts, errors = check_descriptor(sys.argv[1])
    if len(sys.argv) == 3:
        errors += check_env(sys.argv[2], res, allowed_hosts)
    for e in errors:
        print(e)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
