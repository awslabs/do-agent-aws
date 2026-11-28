#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Default knowledge seed for the hindsight memory - post the curated banks under /seed into the
# self-hosted hindsight-api, once.
#
# Called by /startup.sh (detached, after the harness UIs start) when UI_START=true, UI_HINDSIGHT is
# not false and HINDSIGHT_SEED is not false; it can also be run by hand inside the container at any
# time. The seed is the shipped content of /seed (README.md there: what is in it and how it was
# curated): banks.json names the banks and their missions, and <bank>.jsonl carries one memory per
# line - {"document_id", "content", "context", "tags"} - with STABLE document ids, which is what
# makes every run idempotent: hindsight updates a document in place when the same id is posted
# again, so a re-run or a changed seed updates instead of duplicating. Hindsight refuses two items
# with the same document_id in one async batch (parallel workers would race), so a duplicate id
# within a file is dropped with a warning and never posted twice.
#
# Runs once per /wd volume: the LAST step writes a stamp (the sha256 of the seed content, the
# per-bank counts, the time), and a later run with the same seed content exits at once. A changed
# seed (new image) re-seeds; --force re-seeds regardless. The stamp is written only after every
# batch was accepted, so an interrupted or failed seed is retried on the next start.
#
# Settings (all overridable via environment; HINDSIGHT_SEED is declared in .env and passed through
# by run.sh, the compose template and the kubernetes deployment):
#   HINDSIGHT_SEED        - true|false (default true); false = do nothing, exit 0
#   HINDSIGHT_SEED_API    - the API (default http://127.0.0.1:${UI_PORT_HINDSIGHT_API:-8888})
#   HINDSIGHT_SEED_DIR    - the seed directory (default /seed)
#   HINDSIGHT_SEED_STAMP  - the stamp file (default /wd/hindsight-seed.stamp, on the /wd volume)
#   HINDSIGHT_SEED_WAIT   - seconds to wait for the API's /health (default 300)
#   HINDSIGHT_SEED_BATCH  - items per POST (default 20)
#   HINDSIGHT_SEED_EXTRACTION_WAIT - after the items are accepted, seconds to wait for the first extracted
#                           memories before the extraction is called FAILED (default 180; 0 = do not watch)
#   HINDSIGHT_SEED_COMPLETE_WAIT - after the first memory, how long to keep watching until EVERY accepted item is a
#                           document (default 1800), the state rewritten every HINDSIGHT_SEED_POLL seconds (default 15)
#   HINDSIGHT_API_LOG     - the memory API's log, read for the cause of a failing extraction (default
#                           ${UI_DIR:-/wd/ui}/hindsight-api.log)
#   HINDSIGHT_SEED_STATE  - the extraction state file the home page's memory note and ui-status.sh read
#                           (default ${UI_DIR:-/wd/ui}/hindsight-seed.state for the default stamp; another
#                           stamp gets its own, ${UI_DIR:-/wd/ui}/<stamp name>.state, so a second seed - another
#                           directory, another stamp - never overwrites the state the home page reports for
#                           the harness's own seed): state=accepted|extracting|complete|stalled|failed,
#                           documents=<have>/<accepted>, reason=<cause>
# Flags: --force (re-seed even when the stamp matches), --dry-run (validate and report, no
# network, no stamp), --status (print the stamp; exit 0 when seeded, 1 when not), -h.
#
# Exit 0 when seeded, already seeded, or disabled. Exit 1 with ONE plain stderr line naming the
# problem when the seed directory is missing or malformed, the API does not answer within the
# wait, or the API refuses a batch. Acceptance is not memory: the items are extracted afterwards
# with the LLM, and a memory API that cannot call it (no credentials, an unknown profile, no model
# access) keeps them pending for good while every status dot stays green. So after acceptance the
# seed WATCHES the first extraction and, when nothing is extracted within the window, says so loudly
# (stdout and stderr) with the cause read from the API's log, and records it in the state file - the
# exit status stays 0 (the seed did its part); the home page and ui-status.sh carry the state.

export HOME=${HOME:-/home/agent}
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

