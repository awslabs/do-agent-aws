#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Comms UI - start the communication-engine operator dashboard.
#
# Opt-in: set COMMS_UI_ENABLED=true in .env (see docs/manual/channels.md "Comms UI" and docs/comms/README.md);
# startup.sh then calls this script at container start. It can also be run manually inside the
# container at any time. The dashboard renders the severity-ordered attention queue
# (engine_lost -> in_flight -> edited_after_response -> staged -> unanswered) over the engine's
# sqlite journal (every viewer connection is opened mode=ro). A SECOND, independent gate -
# COMMS_UI_WRITE_ENABLED, shipped true in .env - adds the engine's write surface: composing
# there STAGES a draft into the outbox, and only an explicit human click on that exact staged
# text sends it (the engine's outbox ladder: durable, deduped, read-back-proven). The agent
# never auto-sends; discard is terminal and kept. Per-channel policy still binds (reply_policy
# defaults to never = deny), and in demo mode the send goes to the credential-free fake
# adapter - fully offline. Set COMMS_UI_WRITE_ENABLED=false for the strictly read-only viewer:
# the engine's send layer is then never even imported (AST-checked by its own test suite).
#
# First run: when ${COMMS_DIR}/settings.json does not exist it is generated from the engine's
# settings.example.json with ONLY the credential-free fake adapter instance kept (an instance
# with unresolved env: auth references makes the engine refuse to start - by design). When
# COMMS_DEMO_SEED=true and no journal exists yet, one read-only scheduler cycle seeds the fake
# adapter with the engine's demo message so the dashboard renders content out of the box.
# Later starts leave settings.json alone, with one exception: with the write gate on, a file
# that is still exactly a default an earlier start generated is regenerated as the current
# default. That covers the read-only defaults (the demo channel at reply_policy 'never': every
# start before the write surface, and any start with COMMS_UI_WRITE_ENABLED off), so a
# container upgraded across the write surface gets its compose form, and the composable
# defaults of earlier versions, whose demo channel polled every 15 s. A file that differs from
# every generated default was edited and is never rewritten or widened; when it leaves no
# channel composable, one line names the setting and where to change it in the comms UI.
# Watching real channels is a deliberate, separate step: the operator replaces settings.json
# with their own, holding env: references to their own tokens (docs/comms/README.md) - the
# demo seed only touches adapters that expose a dry-run seed() hook, which only the fake does.
#
# Engine state (settings.json, state/journal.db, state/messages.db with cursors) lives under
# COMMS_DIR=/wd/comms so it survives container replacement, same as /wd/ui and /wd/slack.
#
# Listen address: the engine's own scripts/dashboard-serve.sh pins 127.0.0.1, which is right on
# a bare host but unreachable through the docker port publish (a loopback bind inside the
# container network namespace never sees the docker-proxy). This script launches streamlit with
# the exact same flags as dashboard-serve.sh and only the address made container-aware - the
# same resolution ui-start.sh uses: in-container default 0.0.0.0 with exposure controlled by
# the 127.0.0.1 host-side publish (UI_BIND_HOST in .env). Set COMMS_UI_LISTEN_HOST=127.0.0.1
# when running the Container-Root scripts outside a container.

export HOME=${HOME:-/home/agent}
export PATH="${HOME}/.local/bin:/usr/local/bin:${PATH}"

COMMS_HOME=${COMMS_HOME:-/opt/comms}
COMMS_PYTHON=${COMMS_PYTHON:-/opt/comms-venv/bin/python}  # streamlit's own Python 3.12 environment (setup/install-comms.sh)
COMMS_DIR=${COMMS_DIR:-/wd/comms}
COMMS_UI_PORT=${COMMS_UI_PORT:-8502}
# Behind the home proxy (UI_HOME=true, no direct publishes) the dashboard binds 127.0.0.1 like every
# other backend (ui-start.sh UI_BACKEND_LISTEN_HOST): a neighbour container on the same docker
# network must not reach it. With the proxy off or the direct publishes opted in it binds the
# container's interfaces again, for docker-proxy.
if [ -z "${COMMS_UI_LISTEN_HOST}" ]; then
	if [ "${UI_HOME:-true}" = "true" ] && [ "${UI_PUBLISH_DIRECT_PORTS:-false}" != "true" ]; then
		COMMS_UI_LISTEN_HOST=127.0.0.1
	else
		COMMS_UI_LISTEN_HOST=${UI_LISTEN_HOST:-0.0.0.0}
	fi
