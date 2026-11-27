#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Import the domain-general skills of a native Claude Code instance into the harness, scrubbed (docs/manual/autonomy.md "Parity with a
native instance", docs/parity/PARITY-GAP.md).

    tools/import-skills.py <skills dir> [--dest Container-Root/agent/skills] [--already-shipped <plugin skills dir>]...
                           [--names-file <file>] [--max-bytes 20000] [--domain-terms 8] [--host-refs 2]
                           [--only name,...] [--list] [--report <file>]

<skills dir> holds one directory per skill with a SKILL.md (Claude Code's layout, ~/.claude/skills on a native host).
Every skill is judged by the same rule, printed in the report, so the selection is reproducible rather than a hand-pick:

  kept     a SKILL.md with a frontmatter name and description, at most --max-bytes long, whose SUBJECT - its name and
           description - names no term of one hardware or framework domain (the list DOMAIN below: accelerators, their
           network fabrics and the frameworks that run on them: a skill about a method stays even when its examples
           cite a GPU, a skill about one stack goes) and whose body names fewer than --domain-terms distinct such terms
           (a body saturated with them is about the stack whatever its title says), whose name and description the
           scrub leaves unchanged (a description that names the source site's people, repositories or clusters is
           about that site), that carries at most --host-refs references to the source host (a path under a home
           directory or ~/, a scratch/ path, a word of --names-file, or one of the skill's own files that is not
           copied - an instruction that cannot be followed in the container is not shipped), that names no skill
           of the source library that is itself not kept (a skill that leans on an absent one is not shipped), and
           whose name is not a skill a plugin the image installs already ships (--already-shipped, one directory
           per plugin)
  scrubbed before it is written: Slack ids, cloud account ids, IPv4 addresses and private hostnames, e-mail addresses,
           credential-shaped strings, paths under a home directory, messaging chat ids, gist URLs and ids, and every word of --names-file (the people,
           customers, clusters and organisations of the source site, one per line) become placeholders in angle
           brackets; a skill whose scrubbed text still matches a leak shape is dropped, never shipped half-scrubbed
  written  <dest>/<name>/SKILL.md with the scrubbed text and a trailing provenance comment; the other files of the
           skill's directory are NOT copied (they are the source site's), and the report says so per skill.
           /agent/claude-skills-sync.sh then copies <dest> into the agent's Claude configuration at the build and at
           every start, the way the harness-setup skill reaches it.

