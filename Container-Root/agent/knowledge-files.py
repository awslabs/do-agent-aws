#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""The default knowledge where a headless loop fire can read it: a copy on the /wd volume, a skill, a CLAUDE.md pointer.

A loop fire (headless `claude -p`, working directory /wd) may Read and Grep but is denied MCP tools and every Bash call
it is not allowed, so the Hindsight banks the seed fills (and the hooks' one bank, coding-agent::<project>) never reach
it: measured, a fire with the knowledge only in Hindsight scored like a fire with none. What a fire does use is a file
it can grep, named in the CLAUDE.md it reads at start: the section says where the records are and how to look one up
(a Grep on the topic, or the skill's index of ids and titles), and the fire follows the records that apply. This step
keeps the copy, the skill and the section in step with the image, idempotently:
  files        the shipped packs (a pack file with its manifest beside it: the example pack gpu-cluster-basics of
               /opt/loglearner-packs, records with id, title, text, category, tags, confidence and source) and the
               seed's general banks (this harness's conventions, starter rules) copied to KNOWLEDGE_DIR/defaults
               (default /wd/knowledge/defaults); a file the image no longer ships is removed from that directory,
               nothing else in KNOWLEDGE_DIR is touched
  skill        CLAUDE_CONFIG_DIR/skills/aws-defaults-knowledge/SKILL.md: how to look a record up, and every record's
               id and title by category or bank
  pointer      a marked section in CLAUDE_CONFIG_DIR/CLAUDE.md naming the copy, the grep, /agent/recall.sh and the
               skill, and sending a diagnosis, an audit or a count to the team's earlier result first (the records,
               recall and every package loaded under KNOWLEDGE_DIR), set beside the agent's own in the answer, and
               having the agent read the artifact itself when that takes seconds (crane config for an image); the
               user's other lines are never changed, and a damaged section (one marker, or out of order) is left alone
               with a message
