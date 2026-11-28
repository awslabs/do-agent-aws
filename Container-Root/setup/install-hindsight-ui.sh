#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

echo ""
echo "Installing Hindsight UI ..."

# Human-facing server pieces for the hindsight memory already wired into the agent by
# install-hindsight.sh (which is unchanged): the HTTP API server (PyPI, serves the
# interactive /docs explorer) and the control-plane web UI (a Next.js standalone app
# that upstream publishes only inside the official container image - extracted with
# crane and served by this container's node).
# 1.2.0 (2026-11-03): the 0.9.2 control plane carried next 16.3.2 (5 CRITICAL in the CVE scan, docs/manual/supply-chain.md "CVE scan"), fixed only
# in the 1.x line; the API and the control plane move together (the same version names both below)
export HINDSIGHT_VERSION=1.2.1
# Python for the hindsight-api tool environment, pinned. The base image's python3 (3.10) is
# below hindsight-api's requires-python (>=3.11), so uv downloads its default stable Python,
# which uv 0.13.0 moved from 3.14 to 3.15 - and mlx (pulled in through hindsight-api-slim[all])
# has no cp315 wheels, so the unpinned install no longer resolves.
export HINDSIGHT_PYTHON=3.14

# The embedded PostgreSQL needs the system timezone database (absent in the base image)
# procps gives the pre-warm below its pgrep/pkill (not guaranteed by the base image)
DEBIAN_FRONTEND=noninteractive apt-get install -y tzdata procps

# The API server's embedded PostgreSQL (pg0) refuses to run as root (initdb), so it gets
# its own unprivileged user - mirroring the rootless official image - and its own uv
# tool install owned by that user. Data lives under /home/hindsight/.pg0.
useradd --create-home --shell /bin/bash hindsight 2>/dev/null || true
# uv for that user: the same pinned, checksum-verified release as the agent's (install-uv.sh), not an installer script
/setup/install-uv.sh /home/hindsight/.local/bin && chown -R hindsight:hindsight /home/hindsight/.local || exit 1
runuser -u hindsight -- sh -c "HOME=/home/hindsight /home/hindsight/.local/bin/uv tool install --python ${HINDSIGHT_PYTHON} hindsight-api==${HINDSIGHT_VERSION}"
ls /home/hindsight/.local/bin/hindsight-api || { echo "install-hindsight-ui.sh: hindsight-api is not installed" >&2; exit 1; }
# pip inside the interpreter uv fetched is never run - uv installs, and the environment built on it has no pip of its own -
# and its vendored urllib3, msgpack and setuptools carried HIGH findings in the CVE scan (docs/manual/supply-chain.md "CVE scan"): removed
for SP in /home/hindsight/.local/share/uv/python/cpython-*/lib/python3*/site-packages; do rm -rf "${SP}"/pip "${SP}"/pip-*.dist-info; done
rm -f /home/hindsight/.local/share/uv/python/cpython-*/bin/pip /home/hindsight/.local/share/uv/python/cpython-*/bin/pip3*
# The install's cache (the hindsight user's ~/.cache/uv: 6.4 GB of wheel archives, most hardlinked into the tool environment, some
# the resolver downloaded and did not keep) is dropped: uv re-downloads on demand, and the CVE scan (docs/manual/supply-chain.md "CVE scan") read
# every archive as a second copy of the environment, one of them (filelock) with a HIGH finding of its own
runuser -u hindsight -- env HOME=/home/hindsight /home/hindsight/.local/bin/uv cache clean || { echo "install-hindsight-ui.sh: uv cache clean failed" >&2; exit 1; }