--list prints the decision per skill and writes nothing. --report writes markdown: the rule with its thresholds, the
counts of dropped skills per reason (their names are the source site's and are not listed), and one line per kept skill
with its note. Exit 0 when it ran, 2 on a usage error.
Stdlib only; reads the source tree, writes only under --dest and the report file.
"""
import argparse
import datetime
import os
import re
import sys

DOMAIN = ["EFA", "libfabric", "fi_", "NCCL", "NVSHMEM", "DeepEP", "NIXL", "CUDA", "GPU", "RDMA", "SRD", "HyperPod", "Trainium",
          "Neuron", "trn2", "trn1", "Dynamo", "vLLM", "SGLang", "TensorRT", "TRT-LLM", "Megatron", "NeMo", "MoE", "kernel",
          "InfiniBand", "p5en", "p5.48xlarge", "H100", "H200", "B200", "DCGM", "NVLink", "nvidia-smi", "torch", "PyTorch",
          "GDRCopy", "gdrdrv", "IBGDA", "GDAKI", "UCX", "aws-ofi-nccl", "nccl-tests", "Slurm", "MPI", "UCCL", "pplx", "ibv_",
          "NVIDIA", "aiperf", "genai-perf", "KV cache", "dispatch/combine", "all-reduce", "AllReduce", "FSDP", "Ray", "FSx",
          "Triton", "DeepSeek", "Qwen", "Llama", "Mixtral", "P4d", "p4d", "P5", "SDG", "nccl", "cuda"]
# the generic shapes of a reference to the source host: a path under a home directory or ~/, a scratch/ path; the site's own
# tool and project names come from --names-file (they are the site's and are not written into this file)
HOST_TOOL = re.compile(r"(?:^|[\s`'\"(=\[])(?:/(?:home|Users)/[^\s`'\")\]]+|~/[^\s`'\")\]]+|(?:\./)?scratch/[^\s`'\")\]]+)")
# the leak shapes: a hit after scrubbing drops the skill
SHAPES = [
    ("a Slack id", re.compile(r"\b[UCDGW]0[A-Z0-9]{8,10}\b")),
    ("a cloud account id", re.compile(r"\b[0-9]{12}\b")),
    ("an IPv4 address", re.compile(r"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b")),
    ("a private hostname", re.compile(r"\bip-[0-9]{1,3}-[0-9]{1,3}-[0-9]{1,3}-[0-9]{1,3}\b|\.compute\.internal\b|\.ec2\.internal\b|\bi-[0-9a-f]{17}\b")),
    ("an e-mail address", re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")),
    ("a credential shape", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b|\bxox[abposr]-[0-9A-Za-z-]{10,}|\bgh[pousr]_[0-9A-Za-z]{30,}|\bgithub_pat_[0-9A-Za-z_]{22,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|\bsk-(?:ant|proj)-[A-Za-z0-9_-]{20,}|\bhf_[A-Za-z0-9]{30,}|\bABSK[A-Za-z0-9+/=]{20,}")),
    ("a home directory path", re.compile(r"/(?:home|Users)/[A-Za-z0-9_.-]+(?:/|\b)|(?<![A-Za-z0-9])-(?:home|Users)-[A-Za-z0-9_.-]+-")),
    ("a messaging chat id", re.compile(r"(?i)\b(?:telegram|chat[ _-]?id|whatsapp|signal)\b\D{0,24}\b[0-9]{7,12}\b")),
    ("a gist URL", re.compile(r"gist\.github\.com/[^\s`'\")\]>]+|\bgist(?: id)?\s+[0-9a-f]{8,32}\b")),
]
SCRUB = [  # (shape, placeholder); the names come from --names-file
    (SHAPES[5][1], "<TOKEN>"),
    (SHAPES[0][1], "<SLACK_ID>"),
    (SHAPES[1][1], "<ACCOUNT_ID>"),
    (SHAPES[3][1], "<HOST>"),
    (SHAPES[2][1], "<IP>"),
    (SHAPES[4][1], "<email>"),
    (re.compile(r"/(?:home|Users)/[A-Za-z0-9_.-]+(?:/[^\s`'\")\]>,;:]*)?"), "<path>"),
    (re.compile(r"(?<![A-Za-z0-9])~/[^\s`'\")\]>,;:]+"), "<path>"),
    (re.compile(r"gist\.github\.com/[^\s`'\")\]>]+"), "<gist>"),
    (re.compile(r"(?i)(\bgist(?: id)?\s+)[0-9a-f]{8,32}\b"), r"\1<gist>"),
    (re.compile(r"(?i)(\b(?:telegram|chat[ _-]?id|whatsapp|signal)\b\D{0,24})\b[0-9]{7,12}\b"), r"\1<CHAT_ID>"),
    (re.compile(r"(?<![A-Za-z0-9])-(?:home|Users)-[A-Za-z0-9_.-]+-[A-Za-z0-9_.-]*"), "<project-slug>"),
]
# a version is not an address: 1.2.3 (three parts, not inside a dotted quad) and v1.2.3.4 / version 1.2.3.4 are set aside before
# the IPv4 shape runs; a bare dotted quad is an address unless it is loopback or the unspecified address
VERSION_SHAPE = re.compile(r"(?<![0-9.])(?:(?:v|version )[0-9]+(?:\.[0-9]+){3}|[0-9]+\.[0-9]+\.[0-9]+)(?![0-9.])")
LOOPBACK = re.compile(r"\b(?:127\.0\.0\.1|0\.0\.0\.0)\b")


def frontmatter(text):
    """(name, description) of a SKILL.md, or (None, None) when the frontmatter has no both."""
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not m:
        return None, None
    name = desc = None
    for line in m.group(1).splitlines():
        if re.match(r"^name:\s*\S", line):
            name = line.split(":", 1)[1].strip().strip("\"'")
        elif re.match(r"^description:\s*\S", line):
            desc = line.split(":", 1)[1].strip()
    if desc is not None:
        lines = m.group(1).splitlines()
        i = next(i for i, l in enumerate(lines) if re.match(r"^description:", l)) + 1
        cont = []
        while i < len(lines) and (lines[i].startswith(" ") or lines[i] == ""):
            cont.append(lines[i].strip()); i += 1
        if desc in (">", ">-", ">+", "|", "|-", "|+"):
            desc = " ".join(x for x in cont if x) or None
        elif cont:
            desc = " ".join([desc] + [x for x in cont if x])
    return name, desc


def domain_terms(text):
    """The DOMAIN terms the text names as words (fi_ and ibv_ as prefixes): 'empirically' is not MPI, 'array' is not Ray."""
    found = []
    for t in DOMAIN:
        if t.endswith("_"):
            pat = r"(?<![A-Za-z0-9_])" + re.escape(t) + r"[A-Za-z0-9_]"
        else:
            pat = r"(?<![A-Za-z0-9_])" + re.escape(t) + r"(?![A-Za-z0-9_])"
        if re.search(pat, text, re.I):
            found.append(t)
    return sorted(found)


def scrub(text, names):
    # versions are kept: the IPv4 shape would turn 2.1.304.1 into an address
    keep = {}
    def hold(m):
        k = "\x00%d\x00" % len(keep)
        keep[k] = m.group(0)
        return k
    text = VERSION_SHAPE.sub(hold, text)
    text = LOOPBACK.sub(hold, text)
    for shape, ph in SCRUB:
        text = shape.sub(ph, text)
    for n in names:
        text = re.compile(r"(?<![A-Za-z0-9])" + re.escape(n) + r"(?![A-Za-z0-9])", re.I).sub("<name>", text)
    for k, v in keep.items():
        text = text.replace(k, v)
    return text


def leaks(text, names):
    found = []
    held = LOOPBACK.sub(" ", VERSION_SHAPE.sub(" ", text))
    for label, shape in SHAPES:
        if shape.search(held):
            found.append(label)
    for n in names:
        if re.search(r"(?<![A-Za-z0-9])" + re.escape(n) + r"(?![A-Za-z0-9])", text, re.I):
            found.append("the name %s" % n[:1] + "*" * (len(n) - 1))
    return found


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source")
    ap.add_argument("--dest", default="Container-Root/agent/skills")
    ap.add_argument("--already-shipped", action="append", default=[], metavar="DIR")
    ap.add_argument("--names-file")
    ap.add_argument("--max-bytes", type=int, default=20000)
    ap.add_argument("--domain-terms", type=int, default=8)
    ap.add_argument("--host-refs", type=int, default=2)
    ap.add_argument("--only")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--report")
    a = ap.parse_args(argv)
    if not os.path.isdir(a.source):
        print("import-skills: %s is not a directory" % a.source, file=sys.stderr)
        return 2
    names = []
    if a.names_file:
        names = [l.strip() for l in open(a.names_file, encoding="utf-8") if l.strip() and not l.startswith("#")]
    shipped = set()
    for d in a.already_shipped:
        if os.path.isdir(d):
            shipped |= set(n for n in os.listdir(d) if os.path.isfile(os.path.join(d, n, "SKILL.md")))
    only = set(a.only.split(",")) if a.only else None
    rows, kept = [], 0
    today = datetime.date.today().isoformat()
    for name in sorted(os.listdir(a.source)):
        src = os.path.join(a.source, name, "SKILL.md")
        if not os.path.isfile(src) or (only and name not in only):
            continue
        text = open(src, encoding="utf-8", errors="replace").read()
        fm_name, desc = frontmatter(text)
        others = sorted(f for f in os.listdir(os.path.join(a.source, name)) if f != "SKILL.md")
        reason = None
        if not fm_name or not desc:
            reason = "no frontmatter name and description"
        elif len(text.encode()) > a.max_bytes:
            reason = "%d bytes > %d" % (len(text.encode()), a.max_bytes)
        elif name in shipped:
            reason = "a plugin the image installs ships a skill of this name"
        else:
            subject = domain_terms(fm_name + " " + desc)
            terms = domain_terms(text)
            if subject:
                reason = "domain-specific (its name or description names %s)" % ", ".join(subject[:4])
            elif len(terms) >= a.domain_terms:
                reason = "domain-specific (%d distinct domain terms in the body: %s, ...)" % (len(terms), ", ".join(terms[:5]))
            elif scrub(fm_name + "\n" + desc, names) != fm_name + "\n" + desc:
                reason = "about the source site (its name or description changes under the scrub)"
        if reason is None:
            refs = len(HOST_TOOL.findall(text))
            refs += sum(len(re.findall(r"(?<![A-Za-z0-9])" + re.escape(n) + r"(?![A-Za-z0-9])", text, re.I)) for n in names)
            for f in others:
                refs += len(re.findall(r"(?<![A-Za-z0-9_./-])" + re.escape(f) + r"(?![A-Za-z0-9_-])", text))
            if refs > a.host_refs:
                reason = "host-bound: %d references to the source host (paths, its names, the skill's own files not copied)" % refs
        out = None
        if reason is None:
            out = scrub(text, names)
            left = leaks(out, names)
            if left:
                reason = "still carries %s after scrubbing" % ", ".join(left)
        rows.append([name, reason, others, len(text.encode()), out])
    # the dependency rule: a kept skill that names a skill of the library that is not kept (and that no plugin ships) leans
    # on an absent instruction; dropped, and the check repeats until no kept skill does
    library = set(r[0] for r in rows)
    changed = True
    while changed:
        changed = False
        kept_names = set(r[0] for r in rows if r[1] is None)
        absent = library - kept_names - shipped
        for r in rows:
            if r[1] is not None:
                continue
            deps = sorted(d for d in absent if d != r[0] and re.search(r"(?<![A-Za-z0-9_-])" + re.escape(d) + r"(?![A-Za-z0-9_-])", r[4] or ""))
            if deps:
                r[1] = "depends on a skill not shipped: %s" % ", ".join(deps[:3]) + (", ..." if len(deps) > 3 else "")
                changed = True
    for name, reason, others, size, out in rows:
        if reason is None:
            kept += 1
            if not a.list:
                dst = os.path.join(a.dest, name, "SKILL.md")
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                note = "\n<!-- imported on %s by tools/import-skills.py from a native Claude Code instance's skill library; the source site's names, ids, hosts and paths are scrubbed to <placeholders>; its other files were not copied -->\n" % today
                with open(dst, "w", encoding="utf-8") as f:
                    f.write(out.rstrip("\n") + "\n" + note)
    width = max((len(r[0]) for r in rows), default=4)
    def family(reason):
        if "bytes > " in reason:
            return "over --max-bytes (%d)" % a.max_bytes
        return reason.split(":")[0].split(" (")[0]
    counts = {}
    for name, reason, others, size, out in rows:
        if reason is not None:
            counts[family(reason)] = counts.get(family(reason), 0) + 1
    lines = ["# Imported skills - the selection and its rule", "",
             "Source: one directory per skill with a SKILL.md. Rule: kept when the frontmatter has a name and a description, the file is at most %d bytes, "
             "the name and description name no domain term and the body fewer than %d distinct ones (the terms: %s), the name and description do not "
             "change under the scrub, at most %d references to the source host remain (paths under a home directory or ~/, scratch/ paths, the names "
             "list's words, the skill's own files that are not copied), no skill named in the body is itself unshipped, no plugin the image installs "
             "ships the name, and nothing leak-shaped survives the scrub (Slack ids, account ids, IPv4 addresses, private hostnames, e-mail addresses, "
             "credential shapes, home-directory paths, messaging chat ids, gist URLs, the names list). Run on %s." % (a.max_bytes, a.domain_terms, ", ".join(DOMAIN), a.host_refs, today),
             "", "Kept %d of %d skills. Dropped, by reason (the dropped skills' names are the source site's and are not listed):" % (kept, len(rows)), ""]
    lines += ["- %d %s" % (n, fam) for fam, n in sorted(counts.items(), key=lambda kv: -kv[1])]
    lines += ["", "| kept skill | note | bytes |", "|---|---|---|"]
    for name, reason, others, size, out in rows:
        if reason is None:
            note = ("%d other file(s) of its directory not copied: %s" % (len(others), " ".join(others))) if others else "SKILL.md alone"
            lines.append("| %s | %s | %d |" % (name, note.replace("|", "/"), size))
    report = "\n".join(lines) + "\n"
    if a.report:
        os.makedirs(os.path.dirname(a.report) or ".", exist_ok=True)
        open(a.report, "w", encoding="utf-8").write(report)
    for name, reason, others, size, out in rows:
        print("%-*s  %-7s  %s" % (width, name, "kept" if reason is None else "dropped", reason or ("%d other file(s) not copied" % len(others) if others else "SKILL.md alone")))
    print("kept %d of %d%s" % (kept, len(rows), " (listed, nothing written)" if a.list else " -> %s" % a.dest))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