HINDSIGHT_SEED=${HINDSIGHT_SEED:-true}
HINDSIGHT_SEED_API=${HINDSIGHT_SEED_API:-http://127.0.0.1:${UI_PORT_HINDSIGHT_API:-8888}}
HINDSIGHT_SEED_DIR=${HINDSIGHT_SEED_DIR:-/seed}
HINDSIGHT_SEED_STAMP=${HINDSIGHT_SEED_STAMP:-/wd/hindsight-seed.stamp}
HINDSIGHT_SEED_WAIT=${HINDSIGHT_SEED_WAIT:-300}
HINDSIGHT_SEED_BATCH=${HINDSIGHT_SEED_BATCH:-20}
HINDSIGHT_SEED_EXTRACTION_WAIT=${HINDSIGHT_SEED_EXTRACTION_WAIT:-180}
HINDSIGHT_SEED_COMPLETE_WAIT=${HINDSIGHT_SEED_COMPLETE_WAIT:-1800}
HINDSIGHT_SEED_POLL=${HINDSIGHT_SEED_POLL:-15}
HINDSIGHT_API_LOG=${HINDSIGHT_API_LOG:-${UI_DIR:-/wd/ui}/hindsight-api.log}
# the state file follows the stamp: the default stamp's state is the file the home page reads; a seed with its own stamp
# (another seed directory, as a knowledge package's instructions do) writes <stamp name>.state next to it instead
if [ -z "${HINDSIGHT_SEED_STATE:-}" ]; then
	if [ "${HINDSIGHT_SEED_STAMP}" = "/wd/hindsight-seed.stamp" ]; then
		HINDSIGHT_SEED_STATE=${UI_DIR:-/wd/ui}/hindsight-seed.state
	else
		STAMP_NAME=$(basename "${HINDSIGHT_SEED_STAMP}"); STAMP_NAME=${STAMP_NAME%.stamp}
		HINDSIGHT_SEED_STATE=${UI_DIR:-/wd/ui}/${STAMP_NAME:-hindsight-seed}.state
	fi
fi

FORCE=false
DRY_RUN=false
STATUS=false
for ARG in "$@"; do
	case "${ARG}" in
		--force) FORCE=true ;;
		--dry-run) DRY_RUN=true ;;
		--status) STATUS=true ;;
		-h|--help)
			echo "Usage: $0 [--force] [--dry-run] [--status]"
			echo "Seed the hindsight memory at HINDSIGHT_SEED_API with the banks under HINDSIGHT_SEED_DIR (once per stamp)."
			exit 0
			;;
		*)
			echo "hindsight seed: unknown option ${ARG} (use -h)" >&2
			exit 1
			;;
	esac
done

if [ "${STATUS}" = "true" ]; then
	if [ -f "${HINDSIGHT_SEED_STAMP}" ]; then
		echo "hindsight seed: seeded (${HINDSIGHT_SEED_STAMP}):"
		sed 's/^/  /' "${HINDSIGHT_SEED_STAMP}"
		if [ -f "${HINDSIGHT_SEED_STATE}" ]; then
			echo "hindsight seed: extraction state (${HINDSIGHT_SEED_STATE}):"
			sed 's/^/  /' "${HINDSIGHT_SEED_STATE}"
		fi
		exit 0
	fi
	echo "hindsight seed: not seeded (no stamp at ${HINDSIGHT_SEED_STAMP})"
	exit 1
fi

if [ "${HINDSIGHT_SEED}" = "false" ]; then
	echo "hindsight seed: disabled (HINDSIGHT_SEED=false) - nothing posted"
	exit 0
fi

command -v python3 > /dev/null 2>&1 || { echo "hindsight seed: python3 not found (the image gets it from setup/install-comms.sh)" >&2; exit 1; }