# Pre-warm the server ONCE at build time, then stop it. Two things a fresh hindsight-api does on
# its first start are better done here than in every new container: it initialises its embedded
# PostgreSQL cluster (pg0, bundled PostgreSQL - no download, ~15 s), and it fetches its local
# embedding model (~220 MB from huggingface.co - a runtime network dependency, and minutes on a
# slow link, during which the memory API, the hooks and the home page's tile are all down).
# Baked, the first container start answers /health in seconds and works offline, and the
# agent-state mount of /home/hindsight/.pg0 (.env AGENT_STATE_VOL_MAP) is seeded from an
# INITIALISED cluster on first run. No credentials are needed for this: the LLM is only called
# on retain/reflect, never on startup. HINDSIGHT_API_WORKER_ID is the same stable id
# /agent/ui-start.sh runs with, so no task is ever left behind under a one-off worker name.
export HINDSIGHT_PREWARM_PORT=8888
export HINDSIGHT_PREWARM_WAIT=300
mkdir -p /home/hindsight/.pg0 /home/hindsight/.cache
chown -R hindsight:hindsight /home/hindsight/.pg0 /home/hindsight/.cache
PREWARM_LOG=/tmp/hindsight-prewarm.log
runuser -u hindsight -- env HOME=/home/hindsight HF_HOME=/home/hindsight/.cache/huggingface \
	HINDSIGHT_API_LLM_PROVIDER=bedrock HINDSIGHT_API_WORKER_ID=do-agent-aws \
	/home/hindsight/.local/bin/hindsight-api --host 127.0.0.1 --port ${HINDSIGHT_PREWARM_PORT} > ${PREWARM_LOG} 2>&1 &
HEALTHY=false
for i in $(seq 1 ${HINDSIGHT_PREWARM_WAIT}); do
	if curl -sf --max-time 2 http://127.0.0.1:${HINDSIGHT_PREWARM_PORT}/health 2>/dev/null | grep -q '"healthy"'; then
		HEALTHY=true
		break
	fi
	sleep 1
done
if [ "${HEALTHY}" != "true" ]; then
	echo "install-hindsight-ui.sh: hindsight-api did not answer /health within ${HINDSIGHT_PREWARM_WAIT}s during the build pre-warm:" >&2
	tail -30 ${PREWARM_LOG} >&2
	exit 1
fi
echo "hindsight-api pre-warm: healthy after ${i}s"
# TERM the server (not runuser's pid: runuser forks the command, the signal must reach the api
# itself), wait for it and its PostgreSQL to exit, then prove the cluster was closed cleanly:
# a leftover postmaster.pid would make the first container start retry against a stale lock.
pkill -TERM -u hindsight -f "hindsight-api --host 127.0.0.1 --port ${HINDSIGHT_PREWARM_PORT}"
for i in $(seq 1 60); do
	pgrep -u hindsight -f "hindsight-api|postgres" > /dev/null || break
	sleep 1
done
if pgrep -u hindsight -f "hindsight-api|postgres" > /dev/null; then
	echo "install-hindsight-ui.sh: hindsight-api or its PostgreSQL did not stop within 60s after TERM" >&2
	pgrep -u hindsight -af "hindsight-api|postgres" >&2
	exit 1
fi
if ls /home/hindsight/.pg0/instances/*/data/postmaster.pid > /dev/null 2>&1; then
	echo "install-hindsight-ui.sh: PostgreSQL left a postmaster.pid behind - the cluster was not closed cleanly" >&2
	exit 1
fi
[ -d /home/hindsight/.pg0/instances ] || { echo "install-hindsight-ui.sh: no pg0 instance under /home/hindsight/.pg0 after the pre-warm" >&2; exit 1; }
[ -d /home/hindsight/.cache/huggingface/hub ] || { echo "install-hindsight-ui.sh: no embedding model cache under /home/hindsight/.cache/huggingface after the pre-warm" >&2; exit 1; }
echo "hindsight-api pre-warm: cluster $(du -sh /home/hindsight/.pg0 | cut -f1) at /home/hindsight/.pg0, model cache $(du -sh /home/hindsight/.cache/huggingface | cut -f1), stopped cleanly"
rm -f "${PREWARM_LOG:?}"

mkdir -p /opt/hindsight
crane export ghcr.io/vectorize-io/hindsight-control-plane:${HINDSIGHT_VERSION} - \
	| tar -x -C /opt/hindsight --strip-components=1 app/control-plane

ls /opt/hindsight/control-plane/server.js
