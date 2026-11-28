#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

echo ""
echo "Installing communication engine (comms UI) ..."

# The communication engine (github.com/dmvevents/communication-engine, Apache-2.0) is the
# observability layer over the agent's communication channels: pluggable adapters
# (slack, telegram, email, and a credential-free fake for demo mode) poll messages into a
# sqlite journal, and a Streamlit dashboard renders the severity-ordered attention queue.
# The engine's human-gated write surface ships on (COMMS_UI_WRITE_ENABLED=true in .env):
# compose stages a draft, only an explicit click sends - nothing auto-sends; set it false
# for the strictly read-only viewer (docs/comms/README.md).
# The engine core is stdlib-only python; streamlit is its one optional extra (the dashboard).
# Pinned to a full commit sha - no floating refs. Current pin: 1156a40, tag v0.1.0 of the engine's public repository.
# (Its v0.2.0 adds the gated Slack send; this image moves there once its own tests and docs cover that send path.) The
# pin carries the write surface, config management, a named warning instead of a crash of the dashboard for a
# half-configured connection, in-thread answers that close open asks, and a thread sweep that a backlog channel cannot
# starve and where an unplaceable thread draft never reaches the send gate. An in-thread reply
# from someone other than the asker, or a reply sent from the dashboard's Reply button, marks the
# ask answered; the scheduler (the comms watcher) fetches the replies under open asks each cycle;
# each click on the dashboard reloads the settings and builds a fresh adapter and outbox.
export COMMS_ENGINE_REPO=https://github.com/dmvevents/communication-engine
export COMMS_ENGINE_SHA=1156a40ca7021cbae9a4e89f42a5b0478bd2c86f
export COMMS_HOME=/opt/comms
# streamlit runs in its own Python 3.12 environment, /opt/comms-venv (uv-managed): the base image's python3 is 3.10, and
# pillow 13 - streamlit's image library; 12.x carried 5 CRITICAL and 23 HIGH findings in the CVE scan (docs/manual/supply-chain.md "CVE scan") -
# needs Python 3.11 or newer, as does streamlit from 1.66.1 on. The interpreter is kept under /opt/uv-python, outside root's
# home and the agent-state mounts. Every streamlit run goes through COMMS_PYTHON (agent/comms-ui-start.sh and the comms tests,
# default ${COMMS_VENV}/bin/python); the engine core stays stdlib-only and runs on either Python.
export STREAMLIT_VERSION=1.67.0
export COMMS_PYTHON_VERSION=3.12
export COMMS_VENV=/opt/comms-venv
export UV_PYTHON_INSTALL_DIR=/opt/uv-python

# The base image ships neither git nor python3 (node arrives via nvm, python tools via uv). python3-pip WITHOUT its Recommends:
# they are build-essential and python3-dev, a compiler toolchain (gcc, g++, make, the libc headers) that nothing in the image uses -
# streamlit and its dependencies install as wheels, and no installer, test or document compiles anything - and with them the
# kernel headers package linux-libc-dev, which the CVE scan (docs/manual/supply-chain.md "CVE scan") reads as the carrier of 18 CRITICAL and ~3,300
# further kernel CVEs that Ubuntu 22.04 has no fix for. git keeps its Recommends (ssh-client, less, patch): git over ssh needs them
DEBIAN_FRONTEND=noninteractive apt-get install -y git python3
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3-pip

git clone ${COMMS_ENGINE_REPO} ${COMMS_HOME}
git -C ${COMMS_HOME} checkout ${COMMS_ENGINE_SHA}

# Fail loud unless the checkout is exactly the pinned sha
HEAD_SHA=$(git -C ${COMMS_HOME} rev-parse HEAD)
if [ "${HEAD_SHA}" != "${COMMS_ENGINE_SHA}" ]; then
	echo "ERROR: communication-engine HEAD ${HEAD_SHA} != pinned ${COMMS_ENGINE_SHA}"
	exit 1
fi

# Build-time patches on the pinned engine: setup/comms-patches/*.patch, applied in name order to the working tree
# (HEAD stays the pin; `git -C /opt/comms status --short` lists the patched files, and `git -C /opt/comms apply
# --check --reverse <patch>` succeeds only while a patch is applied). Each file holds the commits of one engine change this
# image needs before the pin can move past it, exported with `git format-patch`; it applies with `apply --check` first and
# fails the build loud when it does not. Delete a patch and move COMMS_ENGINE_SHA past its merge in the same commit.
#   0001-thread-answered-at-ingest.patch - an engine change released in its v0.2.0: a message that has a thread is
#   answered (threaded_is_answered, default on): an ask whose polled row shows a reply from someone other than the
#   asker is tied at ingest with no replies call, and in the thread sweep any such reply answers, a question included
#   (docs/comms/README.md "What unanswered means"). Delete it when the pin moves to v0.2.0 or later.
for PATCH in /setup/comms-patches/*.patch; do
	[ -f "${PATCH}" ] || continue
	if ! git -C ${COMMS_HOME} apply --check "${PATCH}"; then
		echo "ERROR: communication-engine patch ${PATCH} does not apply to ${COMMS_ENGINE_SHA} - the engine pin moved under it (delete the patch if its change is merged there, else refresh it)"
		exit 1
	fi
	git -C ${COMMS_HOME} apply "${PATCH}" || { echo "ERROR: applying ${PATCH} failed"; exit 1; }
	echo "communication-engine: applied $(basename "${PATCH}") on ${COMMS_ENGINE_SHA}"
done

# The engine's documented healthy-clone step: its tests/test_docs.py asserts the
# pre-commit hook exists, so the unit-test gate in test6.sh needs the hooks installed
(cd ${COMMS_HOME} && bash scripts/install-hooks.sh)

UV=${HOME}/.local/bin/uv
"${UV}" venv --python "${COMMS_PYTHON_VERSION}" "${COMMS_VENV}" || { echo "ERROR: install-comms.sh: uv venv ${COMMS_VENV} failed"; exit 1; }
"${UV}" pip install --python "${COMMS_VENV}/bin/python" "streamlit==${STREAMLIT_VERSION}" \
	|| { echo "ERROR: install-comms.sh: streamlit ${STREAMLIT_VERSION} did not install into ${COMMS_VENV}"; exit 1; }
# the wheels are not needed once installed, and the CVE scan would read them as a second copy
"${UV}" cache clean
# pip inside the interpreter uv fetched is never run - uv installs, and the environment built on it has no pip of its own -
# and its vendored urllib3, msgpack and setuptools carried HIGH findings in the CVE scan (docs/manual/supply-chain.md "CVE scan"): removed
for SP in "${UV_PYTHON_INSTALL_DIR}"/cpython-*/lib/python3*/site-packages; do rm -rf "${SP}"/pip "${SP}"/pip-*.dist-info; done
rm -f "${UV_PYTHON_INSTALL_DIR}"/cpython-*/bin/pip "${UV_PYTHON_INSTALL_DIR}"/cpython-*/bin/pip3*

ls ${COMMS_HOME}/scripts/dashboard.py
"${COMMS_VENV}/bin/python" -c "import streamlit, PIL; print('streamlit', streamlit.__version__, 'pillow', PIL.__version__)"
