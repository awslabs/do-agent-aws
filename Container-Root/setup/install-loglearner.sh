#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

echo ""
echo "Installing LogLearner (vendored dashboard + loglearner package) ..."

# LogLearner (github.com/dmvevents/loglearning, MIT) is vendored into the image at /opt/loglearner as
# its gated MINIMAL RUNTIME: dashboard/ (the read-only session-corpus dashboard served as the
# "LogLearner dashboard" tile by /agent/ui-start.sh via /agent/loglearner-serve.sh, with its
# /api/tile.json status contract) and the loglearner/ package the dashboard imports (export gate,
# scrub core, the knowledge-pack loader `python3 -m loglearner.pack`, the rule-delivery hook). The
# full rule-MINING command of the upstream repository is not part of that runtime (it needs the
# embedding and de-duplication modules the gate leaves out), so the `loglearner` command installed
# here is the runtime's own surface, the pack loader. See /opt/loglearner/VENDORED.md for the
# artifact, what was left out, and how to refresh.
#
# The dashboard is stdlib-only by design (binds 127.0.0.1, GET-only). python3 is the apt interpreter
# that setup/install-comms.sh installs, so this script must run after it.
export LOGLEARNER_DIR=${LOGLEARNER_DIR:-/opt/loglearner}
# the build leaves these at their defaults; a test of this gate points them at its own directory, so a tree it plants
# can never repoint the image's command or write outside the test
LOGLEARNER_SCAN=${LOGLEARNER_SCAN:-/seed/scan.py}
LOGLEARNER_SCAN_OUT=${LOGLEARNER_SCAN_OUT:-/tmp/loglearner-scan.out}
LOGLEARNER_BIN=${LOGLEARNER_BIN:-/usr/local/bin/loglearner}

fail()
{
	echo "ERROR: loglearner: $1" >&2
	exit 1
}

command -v python3 > /dev/null 2>&1 || fail "python3 not found (setup/install-comms.sh installs it; run that first)"
[ -f "${LOGLEARNER_DIR}/dashboard/app.py" ] && [ -f "${LOGLEARNER_DIR}/dashboard/indexer.py" ] \
	|| fail "no vendored dashboard at ${LOGLEARNER_DIR}/dashboard (Container-Root/opt/loglearner is missing from the build context)"
[ -f "${LOGLEARNER_DIR}/LICENSE" ] || fail "the vendored tree must carry its LICENSE (MIT redistribution)"
[ -f "${LOGLEARNER_DIR}/loglearner/pack.py" ] || fail "no loglearner package (pack loader) at ${LOGLEARNER_DIR}/loglearner"

# Every vendored module must at least compile under THIS image's python (upstream targets 3.12;
# the base image ships 3.10 - a syntax drift upstream must fail the build, not the first tile probe)
python3 -m compileall -q "${LOGLEARNER_DIR}" || fail "a vendored module does not compile under $(python3 --version 2>&1)"

# ...and the modules the dashboard and the CLI import at startup must import
cd /tmp || exit 1
python3 - "${LOGLEARNER_DIR}" << 'EOF' || fail "import check failed (see above)"
import importlib, sys
sys.path.insert(0, sys.argv[1])
for m in ("loglearner.export_gate", "loglearner.scrub_core", "loglearner.pack", "loglearner.cli", "loglearner.recall", "loglearner.bank", "dashboard.indexer", "dashboard.app"):
    importlib.import_module(m)
    print(f"loglearner: import {m} ok")
EOF

# The vendored tree must carry no fleet-internal name and no home directory of the build host: the seed's privacy
# scan in tree mode (every source file, identifiers included; the term list is hashed) - a tree that does fails the
# BUILD here, not a grep after the fact. The fix is a scrubbed upstream release re-vendored with
# tools/vendor-loglearner.sh, never an
# edit of the vendored files.
python3 "${LOGLEARNER_SCAN}" --tree "${LOGLEARNER_DIR}" > "${LOGLEARNER_SCAN_OUT}" 2>&1 \
	|| { tail -25 "${LOGLEARNER_SCAN_OUT}"; fail "the vendored LogLearner tree carries a denylisted name or a home directory (the findings above, masked) - re-vendor a scrubbed release"; }
echo "loglearner: privacy scan over the vendored tree: $(tail -1 "${LOGLEARNER_SCAN_OUT}")"

# The command: the runtime's one entry point, `python3 -m loglearner.cli` - `recall "<query>"` (exit 0 hit /
# 1 none), `bank --json '<entry>'` (0 banked / 2 schema / 3 duplicate), and the pack loader's
# `ingest | verify | installed` passed through (AGENT-USAGE.md in the vendored tree)
mkdir -p "$(dirname "${LOGLEARNER_BIN}")"
cat > "${LOGLEARNER_BIN}" << EOF
#!/bin/bash
# loglearner - the LogLearner minimal runtime's command (vendored at ${LOGLEARNER_DIR}; MIT):
#   loglearner recall "<query>"                      search the installed banks (exit 0 hit, 1 none; --json)
#   loglearner bank --json '<entry>'                 append a verified rule to the global bank
#   loglearner ingest --pack <jsonl> --bank <bank>   load a knowledge pack (idempotent by id)
#   loglearner verify|installed ...                  the pack loader's other subcommands
# The dashboard is /agent/loglearner-serve.sh (the LogLearner dashboard tile); AGENT-USAGE.md explains the rest.
# State: the same tree the dashboard keeps under LOGLEARNER_STATE (/wd/loglearner by default), so recall
# reads the banks the dashboard loaded and a banked rule shows up on its Learnings tab.
LOGLEARNER_STATE=\${LOGLEARNER_STATE:-/wd/loglearner}
export LOGLEARNER_BANKS_DIR=\${LOGLEARNER_BANKS_DIR:-\${LOGLEARNER_STATE}/banks}
export INSTINCTS_JSON=\${INSTINCTS_JSON:-\${LOGLEARNER_BANKS_DIR}/global/instincts.jsonl}
export LOGLEARNER_LEARNINGS_DIR=\${LOGLEARNER_LEARNINGS_DIR:-\${LOGLEARNER_BANKS_DIR}/global}
export LOGLEARNER_UCB_DIR=\${LOGLEARNER_UCB_DIR:-\${LOGLEARNER_STATE}/output}
cd "${LOGLEARNER_DIR}" && exec python3 -m loglearner.cli "\$@"
EOF
chmod +x "${LOGLEARNER_BIN}"
# the two agent commands answer (the runtime's top-level --help exits 2 by upstream design: with no mining
# CLI present it prints the usage and says so - the subcommands' help is the check that means something)
"${LOGLEARNER_BIN}" recall --help > /dev/null 2>&1 || fail "${LOGLEARNER_BIN} recall --help does not exit 0"
"${LOGLEARNER_BIN}" bank --help > /dev/null 2>&1 || fail "${LOGLEARNER_BIN} bank --help does not exit 0"
"${LOGLEARNER_BIN}" verify --help > /dev/null 2>&1 || fail "${LOGLEARNER_BIN} verify --help (the pack loader pass-through) does not exit 0"
echo "loglearner: dashboard and CLI installed from ${LOGLEARNER_DIR} ($(python3 --version 2>&1))"