fi
# URL path the dashboard serves under (streamlit --server.baseUrlPath). Empty = at / (the
# pre-home behavior); .env sets "comms" when the home proxy carries the dashboard at
# /comms/ through the single published port (docs/manual/ui.md "Home page and reverse proxy").
COMMS_UI_BASE_PATH=${COMMS_UI_BASE_PATH:-}
COMMS_UI_BASE_ARGS=""
if [ -n "${COMMS_UI_BASE_PATH}" ]; then
	COMMS_UI_BASE_ARGS="--server.baseUrlPath ${COMMS_UI_BASE_PATH}"
fi
COMMS_DEMO_SEED=${COMMS_DEMO_SEED:-true}
# Default matches the shipped .env (write surface on). The engine refuses any value other than
# true/false by name, so pass it through verbatim rather than normalizing a typo into one of
# the two states here.
COMMS_UI_WRITE_ENABLED=${COMMS_UI_WRITE_ENABLED:-true}

if [ ! -f "${COMMS_HOME}/scripts/dashboard.py" ]; then
	echo "comms-ui: engine not installed under ${COMMS_HOME} (run setup/install-comms.sh)"
	exit 1
fi

mkdir -p "${COMMS_DIR}" 2>/dev/null || COMMS_DIR=/tmp/comms
mkdir -p "${COMMS_DIR}"
COMMS_SETTINGS=${COMMS_SETTINGS:-${COMMS_DIR}/settings.json}

# A pid is trusted only when its command line matches the dashboard it claims to be:
# pidfiles live on the /wd volume and survive container recreation, while pids are
# namespace-local, so after a restart a stale pidfile can point at an unrelated recycled pid.
pid_is_comms()
{
	PID=$1
	[ -n "${PID}" ] && [ -d "/proc/${PID}" ] && tr '\0' ' ' < "/proc/${PID}/cmdline" 2>/dev/null | grep -q "scripts/dashboard.py"
}

PID_FILE=${COMMS_DIR:?}/ui.pid
if [ -f "${PID_FILE}" ]; then
	if pid_is_comms "$(cat ${PID_FILE})"; then
		echo "comms-ui: already running (pid $(cat ${PID_FILE}))"
		exit 0
	fi
	rm -f "${PID_FILE:?}"
fi

# settings.json: generated on the first start; afterwards only an unmodified read-only
# default is regenerated, and only with the write gate on (see the header)
COMMS_HOME="${COMMS_HOME}" COMMS_SETTINGS="${COMMS_SETTINGS}" \
COMMS_UI_WRITE_ENABLED="${COMMS_UI_WRITE_ENABLED}" python3 - << 'EOF' || exit 1
import json, os, pathlib, sys
home = pathlib.Path(os.environ["COMMS_HOME"])
out = pathlib.Path(os.environ["COMMS_SETTINGS"])
write_gate = os.environ.get("COMMS_UI_WRITE_ENABLED") == "true"
example = json.loads((home / "settings.example.json").read_text())

# Every generated file opens with NOTE_HEAD. NOTE_V1 and NOTE_V2 are the whole notes that
# earlier versions of this script wrote - the read-only viewer (60d75cc) and the write surface
# up to this version (c93d826 on: 'never' whenever the write gate was off at the first start).
# They stay verbatim: an unmodified older default is recognized by its content.
NOTE_HEAD = ("Generated by /agent/comms-ui-start.sh with only the credential-free fake "
             "adapter instance kept, so the dashboard works out of the box. To watch real "
             "channels, replace this file following settings.example.json in "
             + str(home) + " and docs/comms/README.md - auth values are env: references "
             "to YOUR tokens; never put literal credentials in this file.")
NOTE_V1 = NOTE_HEAD
NOTE_V2 = NOTE_HEAD + (" Channels are generated at reply_policy 'staged' (composable, "
                       "click-gated) when COMMS_UI_WRITE_ENABLED=true at first start, "
                       "'never' (read-only) otherwise; this file is generated once - edit "
                       "it to change policies later.")
NOTE_STAGED = NOTE_HEAD + (" Generated with COMMS_UI_WRITE_ENABLED=true, so the demo channel "
                           "is at reply_policy 'staged' (composable; a draft still sends "
                           "only on your click). Edit this file to change policies; an "
                           "edited file is never rewritten.")