export HINDSIGHT_SEED_API HINDSIGHT_SEED_DIR HINDSIGHT_SEED_STAMP HINDSIGHT_SEED_WAIT HINDSIGHT_SEED_BATCH FORCE DRY_RUN
export HINDSIGHT_SEED_EXTRACTION_WAIT HINDSIGHT_SEED_COMPLETE_WAIT HINDSIGHT_SEED_POLL HINDSIGHT_API_LOG HINDSIGHT_SEED_STATE
python3 - << 'PY'
import decimal, hashlib, json, os, re, sys, time, urllib.error, urllib.request

API = os.environ["HINDSIGHT_SEED_API"].rstrip("/")
SEED_DIR = os.environ["HINDSIGHT_SEED_DIR"]
STAMP = os.environ["HINDSIGHT_SEED_STAMP"]
WAIT = int(os.environ["HINDSIGHT_SEED_WAIT"])
BATCH = max(1, int(os.environ["HINDSIGHT_SEED_BATCH"]))
FORCE = os.environ["FORCE"] == "true"
DRY_RUN = os.environ["DRY_RUN"] == "true"


def die(msg):
    print("hindsight seed: " + msg, file=sys.stderr)
    sys.exit(1)


def say(msg):
    print("hindsight seed: " + msg, flush=True)


# --- the extraction watch (see the header): acceptance is not memory ---
STATE_FILE = os.environ["HINDSIGHT_SEED_STATE"]
EXTRACTION_WAIT = int(os.environ["HINDSIGHT_SEED_EXTRACTION_WAIT"])
COMPLETE_WAIT = int(os.environ["HINDSIGHT_SEED_COMPLETE_WAIT"])
POLL = max(1, int(os.environ["HINDSIGHT_SEED_POLL"]))
API_LOG = os.environ["HINDSIGHT_API_LOG"]

# what the memory API's log says when extraction cannot happen -> the cause in the user's words
# The memory API calls Bedrock through an LLM client library that forwards Bedrock's HTTP errors as
# `<Class>: BedrockException - {"message": "..."}` lines - the MESSAGE TEXTS are what the log carries, not AWS
# error codes, so they are matched here case-insensitively (the codes too, for a log that has them)
CAUSES = [
    (r"(?i)ProfileNotFound|config profile \(.*\) could not be found",
     "the AWS profile named by AWS_PROFILE does not exist in the credentials the container sees (a mounted ~/.aws, or the copy the memory API runs with)"),
    (r"(?i)NoCredentialsError|Unable to locate credentials|NoCredentialProviders|could not load aws credentials|no credentials",
     "no AWS credentials reach the memory API (an instance role, AWS_* variables or a mounted ~/.aws)"),
    (r"(?i)security token included in the request is (expired|invalid)|ExpiredToken|InvalidClientTokenId|UnrecognizedClientException|security token .* invalid|InvalidSignature",
     "the AWS credentials are expired or invalid"),
    (r"(?i)marked by provider as legacy|model is marked .*legacy",
     "the model HINDSIGHT_API_LLM_MODEL names is marked Legacy by its provider and Bedrock refuses it - choose a current model (docs/bedrock/README.md)"),
    (r"(?i)don.t have access to the model|do not have access to the model|model access.*(not|isn.t) (enabled|granted)",
     "model access is not enabled for this account on the model HINDSIGHT_API_LLM_MODEL names - request it in the Bedrock console (docs/bedrock/README.md)"),
    (r"(?i)on-demand throughput isn.t supported|on-demand throughput is not supported|inference profile.*(required|instead)",
     "the model needs an inference profile id (us.<model>) in HINDSIGHT_API_LLM_MODEL instead of the bare model id (docs/bedrock/README.md)"),
    (r"(?i)AccessDeniedException|not authorized to perform|access ?denied|PermissionDenied",
     "the credentials have no access to the Bedrock model (bedrock:InvokeModel on the model and its inference profile - an inference-profile ARN pasted into HINDSIGHT_API_LLM_MODEL needs the policy to cover that resource, the plain profile id usually works; docs/bedrock/README.md)"),
    (r"(?i)ResourceNotFoundException|model identifier is invalid|Could not resolve the foundation model|is not supported in this region",
     "the model is not available to this account or region (HINDSIGHT_API_LLM_MODEL, AWS_REGION; docs/bedrock/README.md)"),
    (r"EndpointConnectionError|Could not connect to the endpoint|Name or service not known|Connection refused|ConnectTimeout",
     "the memory API cannot reach the Bedrock endpoint (network, proxy or region)"),
    (r"ThrottlingException|Too many requests|TooManyRequests",
     "Bedrock is throttling the calls"),
]


