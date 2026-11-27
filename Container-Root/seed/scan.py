#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Secret + PII + scope scan and schema check for the Hindsight default knowledge seed.

Usage: python3 scan.py <dir-or-file>...     (stdlib only; runs on python >= 3.8)
       python3 scan.py --tree <dir>...       (every text file of a vendored source tree, see below)

Scans every *.jsonl, *.json and *.md under the given paths (never *.py - the denylist lives in
this file, and a checker must not flag its own source; see seed/README.md). Exit 0 and one
summary line `scan: <files> files, <items> items, 0 findings` when clean; exit 1 with one line
per finding (`path:line: <kind>: <masked excerpt>`) otherwise. Everything found is MASKED
(first 3 characters, then the length), so the report itself never carries a secret.

--tree: the same name and secret scan over EVERY text file of a directory or file (sources, tests,
configs, docs, a rendered page - identifiers included; no schema check; the seed's scope rule does
not apply, it is about the seed's knowledge content), for the trees this image vendors from other
repositories and for the repository's own user-facing pages: a fleet-internal identifier shipped
once inside the vendored LogLearner runtime, and a private repository's name once stood on the home
page. The vendored product's own hyphenated name and the repository owner's identities are not
findings in this mode (TREE_PUBLIC_NAMES), nor are the exact fixture values one named file carries on
purpose (FIXTURE_VALUES_SHA256: the fresh-deploy proof's planted control network, the vendored Loop
Deck's fixture act token). This mode also finds a home directory in the tree (HOME_PATH_RX: /home/<user>,
/Users/<user>, and the encoded -home-<user>- form of ~/.claude/projects/) - the build host's user and
layout, which a vendored LogLearner once shipped in its provenance table, its dashboard and its tests;
the image's own service accounts are not findings (TREE_IMAGE_USERS). install-loglearner.sh runs this
mode at build time, so a vendored tree carrying a denylisted name or a home directory fails the BUILD;
test17 runs it over the checkout's tree and README; test16 over the rendered home page;
tools/vendor-loglearner.sh on a fresh import. The summary line keeps the same shape (`items` is 0 in
this mode).

What it refuses (each category is proven on a planted fixture in seed/README.md):
  aws-access-key   AKIA/ASIA access key ids              account-id   bare 12-digit numbers
  arn              arn:aws... resource names             ipv4         any address but 127.0.0.1 / 0.0.0.0 / the IMDS endpoint
  hostname         ec2-*.compute.amazonaws.com, ip-N-N-N-N, *.internal, EC2/VPC resource ids
  slack-id         C/U/D/G/W + 8-10 uppercase alnum with a digit (channel, user, DM ids)
  email            any address except one on a domain that cannot exist on the public internet: the RFC 2606
                   documentation domains (example.com/net/org, their subdomains too) and the reserved TLDs .example, .invalid,
                   .localhost, .test and mDNS .local (RFC 6762) - the harness's own board account
                   agent@do-agent-aws.local is such a placeholder, a person's address never is
                   The scp-like SSH remote form of a repository address, git@host: (git@github.com:owner/repo, or
                   the bare prefix a URL rewrite strips), is a repository address, not a person's: the local part
                   is exactly git and a colon follows the host. Without the colon it stays a finding.
  token            xox[abpors]- Slack tokens, gh*_ / github_pat_ GitHub tokens, hf_ tokens,
                   sk- style API keys, Bearer values, KEY=value assignments of secret-named keys
  private-key      PEM private key blocks
  home-path        (tree mode only; proven in test17) a home directory of the build host: /home/<user>,
                   /Users/<user>, /var/home/<user>, C:\\Users\\<user>, in plain, doubled-slash, file://, relative or
                   JSON-escaped form, and Claude Code's encoded -home-<user>-, -Users-<user>-, C--Users-<user>-
                   directory names; the image's own service homes pass (TREE_IMAGE_USERS), look-alike tokens too
                   (HOME_PATH_RX's comment); tilde paths are not of this class (a recorded gap, same comment)
  denylist-name    customer and people names and handles the seed must never carry (kept as
                   sha256 digests; `scan.py --hash <term>` prints the digest for a new one)
  scope            per bank: a GENERAL bank (a *.jsonl that is not layer-*.jsonl; every bank the seed ships)
                   excludes the deep-research topics whole (SCOPE_EXCLUDED: DeepEP, NVSHMEM, NIXL, GDAKI, IBGDA,
                   EFA, NCCL, libfabric), as it always has; a LAYER bank (layer-*.jsonl, a bank of one layer of the
                   GPU stack added to a seed) and the seed's other files (banks.json, README.md) exclude
                   kernel-level internals only (DEPTH_EXCLUDED below: device-API calls, kernel signatures and
                   launches, PTX/SASS, work-queue, doorbell, fence and completion-queue internals, kernel tuning
                   identifiers) - the practical level of EFA, NCCL, libfabric, NVSHMEM, NIXL and DeepEP
                   (versions, env vars, modules, checks, failure signatures) is what a layer bank may hold
Schema (for *.jsonl): each line is one JSON object with non-empty string document_id, content
and context, a list of strings in tags; document_ids unique per file; at most 300 items in any one
.jsonl - one bank (MAX_ITEMS_PER_BANK).
"""
import hashlib
import json
import os
import re
import sys

ALLOWED_IPV4 = {"127.0.0.1", "0.0.0.0", "169.254.169.254"}  # loopback, wildcard, the EC2 IMDS link-local endpoint
ALLOWED_EMAIL_DOMAINS = {"example.com", "example.net", "example.org"}   # RFC 2606 documentation domains
PLACEHOLDER_EMAIL_TLDS = {"example", "invalid", "localhost", "test", "local"}  # reserved TLDs (RFC 2606, RFC 6761, RFC 6762): no mailbox can exist there


def placeholder_domain(domain):
    """an address domain on which no mailbox can exist: a documentation domain or a subdomain of one
    (user@docs.example.com), or a reserved top-level domain"""
    d = domain.lower().rstrip(".")
    return any(d == a or d.endswith("." + a) for a in ALLOWED_EMAIL_DOMAINS) or d.rsplit(".", 1)[-1] in PLACEHOLDER_EMAIL_TLDS


# The cap is per bank: a bank is the unit hindsight-seed.sh posts and the agent recalls from, so the cap bounds each
# bank's seeding time and recall noise. A cap on the whole seed would only count its banks.
MAX_ITEMS_PER_BANK = 300

# Customer names, people's names and handles seen in the fleet sources this seed was curated
# from. Matched case-insensitively on word boundaries ("ian" never matches "Italian").
# Customer and people names and handles, and the names of the internal knowledge stores the learnings were
# curated from, which the seed must never carry - stored as sha256 digests of the
# lower-cased term, so this file (which ships in the image) does not itself spell them out. A
# candidate is every word of a line, every pair of adjacent words, and every window of one to three parts
# of a compound word (split on hyphens, dots, underscores and camelCase, joined by '-', ' ' or nothing);
# `python3 scan.py --hash "<term>"` prints the digest to add here.
DENYLIST_SHA256 = {
    "a63007faf354282ef19744b59d10084aba7f1d67d09836170c806e7c474cebcd",  # the fleet-internal knowledge-base identifier the E2E run found shipped in a vendored tree
    "086eea3e91ea6a40a2ce0a021a4aba3d2b2b5b954cad3d7c2dfad791cf64d845",
    "08b55e9286d5ccdca3a970b081a96f66fa352482424f688e87a4042bbbbda2c4",
    "0dac71f1b7638e696c8576e8da42c0f3a99692d820e2ecf67a81c5eac4362d0e",
    "0dc8f791ab4b258e59ff9719187a5a707c0d0d653d3b61f8f42536dd866619d2",
    "130199c28bbfbff67494cf1fbad9a7754b96ada50781866eb70ccfe1852a2d0e",
    "1f29f2d29f02f2608eb72d45625ba3a851eda1ee2be1bda22427a584b787c722",
    "23086a806336dfe3871654dc2e7124dba1656e6d8d954e0a1f60e38625ba26fa",
    "4135aa9dc1b842a653dea846903ddb95bfb8c5a10c504a7fa16e10bc31d1fdf0",
    "44c2fc7b06e5b214c7e9febbf3c0a2487b83a8ed062c3a8df7f7617748a399db",
    "46a128501183dca9ae9979e8fd5a6869ff4363608e9181cb6eb3cea14b879b4a",
    "57c1631b6a57ad02674610e4575089166b971c6910f6d9653e7f57a7c11d417f",
    "59c5204e6b81208b951a9904da5db151ab46c956281617bc1e018a903c00eac7",
    "5b2b125a101b0017fce735b74144f3fbab4e86b77a2f2ad067181fac64136614",
    "65720717f9620c2d53e04d3c31e4e95057c139c475a91a272967acd437dcd92c",
    "67b51232d90eef075f44549519a721f50e31cfe58c93c9c30132291aac942601",
    "710ba0361a2bb92fbdb391492fe5684016d4af9ae3f109496525002c110d630b",
    "71c538095514b1e40a73d64f65854fe3d0dede4644e4f5a695035f2cb50933dd",
    "744ef866f1a1f589e7c5c0e955133379beac1a39746034c54ca891a8e60c0ba2",
    "74ca38ef9d349c49ad3142122715a73576ea0c6db952d7b845561a04207ece96",
    "8bea138166e0b85b3de7d06d9bcb30867d3fe5bf03dc9c9f9aa7651f7e3ec005",
    "96a4bc2602655473120fcc571ee3d8cfe5f8801f8038ccc06323d305e323331c",
    "9d0a22a86c586dd6279993dfeda0a23ae9f4665cf85838e492af892cbcfaa81a",
    "ab798432fbd0446e393dabaa4d0554c55ff0c2037c18b54d85e2e4f991cf406c",
    "ac05bfb29473338691247250ec243675a311695196328d7521357cf8acdc1d19",
    "ae43836a67619ea82ebfc28f7d8c6cc19c8ac5dfedc37463da6220f1bc5d8cca",
    "b410c112121ab1641f7c74cb9e7fe083ad5fc489008992b74fce4ba27ee04765",
    "b54a95127a4b573f41e335fdbd339dcc2208fbfb1ae0b6fab7599d6e2d6ec754",
    "b8a1a865903f26af4c87fb391696d510c40d35cc72941dd14e47f66243b6a02f",
    "c7ad2ac22b4500bd63f64e6809fa98fbd6fe130806c5d590887c12d30d05419e",
    "d36e5a1a7a3c45ce282d8aaaf7dd105ca8ef48e0bf10c8f855fdcca4c5029871",
    "e3e97e468af50c25e51e986d807c894d5b23fd8108f37f6fcf118d0e67d3b672",
    "e4a4342d4a2ea3ef8583ffbdae4ea77d77548aef744e64b08febf59b0e0b9b58",
    "e4baefb0d7cf32ecef42fcdc2cd316098883e268b8ccebfdd8d8a7f1041687d6",
    "edf882e2e9501fff1d8379fc96278f52efb74721a0f04bf6fbcaebd8de8536d8",
    "ee9021c84f33366bde80b75efa132836e47afa18b9ce58e8077f4c25d039666c",
    "6d1db31c7dd1afc94b667ef2363069973a3bae59c2f863bc9d37252f74ff49fa",  # the private fleet repository whose name stood in the Loop Deck tile text and the README (E2E run 1)
}
WORD_RX = re.compile(r"[A-Za-z][A-Za-z0-9-]*")
# Deep-research topics the brief excludes from a GENERAL bank - every bank the seed ships and any other bank that is
# not a layer bank (layer-*.jsonl).
SCOPE_EXCLUDED = re.compile("(?i)" + "|".join(["deepep", "nvshmem", "nixl", "gdaki", "ibgda", r"\befa\b", r"\bnccl\b", "libfabric"]))
# Kernel-level internals - the depth a LAYER bank stays out of ("no deep DeepEP/EFA research"). The general banks
# exclude whole topics (DeepEP, NVSHMEM, NIXL, EFA, NCCL, libfabric: SCOPE_EXCLUDED above); a layer bank (one layer
# of the GPU stack: frameworks, communication, network, nodes, Kubernetes, AWS policy) may carry the PRACTICAL level
# of exactly those, so the line is drawn at depth instead: device-API CALLS (case-sensitive, with a parenthesis),
# kernel signatures and launch syntax, PTX/SASS, memory-model primitives and transport internals. Env vars,
# diagnostic CLIs and protocol names pass.
DEPTH_EXCLUDED = re.compile(
    r"(?i:\bwarps?\b|\bwqes?\b|queue[- ]pairs?|\bqps?\b|doorbell|fi_writemsg|fi_atomic|"
    r"completion queue|\bcqs?\b|threadfence|memory fence|ld\.acquire|st\.release|\bptx\b|\bsass\b|"
    r"dispatch kernel|combine kernel|__global__|cuStreamWriteValue|internode_ll|"
    r"signal slot|red_add|st\.global|mbarrier|tma descriptor)"
    r"|\bnum_sms\b"
    r"|\bnvshmemx?_[a-z_]+\s*\(|\bnvshmemi_[a-z_]+"
    r"|\bibv_(?!devinfo\b|devices\b|rc_pingpong\b|ud_pingpong\b|srq_pingpong\b)[a-z_]+\s*\("
    r"|\b(?:mlx5dv|efadv|ibgda)_[a-z_]+\s*\(|<<<[^>]*>>>")

PATTERNS = [
    ("aws-access-key", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("account-id", re.compile(r"(?<![0-9A-Za-z._-])[0-9]{12}(?![0-9A-Za-z._-])")),
    ("arn", re.compile(r"\barn:aws[a-z-]*:[a-z0-9-]*:[a-z0-9-]*:[0-9]*:\S+")),
    ("ipv4", re.compile(r"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b")),
    ("hostname", re.compile(
        r"\bec2-[0-9-]+\.[a-z0-9-]+\.compute\.amazonaws\.com\b|\bip-[0-9]{1,3}-[0-9]{1,3}-[0-9]{1,3}-[0-9]{1,3}\b"
        r"|\b[a-z0-9-]+\.(?:[a-z0-9-]+\.)*internal\b|\b(?:i|vpc|subnet|sg|vol|ami|eni|cr)-[0-9a-f]{8,17}\b")),
    ("slack-id", re.compile(r"\b[CUDGW][0-9A-Z]{8,10}\b")),
    ("email", re.compile(r"\b[A-Za-z0-9._%+-]+@([A-Za-z0-9.-]+\.[A-Za-z]{2,})\b")),
    ("token", re.compile(
        r"\bxox[abpors]-[A-Za-z0-9-]{10,}|\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{20,}"
        r"|\bhf_[A-Za-z0-9]{20,}\b|\bsk-[A-Za-z0-9_-]{20,}\b|(?i:\bbearer\s+[A-Za-z0-9._~+/-]{20,}=*)"
        r"|(?i:\b(?:api[_-]?key|secret[_-]?key|secret|token|password|passwd)\b\s*[=:]\s*['\"]?[A-Za-z0-9+/_\-.]{8,})")),
    ("private-key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
]


def scope_rule(path):
    """The topic rule of one file: the general banks keep the topic exclusion, a layer bank (and the seed's index and
    README) only the depth line."""
    name = os.path.basename(path)
    if name.endswith(".jsonl") and not name.startswith("layer-"):
        return SCOPE_EXCLUDED
    return DEPTH_EXCLUDED


def mask(s):
    s = s.strip()
    return s[:3] + "..." + f"({len(s)} chars)"


# Product names the harness ships and names openly, written flat: the camelCase spelling of exactly these
# tokens is not windowed (LogLearner would otherwise split into the denylisted lane name); the hyphenated
# and the spaced spellings stay candidates - they are the lane's name, not the product's.
PUBLIC_NAMES = {"loglearner", "loglearning"}
# --tree mode only: names a vendored tree or the repository's own pages carry by construction and may spell, in
# any compound spelling (log-learner, log_learner, LogLearner...; compared flattened) - the vendored product's own
# name (in the seed its hyphenated form is a lane reference and stays a finding), and the repository's owner
# identities (the GitHub organisation and the committer, in links, licenses and attributions)
TREE_PUBLIC_NAMES = {"loglearner", "loglearning", "iankouls", "iankoulsaws", "dmvevents"}
# --tree mode only: a home directory in a shipped tree is the build host's - the user's name and the machine's layout
# leaking into a program's provenance, its tests or its page sources. The shapes: the path itself (/home/<user>,
# /Users/<user>, /var/home/<user>; also doubled or file:// slashes, the relative ../home/<user> with any chain of ../
# before it, and the JSON-escaped \/home\/<user>), the Windows path C:\Users\<user>, and Claude Code's
# project-directory encodings (-home-<user>-<repo>,
# -Users-<user>-<repo>, the Windows C--Users-<user>-<repo>: the directory names under ~/.claude/projects/). A user name
# may carry periods (first.last) but never ends in one, so a sentence ending in a home keeps its period out of the name.
# Not a finding: a path or an encoded form inside a longer token - a URL's /home/ page, a ${VAR}/home/x expansion, a
# --home-dir or -home-dir flag, a fix-home-page slug, -Users-only after a space (the encoded form is matched only after
# a path separator, a quote or a backtick, where ~/.claude/projects/ puts it). The image's own service accounts are not
# a host: their homes (TREE_IMAGE_USERS) are the container's layout and the README describes them - the agent user's
# /home/agent, which the README and quickstarts name throughout, and the memory API's /home/hindsight. The seed is
# not scanned for this: its records describe the container (the Hindsight data directory under the hindsight user's
# home).
# Known gaps, recorded rather than guessed. The encoded form at a line start, after a space (how `ls ~/.claude/projects`
# prints it) or after a backslash is not a finding - the cost of leaving -Users-only and -home-dir alone. Tilde paths
# (~/.claude/skills/<name>, ~/.claude/projects/<dir>/memory/<file>)
# name no user but did carry internal skill and memory-file names (8 of the 11 values the vendored 0.1.9 leaked); a
# class
# for them needs a look-alike study first, because vendored documentation legitimately names
# ~/.claude/settings.json-style
# install paths. The user name is whichever group matched (home_path_user).
_HOME_USER = r"([A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*)"      # a path's user: periods inside, never at the end
_ENCODED_USER = r"([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*)"     # an encoded name's user: the same, and no hyphen (the separator)
HOME_PATH_RX = re.compile(
    r"(?<![A-Za-z0-9_.}/~-])(?:file:)?/+(?:var/home|home|Users)/" + _HOME_USER       # /home/u, //home/u, file:///home/u, /var/home/u
    + r"|(?<![A-Za-z0-9_.}/-])(?:\\/)+(?:var\\/home|home|Users)\\/" + _HOME_USER   # the JSON-escaped \/home\/u
    + r"|(?<![A-Za-z0-9_./-])(?:~/|\./)?(?:\.\./)+(?:home|Users)/" + _HOME_USER       # ../home/u, ../../home/u, ./../home/u, ~/../home/u
    + r"|(?<![A-Za-z0-9_])[A-Za-z]:\\+Users\\+" + _HOME_USER                        # C:\Users\u (the backslash doubled or not)
    + r"|(?<=[/'\"`])-(?:home|Users)-" + _ENCODED_USER                               # -home-u-repo after a separator or a quote
    + r"|(?<![A-Za-z0-9_-])[A-Za-z]--Users-" + _ENCODED_USER)                         # C--Users-u-repo (the Windows encoding)
TREE_IMAGE_USERS = {"agent", "hindsight"}


def home_path_user(m):
    """The user name a HOME_PATH_RX match carries (the one group that matched)."""
    return next((g for g in m.groups() if g), "")
# --tree mode only: exact VALUES one named fixture file carries on purpose - never a shape, never another file. The
# fresh-deploy proof's custom-gateway control (tools/fresh-deploy-proof/proof.sh) needs a real, unroutable private
# subnet and its .254 gateway so the home proxy meets a genuine non-default gateway; those two addresses, and only
# those, pass in that file. They are kept as sha256 digests so this file spells no address; the same strings in any
# other file, and a third address in this one, stay findings. The vendored Loop Deck's action tests
# (opt/loop-deck/tests/test_deck_actions.py, byte-identical to the release, VENDORED.md) assign the act token of
# their own fixture deployment, a made-up value; that one assignment passes in that file, and any other token there
# or anywhere else stays a finding. A digest is the sha256 of the exact text the pattern matched, case kept
# (scan.py --hash lower-cases for the denylist, so it prints the right digest for an all-lower-case value only).
# Add a value only together with the file that carries it and the reason, as here.
FIXTURE_VALUES_SHA256 = {
    "tools/fresh-deploy-proof/proof.sh": {
        "e6677c4bb8aeb6d0060dc8fdb19c16f8d3cb6493c0b747ecf037cf4b9c941ac3",  # the control network (/24)
        "9656a2c7ca75d0577a3ccd3d66c8aacda94c1c25ea97683b0bfb37f0bf083fcc",  # its gateway (.254)
    },
    "opt/loop-deck/tests/test_deck_actions.py": {
        "b7850d7516e81f40a678e807865782f6181dc070176a35a57b3d2de3a44ba82a",  # the fixture deployment's act token
    },
}


def fixture_values(path, tree):
    """The digests of the exact values the file at path may carry (tree mode only; matched on the path's tail)."""
    if not tree:
        return set()
    norm = path.replace(os.sep, "/")
    for tail, digests in FIXTURE_VALUES_SHA256.items():
        if norm == tail or norm.endswith("/" + tail):
            return digests
    return set()


def _parts(token):
    """Split a token into its words: on hyphens, dots and underscores, and on camelCase boundaries."""
    spaced = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", token)
    return [p.lower() for p in re.split(r"[-._\s]+", spaced) if p]


def denylisted(line, tree=False):
    """Return the first denylisted term in the line: a word, an adjacent word pair, or any window of one to
    three consecutive parts of a compound token joined by '-', ' ' or nothing (fleet-mgr-learnings,
    kube-spoke-learnings.jsonl and FleetMgr all contain their two-part term). In tree mode the names of
    TREE_PUBLIC_NAMES are skipped whole."""
    tokens = WORD_RX.findall(line)
    words = [t.lower() for t in tokens]
    for i, t in enumerate(tokens):
        flat = re.sub(r"[-._]", "", t).lower()
        if tree and flat in TREE_PUBLIC_NAMES:
            continue
        candidates = [words[i]]
        # the adjacent pair (a snake_case identifier such as log_learner arrives as two tokens, the tokenizer
        # stopping at the underscore); in tree mode a pair that flattens to a public name is skipped too
        if i + 1 < len(words) and not (tree and re.sub(r"[-._]", "", words[i] + words[i + 1]) in TREE_PUBLIC_NAMES):
            candidates.append(f"{words[i]} {words[i + 1]}")
        parts = [] if flat in PUBLIC_NAMES else _parts(t)
        for n in (1, 2, 3):
            for j in range(len(parts) - n + 1):
                window = parts[j:j + n]
                candidates += ["-".join(window), " ".join(window), "".join(window)]
        for c in candidates:
            if hashlib.sha256(c.encode()).hexdigest() in DENYLIST_SHA256:
                return c
    return None


def scan_text(path, text, findings, tree=False):
    patterns = PATTERNS + [("scope", scope_rule(path))] + ([("home-path", HOME_PATH_RX)] if tree else [])
    fixtures = fixture_values(path, tree)
    for lineno, line in enumerate(text.splitlines(), 1):
        hit = denylisted(line, tree)
        if hit:
            findings.append(f"{path}:{lineno}: denylist-name: {mask(hit)}")
        for kind, rx in patterns:
            if tree and kind == "scope":
                continue   # the scope rule is about the SEED's knowledge content, not a vendored program's vocabulary
            for m in rx.finditer(line):
                hit = m.group(0)
                if kind == "ipv4" and hit in ALLOWED_IPV4:
                    continue
                if kind == "email" and placeholder_domain(m.group(1)):
                    continue
                if kind == "email" and hit.lower().startswith("git@") and line[m.end():m.end() + 1] == ":":
                    continue  # the scp-like SSH remote form git@host:... is a repository address, not a person's
                if fixtures and hashlib.sha256(hit.encode()).hexdigest() in fixtures:
                    continue  # an exact fixture value the named file carries on purpose (FIXTURE_VALUES_SHA256)
                if kind == "slack-id" and not (re.search(r"[0-9]", hit) and re.search(r"[A-Z]", hit[1:])):
                    continue  # an all-letters or all-digits run is a word or a number, not an id
                if kind == "home-path" and home_path_user(m) in TREE_IMAGE_USERS:
                    continue  # the image's own service account, not the build host's user (TREE_IMAGE_USERS)
                findings.append(f"{path}:{lineno}: {kind}: {mask(hit)}")


def check_jsonl(path, text, findings):
    seen = set()
    items = 0
    for lineno, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except ValueError as e:
            findings.append(f"{path}:{lineno}: schema: not JSON ({e})")
            continue
        if not isinstance(obj, dict):
            findings.append(f"{path}:{lineno}: schema: not an object")
            continue
        for key in ("document_id", "content", "context"):
            v = obj.get(key)
            if not isinstance(v, str) or not v.strip():
                findings.append(f"{path}:{lineno}: schema: {key} missing or empty")
        tags = obj.get("tags")
        if not isinstance(tags, list) or not tags or not all(isinstance(t, str) and t for t in tags):
            findings.append(f"{path}:{lineno}: schema: tags must be a non-empty list of strings")
        unknown = set(obj) - {"document_id", "content", "context", "tags", "timestamp", "metadata"}
        if unknown:
            findings.append(f"{path}:{lineno}: schema: unknown keys {sorted(unknown)}")
        did = obj.get("document_id")
        if isinstance(did, str):
            if did in seen:
                findings.append(f"{path}:{lineno}: schema: duplicate document_id {did}")
            seen.add(did)
            if not re.fullmatch(r"[a-z0-9][a-z0-9-]{2,63}", did):
                findings.append(f"{path}:{lineno}: schema: document_id must be kebab-case ascii: {did}")
        items += 1
    return items


# --tree mode: not scanned (binary or generated); everything else under the tree is read as text
TREE_SKIP_DIRS = {"__pycache__", ".git", "node_modules", ".pytest_cache", ".mypy_cache"}
TREE_SKIP_SUFFIXES = (".pyc", ".pyo", ".so", ".png", ".jpg", ".jpeg", ".gif", ".ico", ".woff", ".woff2", ".ttf",
                      ".zip", ".gz", ".tgz", ".tar", ".whl", ".pdf")


def collect(paths, tree=False):
    files = []
    for p in paths:
        if os.path.isdir(p):
            for root, dirs, names in os.walk(p):
                if tree:
                    dirs[:] = sorted(d for d in dirs if d not in TREE_SKIP_DIRS)
                for n in sorted(names):
                    if tree:
                        if not n.endswith(TREE_SKIP_SUFFIXES):
                            files.append(os.path.join(root, n))
                    elif n.endswith((".jsonl", ".json", ".md")):
                        files.append(os.path.join(root, n))
        elif os.path.isfile(p):
            files.append(p)
        else:
            print(f"scan: ERROR no such path: {p}", file=sys.stderr)
            sys.exit(2)
    return files


def main(argv):
    if len(argv) >= 3 and argv[1] == "--hash":
        # the digest to add to DENYLIST_SHA256 for a new term (lower-cased, single spaces)
        print(hashlib.sha256(" ".join(argv[2:]).strip().lower().encode()).hexdigest())
        return 0
    tree = len(argv) >= 2 and argv[1] == "--tree"
    paths = argv[2:] if tree else argv[1:]
    if not paths:
        print(__doc__)
        return 2
    files = collect(paths, tree=tree)
    if not files:
        print("scan: ERROR nothing to scan (an empty scan is a hard error, not a clean pass)", file=sys.stderr)
        return 2
    findings = []
    items = 0
    for path in files:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
        scan_text(path, text, findings, tree=tree)
        if path.endswith(".jsonl") and not tree:
            n = check_jsonl(path, text, findings)
            items += n
            if n > MAX_ITEMS_PER_BANK:
                findings.append(f"{path}: schema: {n} items in one bank exceeds the per-bank cap of {MAX_ITEMS_PER_BANK}")
    shown = findings if len(findings) <= 40 else findings[:40] + [f"... and {len(findings) - 40} more findings"]
    for line in shown:
        print(line)
    print(f"scan: {len(files)} files, {items} items, {len(findings)} findings" + (f" (tree mode: every text file under {', '.join(paths)})" if tree else ""))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