NOTE_NEVER = NOTE_HEAD + (" Generated with COMMS_UI_WRITE_ENABLED off, so the demo channel is "
                          "at reply_policy 'never' (read-only). While the file is exactly as "
                          "generated, a start with the write gate on regenerates it at "
                          "'staged'; an edited file is never rewritten.")
# The demo channel's poll interval in a generated file. The example gives the fake channel
# 15 s, and the engine keeps polling at the fastest channel's interval while an ask is unanswered
# (the seeded demo question is one), so 15 s meant a watcher cycle every 15 s until someone
# answered it; at 60 s that is one cycle a minute. Older defaults keep the example's value.
DEMO_POLL_S = 60


def generated(note, staged, poll_s=None):
    # a fresh copy of the example's fake instances on every call
    instances = [i for i in json.loads(json.dumps(example["instances"]))
                 if i.get("adapter") == "fake"]
    for inst in instances:
        for ch in inst.get("channels", []):
            if staged:
                # The demo channel is promoted to 'staged' ONLY when the write gate is on, so
                # the offline write cycle (compose -> staged -> human click -> fake-adapter
                # delivery) is demoable out of the box. 'staged' never auto-sends - a draft
                # still needs the explicit click - and this touches only the credential-free
                # fake adapter; a real channel keeps requiring the operator's own
                # settings.json AND tokens.
                ch["reply_policy"] = "staged"
            if poll_s is not None:
                ch["poll_interval_s"] = poll_s
    return {
        "_note": note,
        "engine": {
            "state_dir": "state",
            "channels_dir": str(home / "channels"),
            # store/journal/outbox are set explicitly: the engine's defaults for journal and
            # outbox resolve the already-resolved state_dir against the base dir a second
            # time when the config path is relative (doubling the path); explicit values
            # resolve once
            "store": "state/messages.db",
            "journal": "state/journal.db",
            "outbox": "state/outbox.db",
        },
        "instances": instances,
    }


def write(settings):
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_name(out.name + ".tmp")
    tmp.write_text(json.dumps(settings, indent=2) + "\n")
    os.replace(tmp, out)


if not out.is_file():
    print("comms-ui: generating %s from %s (fake adapter only)"
          % (out, home / "settings.example.json"))
    settings = generated(NOTE_STAGED if write_gate else NOTE_NEVER, write_gate, DEMO_POLL_S)
    write(settings)
    print("comms-ui: wrote %s (instances: %s)"
          % (out, [i["name"] for i in settings["instances"]]))
    sys.exit(0)
if not write_gate:
    sys.exit(0)    # no write surface, so there is no compose form to restore
try:
    current = json.loads(out.read_text())
except ValueError:
    sys.exit(0)    # not JSON: the engine's refusal below names the file
# The defaults earlier starts generated, exactly as they wrote them: read-only (60d75cc; the
# write gate off at the first start, before this version or with it), and composable at the
# example's 15 s (c93d826 .. 3defadd with the write gate on)
read_only = [generated(NOTE_V1, False), generated(NOTE_V2, False),
             generated(NOTE_NEVER, False, DEMO_POLL_S)]
if current in read_only or current == generated(NOTE_V2, True):
    if current in read_only:
        why = "the demo channel at reply_policy 'never', so the dashboard had no compose form"
    else:
        why = ("the demo channel polled every %s s"
               % current["instances"][0]["channels"][0].get("poll_interval_s"))
    write(generated(NOTE_STAGED, True, DEMO_POLL_S))
    print("comms-ui: migrated %s - it was the unmodified default an earlier start generated "
          "(%s); regenerated as the current default: the demo channel at reply_policy 'staged' "
          "(a draft still sends only on your click), polled every %d s" % (out, why, DEMO_POLL_S))
    sys.exit(0)
# Edited: never rewritten or widened. When no channel can be composed to, name the setting.
# The rule is the engine's (scripts/dashboard_write.composable()): a compose target is a
# channel whose channel-scope policy is not 'never', on an instance whose adapter declares send.
sys.path.insert(0, str(home))
try:
    from core.config import load, load_adapter_class
    cfg = load(str(out))
except Exception:
    sys.exit(0)    # refused: the journal step below reports it