AGENT_KNOWLEDGE=false takes all three away: the copy (the packs and manifests in KNOWLEDGE_DIR/defaults, a directory
this step owns; nothing else in KNOWLEDGE_DIR is touched), the skill and the pointer - with the copy left on disk a
fire still found it (Read and Grep are allowed in a fire). Prints one line per step; exits 0 unless an argument is
wrong. Usage: knowledge-files.py [sync|status|verify]
The copy is trusted - the section tells every fire to follow it - and it lies on the volume fires work in, so its
bytes are checked against the image's: at every start (sync) and, through the SessionStart hook claude-settings-sync.sh
registers, before every Claude session (verify: each loop fire, each chat reply, the agent's pane). A file whose bytes
are not the image's is restored, a missing one re-created, a pack or manifest the image does not ship removed, and
each case is one line on stdout (the session's context, for verify) and in KNOWLEDGE_DIR/integrity.log. A change
the image itself made (a new pack version) is told apart by the digests of the last sync (KNOWLEDGE_DIR/.copy.sha256)
and reads "updated", not "restored". verify prints nothing when the copy is the image's. A link, a pipe or a directory
planted in the copy is replaced or reported, never followed or opened, and nothing outside the copy is written. When
KNOWLEDGE_DIR is itself a link, or resolves through a link below its top-level directory (a link at /wd itself, the
mount point above it, is the host's layout), every action refuses: nothing is written, read as the copy or removed
there, and the skill and the section are withdrawn (a session is not told to follow files this step cannot vouch for).
Settings: AGENT_KNOWLEDGE (true), KNOWLEDGE_DIR (/wd/knowledge; the copy is skipped when its parent does not exist,
as at image build), KNOWLEDGE_PACKS (space-separated pack files, default /opt/loglearner-packs/gpu-cluster-basics.jsonl
plus the /seed banks harness-knowledge and loglearner-rules; a file with a <name>.manifest.json beside it is a shipped
pack, the others are seed banks), CLAUDE_CONFIG_DIR (/home/agent/.claude).
"""
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
import time

ON = os.environ.get("AGENT_KNOWLEDGE", "true") == "true"
KNOWLEDGE_DIR = os.environ.get("KNOWLEDGE_DIR", "/wd/knowledge")
COPY_DIR = os.path.join(KNOWLEDGE_DIR, "defaults")
CONFIG_DIR = os.environ.get("CLAUDE_CONFIG_DIR", "/home/agent/.claude")
PACKS = os.environ.get("KNOWLEDGE_PACKS", "/opt/loglearner-packs/gpu-cluster-basics.jsonl /seed/harness-knowledge.jsonl "
                       "/seed/loglearner-rules.jsonl").split()
SKILL_NAME = "aws-defaults-knowledge"
MARK_BEGIN = "<!-- do-agent-aws default knowledge: begin -->"
MARK_END = "<!-- do-agent-aws default knowledge: end -->"
STATE = os.path.join(KNOWLEDGE_DIR, ".copy.sha256")   # name -> sha256 of the bytes the last sync wrote
LOG = os.path.join(KNOWLEDGE_DIR, "integrity.log")


def write_if_changed(path, text):
    try:
        with open(path, encoding="utf-8") as f:
            if f.read() == text:
                return False
    except OSError:
        pass
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)
    return True


def records(path):
    """(id, title, group) per record: the pack schema (id, title, category) or the seed's (document_id, context)."""
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            if not line.strip():
                continue
            r = json.loads(line)
            if "document_id" in r:
                out.append((r["document_id"], (r.get("context") or r.get("content", "")[:80]).strip(), os.path.basename(path)[:-6]))
            else:
                out.append((r["id"], (r.get("title") or r.get("text", "")[:80]).strip(), "category " + (r.get("category") or "general")))
    return out


def manifest_of(path):
    """The manifest a shipped pack has beside it: <name>.manifest.json for <name>.jsonl (a seed bank has none)."""
    return path[:-len(".jsonl")] + ".manifest.json"


def shipped():
    return [p for p in PACKS if os.path.isfile(p)]


def skill_text(packs):
    recs = [(p, records(p)) for p in packs]
    total = sum(len(r) for _, r in recs)
    names = [os.path.basename(p)[:-len(".jsonl")] for p in packs if os.path.isfile(manifest_of(p))]
    example = ", ".join(r[0][0] for _, r in recs if r)
    lines = [
        "---",
        "name: %s" % SKILL_NAME,
        "description: The default knowledge shipped with do-agent-aws - %d records: this harness's own knowledge of AWS, "
        "Docker, Claude Code agent operations and git, its conventions and starter rules, plus the shipped knowledge "
        "packs (%s). Use it before a Dockerfile or an image build, a cluster or node change, an IAM, quota or capacity "
        "step, GPU, EFA or NCCL work, a training job, and before claiming a result." % (total, ", ".join(names) or "none"),
        "---",
        "",
        "# Default knowledge",
        "",
        "Generated from the shipped packs; do not edit by hand. One JSON object per line: a shipped pack's records have "
        "id, title, text, category, tags, confidence, source; the harness banks have document_id, content, context, tags.",
        "",
        "## How to look a record up",
        "",
        "1. Grep the copy on the working volume (allowed in headless fires, which run in /wd):",
        "   `grep -i '<keyword>' %s/*.jsonl` - try two or three keywords, read the matching lines." % COPY_DIR,
        "2. Ranked recall over every bank (the LogLearner bank and all Hindsight banks): `/agent/recall.sh \"<question>\"`.",
        "3. Apply the records that fit, read a record that says never or do not as a dead end to avoid, and cite the ids "
        "you used (for example %s)." % (example or "the record's id"),
        "",
        "The records are defaults: the goals file, the operator's instruction and the agent rules (AGENT_RULES.md) win.",
        "",
        "## Files",
        "",
    ]
    for p, r in recs:
        lines.append("- `%s/%s` - %d records" % (COPY_DIR, os.path.basename(p), len(r)))
    lines += ["", "## Index (id: title)"]
    for p, r in recs:
        groups = {}
        for rid, title, g in r:
            groups.setdefault(g, []).append((rid, title))
        for g in sorted(groups):
            lines += ["", "### %s (%s)" % (g, os.path.basename(p)), ""]
            lines += ["- `%s`: %s" % (rid, title) for rid, title in groups[g]]
    return "\n".join(lines) + "\n"


def pointer_text(packs):
    shipped_packs = [p for p in packs if os.path.isfile(manifest_of(p))]
    rest = [os.path.basename(p) for p in packs if p not in shipped_packs]
    lines = [MARK_BEGIN,
             "## Default knowledge (the shipped packs and the harness conventions; the goals, the operator and "
             "AGENT_RULES.md win)",
             "Before a Dockerfile or image build, a cluster or node change, an IAM, quota or capacity step, GPU, EFA or "
             "NCCL work, a training job, or a claim that something is verified, look the shipped records up and follow "
             "the ones that apply; cite the ids you used."]
    for p in shipped_packs:
        name = os.path.basename(p)
        lines.append("- `grep -i '<keyword>' %s/%s` - %d records of the shipped pack %s, one per line (id, title, text, "
                     "category, tags, confidence, source), or read that file; its version (name, version, sha256) is "
                     "`%s/%s`." % (COPY_DIR, name, len(records(p)), name[:-len(".jsonl")], COPY_DIR,
                                   os.path.basename(manifest_of(p))))
    if rest:
        lines.append("- `grep -i '<keyword>' %s/{%s}` - this harness's knowledge of AWS, Docker, Claude Code and git, its "
                     "conventions and starter rules." % (COPY_DIR, ",".join(rest)))
    lines += ["- These are files: a headless loop fire reaches them with Read and Grep whatever its permission options "
              "(the shipped fire skips the permission checks; the safe value allows only /agent/slack-post.sh, "
              "/agent/recall.sh and /agent/bus-answer.sh).",
              "- `/agent/recall.sh \"<question>\"` ranks matches across the LogLearner bank and every Hindsight bank.",
              "- The skill `%s` lists every record's id and title." % SKILL_NAME,
              "- Before a diagnosis, an audit or a count, look for the team's own earlier result on the same question: "
              "these records, `/agent/recall.sh`, and every shared package loaded beside the copy "
              "(`grep -ril '<the error text, the flag or the component>' %s`). When one exists, put it beside yours in "
              "the answer - the same, or different and why (a newer tree, another set of files, a fix a later one "
              "replaced) - with its path and date." % KNOWLEDGE_DIR,
              "- A record is a lead, not a measurement: when the artifact itself can be read in seconds - an image's "
              "config (`crane config <image>:<tag>`, no docker daemon needed), a node's allocatable, the file in the "
              "tree - read it and give both.",
              MARK_END]
    return "\n".join(lines) + "\n"


def sha(data):
    return hashlib.sha256(data).hexdigest()


# The copy lies where anyone with the volume can write, and this step runs as root before every session: it reads
# no link and opens no pipe there, writes through a fresh temporary name (never a path someone planted) and a rename,
# keeps its own directory a real one, and names a file it did not ship only in a safe spelling.
NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


def shown(name):
    """A file name as it may appear in a note (the session's context): [A-Za-z0-9._-] kept, the rest '?', 80 at most."""
    return re.sub(r"[^A-Za-z0-9._-]", "?", name)[:80]


def read_regular(path):
    """The bytes of the regular file at path; None when nothing is there or something else is (a link, a pipe, a
    directory)."""
    try:
        fd = os.open(path, os.O_RDONLY | NOFOLLOW | getattr(os, "O_NONBLOCK", 0))
    except OSError:
        return None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None
        chunks = []
        while True:
            b = os.read(fd, 1 << 20)
            if not b:
                return b"".join(chunks)
            chunks.append(b)
    finally:
        os.close(fd)


def write_bytes(path, data):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp.", dir=d)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)   # a link at path is replaced, never written through
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def linked():
    """Where KNOWLEDGE_DIR really is, when it is itself a link or a link below its top-level directory takes it
    elsewhere; None otherwise. The top-level directory above it (/wd, the volume's mount point) may be a link: that is
    the host's or image's layout - unless it is KNOWLEDGE_DIR itself (a one-component path)."""
    path = os.path.abspath(KNOWLEDGE_DIR)
    if os.path.islink(path):
        return os.path.realpath(path)
    parts = path.strip("/").split("/")
    top = os.path.realpath("/" + parts[0])
    real = os.path.realpath(path)
    return real if real != os.path.join(top, *parts[1:]) else None


def own_dir(notes):
    """COPY_DIR is this step's: a link there (wherever it points) or a file is removed - the target untouched - so no
    write or removal of this step lands outside the copy."""
    if os.path.islink(COPY_DIR) or (os.path.lexists(COPY_DIR) and not os.path.isdir(COPY_DIR)):
        os.remove(COPY_DIR)
        notes.append("replaced %s: it was a link or a file, not the copy's directory" % os.path.basename(COPY_DIR))


def log(notes, source):
    """One line per case in KNOWLEDGE_DIR/integrity.log - outside the copy, and like it closed to Claude's writes."""
    if not notes:
        return
    try:
        if os.path.islink(LOG):
            os.remove(LOG)   # a link where the log goes: removed, its target untouched
        fd = os.open(LOG, os.O_WRONLY | os.O_APPEND | os.O_CREAT | NOFOLLOW, 0o644)
        with os.fdopen(fd, "a", encoding="utf-8") as f:
            for n in notes:
                f.write("%s %s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), source, n))
    except OSError:
        pass


def check_files(packs):
    """Put the copy back to the image's bytes: each shipped pack and the manifest beside it. Returns (counts, notes),
    notes one line per file that was not the image's (a first copy is no news), or (None, []) where the copy is not
    made (no KNOWLEDGE_DIR parent: the image build)."""
    parent = os.path.dirname(KNOWLEDGE_DIR.rstrip("/")) or "/"
    if not os.path.isdir(parent):
        return None, []
    try:
        last = json.loads(read_regular(STATE) or b"{}")
    except ValueError:
        last = {}
    last = last if isinstance(last, dict) else {}
    counts = dict(written=0, updated=0, restored=0, unchanged=0, pruned=0)
    notes, now = [], {}
    own_dir(notes)
    existed = os.path.isdir(COPY_DIR) or bool(last)   # a copy was made before: a missing file is news
    names = set()
    # each pack, and its manifest (the pack's version record) when one ships beside it
    for p in packs + [m for m in (q[:-len(".jsonl")] + ".manifest.json" for q in packs) if os.path.isfile(m)]:
        name = os.path.basename(p)
        names.add(name)
        with open(p, "rb") as f:
            want = f.read()
        now[name] = sha(want)
        dst = os.path.join(COPY_DIR, name)
        have = read_regular(dst)
        if have == want:
            counts["unchanged"] += 1
            continue
        if have is None:
            counts["written"] += 1
            if os.path.lexists(dst):
                notes.append("replaced %s: it was a link or another non-file, not the image's file" % name)
            elif existed:
                notes.append("re-created %s: it was missing from the copy" % name)
        elif last.get(name) == sha(have):
            counts["updated"] += 1
            notes.append("updated %s to the image's new bytes (sha256 %s)" % (name, now[name][:12]))
        else:
            counts["restored"] += 1
            notes.append("restored %s: its bytes (sha256 %s) were not the image's (%s)" % (name, sha(have)[:12], now[name][:12]))
        write_bytes(dst, want)
    for old in sorted(os.listdir(COPY_DIR)) if os.path.isdir(COPY_DIR) else []:
        if (old.endswith(".jsonl") or old.endswith(".manifest.json")) and old not in names:
            path = os.path.join(COPY_DIR, old)
            if os.path.isdir(path) and not os.path.islink(path):
                notes.append("left %s: a directory, not a pack" % shown(old))
                continue
            os.remove(path)
            counts["pruned"] += 1
            notes.append("removed %s: the image does not ship it" % shown(old))
    if now != last:
        write_bytes(STATE, (json.dumps(now, indent=1, sort_keys=True) + "\n").encode())
    return counts, notes


def sync_files(packs):
    counts, notes = check_files(packs)
    if counts is None:
        return ["files: skipped - %s does not exist here (the copy is made at the first start, on the /wd volume)"
                % (os.path.dirname(KNOWLEDGE_DIR.rstrip("/")) or "/")]
    log(notes, "start")
    return ["files: %s %s" % (COPY_DIR, " ".join("%s=%d" % kv for kv in counts.items()))] + ["files: " + n for n in notes]


def prune_files():
    """AGENT_KNOWLEDGE=false: remove the copy - every pack and manifest in COPY_DIR (the harness owns that directory;
    sync_files prunes there too) - and COPY_DIR itself once empty; nothing else in KNOWLEDGE_DIR is touched."""
    if os.path.islink(COPY_DIR):
        os.remove(COPY_DIR)   # the link only: what it points to is not the copy
        return "files: %s was a link - removed, its target untouched (AGENT_KNOWLEDGE=false)" % COPY_DIR
    if not os.path.isdir(COPY_DIR):
        return "files: absent (AGENT_KNOWLEDGE=false)"
    removed = 0
    for old in sorted(os.listdir(COPY_DIR)):
        path = os.path.join(COPY_DIR, old)
        if (old.endswith(".jsonl") or old.endswith(".manifest.json")) and not (os.path.isdir(path) and not os.path.islink(path)):
            os.remove(path)
            removed += 1
    if os.path.lexists(STATE):
        os.remove(STATE)   # the digests of a copy that is gone: a later copy is a first one again
    try:
        os.rmdir(COPY_DIR)
        gone = ", the directory too"
    except OSError:
        gone = "; other files there kept"
    return "files: %s removed %d (AGENT_KNOWLEDGE=false)%s" % (COPY_DIR, removed, gone)


def sync_pointer(text, why="AGENT_KNOWLEDGE=false"):
    """Write (text) or remove (empty text) our marked section of CLAUDE.md; every other line stays as it is."""
    md = os.path.join(CONFIG_DIR, "CLAUDE.md")
    try:
        with open(md, encoding="utf-8") as f:
            cur = f.read()
    except OSError:
        cur = ""
    nb, ne = cur.count(MARK_BEGIN), cur.count(MARK_END)
    if nb == 1 and ne == 1 and cur.index(MARK_BEGIN) < cur.index(MARK_END):
        head, rest = cur.split(MARK_BEGIN, 1)
        tail = rest.split(MARK_END, 1)[1]
        tail = tail[1:] if tail.startswith("\n") else tail
        if text:
            new = head + text + tail
        else:
            new = (head[:-1] if head.endswith("\n\n") else head) + tail  # also the blank line added before it
    elif nb == 0 and ne == 0:
        if not text:
            return "pointer: absent (%s)" % why
        new = (cur if not cur or cur.endswith("\n") else cur + "\n") + ("\n" if cur else "") + text
    else:
        return ("pointer: %s has %d begin and %d end markers of the default knowledge section (or they are out of "
                "order) - left alone; fix or remove them by hand" % (md, nb, ne))
    if new == cur:
        return "pointer: %s unchanged" % md
    mode = os.stat(md).st_mode & 0o777 if os.path.exists(md) else 0o644
    write_if_changed(md, new)
    os.chmod(md, mode)
    return "pointer: %s %s" % (md, "written" if text else "removed (%s)" % why)


def sync_skill(text, why="AGENT_KNOWLEDGE=false"):
    path = os.path.join(CONFIG_DIR, "skills", SKILL_NAME, "SKILL.md")
    if text is None:
        if os.path.exists(path):
            os.remove(path)
            try:
                os.rmdir(os.path.dirname(path))
            except OSError:
                pass
            return "skill: %s removed (%s)" % (path, why)
        return "skill: absent (%s)" % why
    return "skill: %s %s" % (path, "written" if write_if_changed(path, text) else "unchanged")


def main(argv):
    action = argv[0] if argv else "sync"
    if action not in ("sync", "status", "verify"):
        print(__doc__.split("\n\n")[0])
        return 2
    packs = shipped()
    if action == "status":
        print("knowledge: AGENT_KNOWLEDGE=%s packs=%s copy=%s" % ("true" if ON else "false", " ".join(packs) or "none", COPY_DIR))
        return 0
    real = linked()
    if real:
        # a link in KNOWLEDGE_DIR's path: what is there is not this step's to write, prune or vouch for
        why = "KNOWLEDGE_DIR %s resolves to %s through a link" % (KNOWLEDGE_DIR, real)
        lines = ["refused - %s: nothing is written, read as the copy or removed there, and no session is pointed at it;"
                 " set KNOWLEDGE_DIR to a real directory" % why]
        for step in (lambda: sync_skill(None, "the copy cannot be made"), lambda: sync_pointer("", "the copy cannot be made")):
            try:
                lines.append(step())
            except OSError as e:
                lines.append("a step failed: %s: %s" % (type(e).__name__, e))
        pre = "do-agent-aws knowledge check: " if action == "verify" else "knowledge: "
        print(pre + ("" if action == "verify" else "files: ") + lines[0])
        for line in lines[1:]:
            print(pre + line)
        return 0
    if action == "verify":
        # before a session (the SessionStart hook): silent unless something was not the image's
        try:
            if not ON:
                if os.path.isdir(COPY_DIR) and any(n.endswith((".jsonl", ".manifest.json")) for n in os.listdir(COPY_DIR)):
                    note = prune_files()
                    log([note], "session")
                    print("do-agent-aws knowledge check: " + note)
                return 0
            _, notes = check_files(packs) if packs else (None, [])
            log(notes, "session")
            for n in notes:
                print("do-agent-aws knowledge check: " + n)
        except (OSError, ValueError) as e:
            print("do-agent-aws knowledge check failed: %s: %s" % (type(e).__name__, e))
        return 0
    if not ON:
        for step in (prune_files, lambda: sync_skill(None), lambda: sync_pointer("")):
            try:
                print("knowledge: " + step())
            except OSError as e:
                print("knowledge: a step failed: %s: %s" % (type(e).__name__, e))
        return 0
    if not packs:
        print("knowledge: no shipped pack found (%s) - nothing delivered" % " ".join(PACKS))
        return 0
    for step in (lambda: sync_files(packs), lambda: [sync_skill(skill_text(packs))], lambda: [sync_pointer(pointer_text(packs))]):
        try:
            for line in step():
                print("knowledge: " + line)
        except (OSError, ValueError) as e:
            print("knowledge: a step failed: %s: %s" % (type(e).__name__, e))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