def write_state(**kv):
    """The extraction state the home page's memory note and ui-status.sh read (key=value lines)."""
    kv["checked_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    try:
        os.makedirs(os.path.dirname(os.path.abspath(STATE_FILE)), exist_ok=True)
        with open(STATE_FILE + ".tmp", "w", encoding="utf-8") as f:
            f.write("".join(f"{k}={v}\n" for k, v in kv.items()))
        os.replace(STATE_FILE + ".tmp", STATE_FILE)
    except OSError as e:
        say(f"could not write the state file {STATE_FILE}: {e}")


def log_size():
    try:
        return os.path.getsize(API_LOG)
    except OSError:
        return 0


def diagnose(since):
    """The cause of a failing extraction from what the memory API logged SINCE this start (the log persists on
    /wd across restarts: an error of a run before the credentials were fixed must not be reported again) -
    (cause, log line) or (None, None)."""
    try:
        with open(API_LOG, "rb") as f:
            f.seek(0, os.SEEK_END)
            end = f.tell()
            start = since if since <= end else 0          # a smaller file was rotated: read it whole
            f.seek(max(start, end - 400_000))
            tail = f.read().decode("utf-8", errors="replace")
    except OSError:
        return None, None
    best = None
    unknown = None
    for line in reversed(tail.splitlines()):
        noisy = "http://" in line or "https://" in line or "&title=" in line or "%5B" in line
        matched = False
        for pattern, cause in CAUSES:
            m = re.search(pattern, line)
            if not m:
                continue
            matched = True
            # the excerpt starts at the matched error, not at whatever boilerplate the line begins with; a line
            # that is a URL (the LLM client's "file a bug" link carries the error name URL-encoded) is kept only
            # when no plain line names the error
            excerpt = clip(line, m.start())
            if noisy:
                best = best or (cause, excerpt)
                continue
            return cause, excerpt
        # an error the list above does not know is still an error: nothing extracted AND the API logging errors is a
        # failure to report, with the line, not a "slow extraction"
        if not matched and not noisy and unknown is None and re.search(r"Error|Exception|ERROR|Traceback|litellm\.|BedrockException", line):
            unknown = ("the memory API is logging errors the seed does not recognise - read its log", clip(line, 0))
    return best or unknown or (None, None)


def clip(line, at, width=200):
    """Up to `width` characters of `line` from a little before `at`, cut at word boundaries."""
    start = max(0, at - 20)
    if start:
        sp = line.rfind(" ", 0, start)
        start = sp + 1 if sp >= 0 else start
    piece = line[start:start + width]
    if start + width < len(line):
        sp = piece.rfind(" ")
        if sp > width // 2:
            piece = piece[:sp]
    return piece.strip()


def shout(msg):
    """The seed runs detached with its output in its own log; a failing extraction is also written to the container's
    own log (pid 1's stdout, what `docker logs` shows) so it is seen without knowing where the seed log is."""
    say(msg)
    try:
        with open("/proc/1/fd/1", "w", encoding="utf-8") as f:
            f.write("hindsight seed: " + msg + "\n")
    except OSError:
        pass


def bank_stats(bank):
    status, stats = request("GET", f"/v1/default/banks/{urllib.request.quote(bank, safe='')}/stats", timeout=60)
    return int(stats.get("total_documents") or 0), int(stats.get("pending_operations") or 0), int(stats.get("failed_operations") or 0)


def totals(expected):
    docs = pending = failed = 0
    for bank in expected:
        d, p, f = bank_stats(bank)
        docs += d
        pending += p
        failed += f
    return docs, pending, failed


def watch_extraction(expected):
    """After acceptance: wait (bounded) for the FIRST extracted memory - nothing within the window = the user hears
    why - then keep watching (bounded) until EVERY accepted item is a document, the state rewritten each poll.
    expected: {bank: the documents the API should end up with}."""
    want = sum(expected.values())
    if EXTRACTION_WAIT <= 0:
        write_state(state="accepted", documents=f"0/{want}", pending="?", failed="?", watch="off")
        return
    write_state(state="accepted", documents=f"0/{want}", pending="?", failed="?")
    log_since = log_size()
    started = time.time()
    first_deadline = started + EXTRACTION_WAIT
    complete_deadline = first_deadline + COMPLETE_WAIT
    docs = pending = failed = 0
    # "drained": nothing pending and operations failed, on TWO consecutive reads - the stats expose pending and failed
    # counts only (no processing counter, failures of every run), and right after a post the API may not have queued
    # the operations yet, so one read saying 0 pending with old failures must not read as a dead queue
    drained_reads = 0
    while True:
        try:
            docs, pending, failed = totals(expected)
        except (urllib.error.URLError, OSError, ValueError) as e:
            write_state(state="unknown", documents=f"?/{want}", reason=f"could not read the bank stats: {e}")
            say(f"extraction watch: could not read the bank stats ({e}) - state unknown")
            return
        drained_reads = drained_reads + 1 if (pending == 0 and failed > 0) else 0
        drained = drained_reads >= 2
        now = time.time()
        if docs >= want:
            # every accepted item is a document; what may still be pending is the API's own housekeeping
            # (consolidation, maintenance), not extraction
            write_state(state="complete", documents=f"{docs}/{want}", pending=pending, failed=failed)
            say(f"extraction complete: {docs}/{want} documents after {int(now - started)}s" + (f" ({pending} API operations of its own still pending)" if pending else ""))
            return
        if docs == 0:
            # nothing yet: a drained queue with failures will never deliver; otherwise wait for the first memory
            if drained or now >= first_deadline:
                break
            time.sleep(min(POLL, 5))
            continue
        # some memories: keep watching until every one is there, the state visible meanwhile
        write_state(state="extracting", documents=f"{docs}/{want}", pending=pending, failed=failed)
        if drained:
            # the queue drained short of the accepted count: the missing documents are the failed operations
            cause, excerpt = diagnose(log_since)
            reason = cause or f"{failed} extraction operations failed and nothing is pending - the memory API's log has the error"
            write_state(state="failed", documents=f"{docs}/{want}", pending=0, failed=failed, reason=reason, excerpt=excerpt or "", log=API_LOG)
            shout(f"WARNING - {docs} of {want} accepted items were extracted and {failed} operations FAILED, nothing pending: {reason}."
                  + (f" Log line: {excerpt}." if excerpt else "") + f" The API log is {API_LOG}; a restart re-posts what the stamp accepted")
            return
        if now >= complete_deadline:
            say(f"extraction running: {docs}/{want} documents after {int(now - started)}s, {pending} pending, {failed} failed - the watch ends here; the home page and /stats show the progress")
            return
        time.sleep(POLL)
    cause, excerpt = diagnose(log_since)
    if drained:
        # nothing pending and every operation failed: nothing more is extracted until a restart re-posts the items,
        # whatever the cause - a throttled run whose queue drained is over, not slow
        reason = (f"{cause}; every extraction operation failed ({failed} of {failed}) and nothing is pending" if cause
                  else f"every extraction operation failed ({failed} of {failed}) and nothing is pending - the memory API's log has the error")
        write_state(state="failed", documents=f"0/{want}", pending=0, failed=failed, reason=reason, excerpt=excerpt or "", log=API_LOG)
        shout(f"WARNING - {want} items were accepted but NO memory was extracted: {reason}." + (f" Log line: {excerpt}." if excerpt else "")
              + f" Fix it and restart (./stop.sh && ./run.sh): the restart re-posts what the stamp accepted. See docs/manual/aws.md 'AWS credentials' and 'Bedrock connectivity'; the API log is {API_LOG}")
        return
    if cause and "throttling" in cause:
        write_state(state="stalled", documents=f"0/{want}", pending=pending, failed=failed, reason=f"{cause} - extraction is slow, not broken", log=API_LOG)
        say(f"extraction stalled: no memory extracted within {EXTRACTION_WAIT}s ({pending} pending, {failed} failed) - {cause}; extraction is slow, not broken")
        return
    if cause:
        write_state(state="failed", documents=f"0/{want}", pending=pending, failed=failed, reason=cause, excerpt=excerpt or "", log=API_LOG)
        msg = (f"WARNING - {want} items were accepted but NO memory was extracted within {EXTRACTION_WAIT}s ({pending} operations pending, "
               f"{failed} failed). The memory API cannot use Bedrock: {cause}." + (f" Log line: {excerpt}." if excerpt else "") + " Fix it and restart (./stop.sh && ./run.sh): "
               f"the restart re-posts what the stamp accepted. See docs/manual/aws.md 'AWS credentials' and 'Bedrock connectivity'; the API log is {API_LOG}")
    else:
        write_state(state="stalled", documents=f"0/{want}", pending=pending, failed=failed,
                    reason=f"no memory extracted within {EXTRACTION_WAIT}s and no error logged by the memory API since this start ({API_LOG})", log=API_LOG)
        msg = (f"WARNING - {want} items were accepted but NO memory was extracted within {EXTRACTION_WAIT}s ({pending} operations pending, "
               f"{failed} failed) and the memory API logged no error since this start ({API_LOG}) - extraction may be slow; the home page's memory line and /stats show the progress")
    shout(msg)


# --- 1. the seed content: banks.json + one jsonl per bank, validated, duplicates dropped ---
banks_file = os.path.join(SEED_DIR, "banks.json")
if not os.path.isfile(banks_file):
    die(f"no seed at {SEED_DIR} (missing {banks_file}) - set HINDSIGHT_SEED_DIR to the seed directory or HINDSIGHT_SEED=false to opt out")
try:
    with open(banks_file, encoding="utf-8") as f:
        banks = json.load(f)
except ValueError as e:
    die(f"{banks_file} is not valid JSON: {e}")
if not isinstance(banks, dict) or not banks:
    die(f"{banks_file} must map bank ids to {{name, mission}} objects")

digest = hashlib.sha256()
plan = {}  # bank -> list of items
for bank in sorted(banks):
    meta = banks[bank]
    if not isinstance(meta, dict) or not meta.get("name"):
        die(f"{banks_file}: bank '{bank}' needs at least a name")
    path = os.path.join(SEED_DIR, f"{bank}.jsonl")
    if not os.path.isfile(path):
        die(f"bank '{bank}' is named in {banks_file} but {path} is missing")
    seen = set()
    items = []
    dropped = 0
    with open(path, "rb") as f:
        raw = f.read()
    digest.update(bank.encode() + b"\0" + raw + b"\0")
    for n, line in enumerate(raw.decode("utf-8", errors="replace").splitlines(), 1):
        if not line.strip():
            continue
        try:
            it = json.loads(line)
        except ValueError as e:
            die(f"{path}:{n}: not valid JSON ({e})")
        if not isinstance(it, dict) or not it.get("document_id") or not it.get("content"):
            die(f"{path}:{n}: every item needs a document_id and content")
        if it["document_id"] in seen:
            print(f"hindsight seed: WARNING {path}:{n}: duplicate document_id '{it['document_id']}' dropped (hindsight refuses duplicate ids in one batch)", file=sys.stderr)
            dropped += 1
            continue
        seen.add(it["document_id"])
        item = {"document_id": it["document_id"], "content": it["content"]}
        if it.get("context"):
            item["context"] = it["context"]
        if isinstance(it.get("tags"), list) and it["tags"]:
            item["tags"] = [str(t) for t in it["tags"]]
        if it.get("timestamp"):
            item["timestamp"] = it["timestamp"]
        if isinstance(it.get("metadata"), dict) and it["metadata"]:
            # forwarded as given, no reshaping: a record's class/layer/admission/correction fields reach the memory
            # (the knowledge lanes read them back from Hindsight; before this they were dropped here)
            # - except their types: the memory API takes string values only and refuses the whole batch with HTTP 422
            # for any other, so a boolean becomes "true"/"false", a number its decimal text, a list or an object its
            # JSON text, and a null is dropped; a string is sent as it is. The seed files keep their JSON types: their
            # other readers parse them as JSON.
            metadata = {}
            for key, value in it["metadata"].items():
                if value is None:
                    continue
                if isinstance(value, bool):
                    value = "true" if value else "false"
                elif isinstance(value, (int, float)):
                    value = format(decimal.Decimal(repr(value)), "f")
                elif not isinstance(value, str):
                    value = json.dumps(value, sort_keys=True)
                metadata[str(key)] = value
            if metadata:
                item["metadata"] = metadata
        items.append(item)
    plan[bank] = (items, dropped)
digest.update(json.dumps(banks, sort_keys=True).encode())
seed_sha = digest.hexdigest()
total = sum(len(v[0]) for v in plan.values())
for bank, (items, dropped) in plan.items():
    batches = (len(items) + BATCH - 1) // BATCH
    say(f"bank {bank}: {len(items)} items in {batches} batch(es)" + (f", {dropped} duplicate id(s) dropped" if dropped else ""))
say(f"seed {SEED_DIR}: {total} items across {len(plan)} banks, sha256 {seed_sha[:16]}...")

# --- 2. the stamp: same content already seeded -> nothing to do, PROVIDED the banks are still there ---
# (the stamp lives on /wd, the banks in the memory database: with ephemeral agent state the database
# can be recreated under a surviving stamp, and the seed must then run again - checked after the API
# answers, below)
STAMPED = False
if os.path.isfile(STAMP) and not FORCE:
    with open(STAMP, encoding="utf-8") as f:
        stamp = dict(l.rstrip("\n").split("=", 1) for l in f if "=" in l)
    if stamp.get("sha256") == seed_sha:
        STAMPED = True
    else:
        say(f"seed content changed since the stamp ({STAMP}) - re-seeding (stable ids update in place)")

if DRY_RUN:
    say("dry run - nothing posted, no stamp written" + (" (stamp matches this seed)" if STAMPED else ""))
    sys.exit(0)


# --- 3. the API ---
def request(method, path, body=None, timeout=120):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, method=method, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        payload = r.read()
        return r.status, (json.loads(payload) if payload else {})


deadline = time.time() + WAIT
while True:
    try:
        status, health = request("GET", "/health", timeout=5)
        if status == 200 and health.get("status") == "healthy":
            break
    except (urllib.error.URLError, OSError, ValueError):
        pass
    if time.time() >= deadline:
        die(f"hindsight-api at {API} did not answer /health within {WAIT}s - is UI_HINDSIGHT on and /agent/ui-start.sh done?")
    time.sleep(2)
say(f"hindsight-api healthy at {API}")

if STAMPED:
    try:
        status, listing = request("GET", "/v1/default/banks?limit=200", timeout=30)
        present = {b.get("bank_id") for b in listing.get("banks", [])}
    except (urllib.error.URLError, OSError, ValueError) as e:
        die(f"could not list the banks at {API} to check the stamp: {e}")
    missing = [b for b in plan if b not in present]
    if missing:
        say(f"stamp {STAMP} matches this seed but bank(s) {', '.join(missing)} are gone from the API (recreated database?) - re-seeding")
    else:
        # the stamp records ACCEPTANCE; extraction is asynchronous and can fail for good (no model access,
        # a wrong profile - every retain failed and the store stayed empty while the stamp said "seeded").
        # Compare what the API holds with what the stamp says was accepted, per bank: fewer documents with
        # nothing pending any more means the extraction never finished - re-seed (stable ids: an update);
        # fewer documents with operations still pending is an extraction in progress - leave it alone.
        short, running = [], []
        for bank in plan:
            try:
                status, stats = request("GET", f"/v1/default/banks/{urllib.request.quote(bank, safe='')}/stats", timeout=60)
            except (urllib.error.URLError, OSError, ValueError) as e:
                die(f"could not read /stats of bank '{bank}' at {API} to check the stamp: {e}")
            have = int(stats.get("total_documents") or 0)
            want = int(stamp.get(f"bank:{bank}", "0") or 0)
            pending = int(stats.get("pending_operations") or 0)
            if have >= want:
                continue
            (running if pending > 0 else short).append(f"{bank} {have}/{want}" + (f" ({pending} pending)" if pending else ""))
        if not short:
            note = f"; extraction still running: {', '.join(running)}" if running else " with their documents"
            say(f"already seeded (stamp {STAMP}, {stamp.get('seeded_at', '?')}; banks {', '.join(sorted(plan))} present{note}) - nothing posted; use --force to re-seed")
            # the extraction state of THIS start: complete at once when every bank holds its documents, otherwise
            # watched - a restart with the credentials still broken must say so again, not stay quiet
            watch_extraction({bank: int(stamp.get(f"bank:{bank}", "0") or 0) for bank in plan})
            sys.exit(0)
        say(f"stamp {STAMP} matches this seed but the API holds fewer documents than were accepted and nothing is pending ({'; '.join(short)}) - the extraction did not finish; re-seeding (stable ids update in place)")

# --- 4. banks, then the items in batches (async: extraction runs server-side) ---
counts = {}
for bank, (items, _) in plan.items():
    meta = banks[bank]
    body = {"name": meta["name"]}
    if meta.get("mission"):
        body["mission"] = meta["mission"]
    try:
        request("PUT", f"/v1/default/banks/{urllib.request.quote(bank, safe='')}", body)
    except urllib.error.HTTPError as e:
        die(f"creating bank '{bank}' failed: HTTP {e.code} {e.read()[:300]!r}")
    except (urllib.error.URLError, OSError) as e:
        die(f"creating bank '{bank}' failed: {e}")
    posted = 0
    for i in range(0, len(items), BATCH):
        chunk = items[i:i + BATCH]
        batch_no = i // BATCH + 1
        # a transient failure (connection reset, 5xx while the API is busy) is retried with a short
        # backoff; a 4xx is the API refusing the content and is final - either way one failed batch
        # ends the run WITHOUT a stamp, so the next start retries the whole seed (stable ids make
        # the already-accepted batches an update, not a duplicate)
        for attempt in range(1, 4):
            try:
                request("POST", f"/v1/default/banks/{urllib.request.quote(bank, safe='')}/memories", {"items": chunk, "async": True})
                break
            except urllib.error.HTTPError as e:
                detail = e.read()[:300]
                if e.code < 500 or attempt == 3:
                    die(f"bank '{bank}' batch {batch_no} refused: HTTP {e.code} {detail!r}")
                say(f"bank {bank} batch {batch_no}: HTTP {e.code} on attempt {attempt}, retrying")
            except (urllib.error.URLError, OSError) as e:
                if attempt == 3:
                    die(f"bank '{bank}' batch {batch_no} failed after {attempt} attempts: {e}")
                say(f"bank {bank} batch {batch_no}: {e} on attempt {attempt}, retrying")
            time.sleep(2 * attempt)
        posted += len(chunk)
    counts[bank] = posted
    say(f"bank {bank}: {posted} items accepted (queued for extraction; the stamp records acceptance, /stats shows extraction)")

# --- 5. the stamp, LAST: only a complete seed has one ---
os.makedirs(os.path.dirname(os.path.abspath(STAMP)), exist_ok=True)
lines = [
    f"seeded_at={time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}",
    f"api={API}",
    f"seed_dir={SEED_DIR}",
    f"sha256={seed_sha}",
    f"items={sum(counts.values())}",
] + [f"bank:{bank}={n}" for bank, n in counts.items()]
with open(STAMP + ".tmp", "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
os.replace(STAMP + ".tmp", STAMP)
say(f"done - {sum(counts.values())} items into {len(counts)} banks; stamp {STAMP}")

# --- 6. the extraction watch: acceptance is not memory (see the header) ---
watch_extraction(counts)
PY