never, composable = [], False
for inst in cfg.instances:
    try:
        adapter = load_adapter_class(cfg.channels_dir, inst.adapter)(auth=inst.auth)
    except Exception:
        continue   # half-configured: the dashboard names it
    if not adapter.capabilities().get("send"):
        continue   # a read-only adapter (every shipped live one): no policy changes that
    for ch in inst.channels:
        policy = ch.policy()
        if (policy if isinstance(policy, str) else policy.get("channel", "never")) == "never":
            never.append("%s %s" % (inst.name, ch.id))
        else:
            composable = True
if never and not composable:
    print("comms-ui: %s was edited, so it is left as it is, and no channel can be composed "
          "to (reply_policy 'never' on %s); to compose from the dashboard, set reply_policy "
          "to staged in the comms UI under connections & monitored channels > edit monitored "
          "channel, then Apply" % (out, ", ".join(never)))
EOF

# Seed once: only when the demo gate is on AND no journal exists yet (first-run-empty).
# The journal path comes from the engine's own config resolution, so a user-supplied
# settings.json with different paths is honored. scheduler.py is read-only by construction
# (the engine's send layer is never imported - AST-checked by its tests); --seed-demo plants
# the demo message only in adapters exposing a dry-run seed() hook (the fake adapter).
JOURNAL_DB=$(COMMS_HOME="${COMMS_HOME}" COMMS_SETTINGS="${COMMS_SETTINGS}" python3 - << 'EOF' 2>/dev/null
import os, sys
sys.path.insert(0, os.environ["COMMS_HOME"])
from core.config import load
print(load(os.environ["COMMS_SETTINGS"]).journal_path)
EOF
)
if [ -z "${JOURNAL_DB}" ]; then
	echo "comms-ui: engine refused ${COMMS_SETTINGS} (unresolved env: reference or bad key?) - not starting"
	exit 1
fi
if [ "${COMMS_DEMO_SEED}" == "true" ] && [ ! -f "${JOURNAL_DB}" ]; then
	echo "comms-ui: seeding demo state (COMMS_DEMO_SEED=true, no journal yet)"
	python3 "${COMMS_HOME}/scripts/scheduler.py" --config "${COMMS_SETTINGS}" --once --seed-demo >> "${COMMS_DIR}/seed.log" 2>&1 \
		|| echo "comms-ui: demo seed failed (see ${COMMS_DIR}/seed.log); the dashboard will render an empty journal"
fi

# The & must apply to the setsid command alone (not a && list) so $! is the daemon
# itself; setsid detaches it into its own session/process group for comms-ui-stop.sh
(
	cd "${COMMS_HOME}" || exit 1
	# --client.toolbarMode viewer: Streamlit's own toolbar menu is gone from the page - its Deploy entry ("Streamlit Community
	# Cloud ... deploy unlimited public apps", a trial, "other platforms") is a public-publishing path inside the tool that
	# holds the Slack credentials; the app's own widgets are untouched. The setting travels with the image
	# here, as the flag and as Streamlit's environment variable for anything the app starts
	setsid nohup env COMMS_SETTINGS="${COMMS_SETTINGS}" \
		COMMS_UI_WRITE_ENABLED="${COMMS_UI_WRITE_ENABLED}" \
		STREAMLIT_CLIENT_TOOLBAR_MODE=viewer \
		"${COMMS_PYTHON}" -m streamlit run "${COMMS_HOME}/scripts/dashboard.py" \
		--server.address "${COMMS_UI_LISTEN_HOST}" \
		--server.port "${COMMS_UI_PORT}" \
		--server.headless true \
		--client.toolbarMode viewer \
		${COMMS_UI_BASE_ARGS} \
		--browser.gatherUsageStats false >> "${COMMS_DIR}/ui.log" 2>&1 &
	echo $! > "${PID_FILE}"
)
echo "comms-ui: started (pid $(cat ${PID_FILE}), log ${COMMS_DIR}/ui.log)"
if [ -n "${COMMS_UI_BASE_PATH}" ]; then
	echo "comms-ui: serving under /${COMMS_UI_BASE_PATH}/ - reach it through the home proxy port (docs/manual/ui.md \"Home page and reverse proxy\")"
else
	echo "comms-ui: reach it via ssh -L ${COMMS_UI_PORT}:127.0.0.1:${COMMS_UI_PORT} <host>, then http://localhost:${COMMS_UI_PORT}"
fi
