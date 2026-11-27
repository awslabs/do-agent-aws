#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Self-hosted Plane board - Plane community's twelve services as sidecar containers of the agent container (docs/manual/boards.md
# "Plane board"). A host-side helper of build.sh, run.sh and stop.sh, also usable by hand:
#   ./plane.sh pull    - pull the pinned public images that are not present yet (build.sh calls it)
#   ./plane.sh init    - create the secrets file PLANE_DIR/plane.env on first use (mode 600) and derive the
#                        per-service env files from it (start calls it)
#   ./plane.sh start   - TO=docker: start the services on PLANE_INTERNAL_NETWORK in upstream's order, the proxy also
#                        on PLANE_NETWORK (the agent's), and wait until the proxy serves /api/instances/ (a fresh
#                        instance there still shows Plane's own setup wizard)
#   ./plane.sh seed    - seed the admin, the workspace, this instance's project and the agent's API token
#                        (plane/seed.py), clear the cache, then assert that the SERVED is_setup_done is true
#   ./plane.sh up      - start + seed (run.sh calls it before it starts the agent container)
#   ./plane.sh down    - remove every container and the networks carrying this harness's label; the data volumes stay
#                        (each container goes with its anonymous volumes, docker container rm -v: the minio image's
#                        unused /data; the named data volumes are never anonymous, so -v leaves them)
#                        (stop.sh calls it)
#   ./plane.sh status  - show the services, the volumes and the served setup state
# No service publishes a host port: the board is reached through the agent container's home proxy at plane.localhost.
# The agent shares a network with the board's proxy only: no other board container can reach the agent's ports. The
# services' own network has no egress, and Plane's metrics exporter points at a closed loopback port: the board sends
# nothing to a third party.
# No secret is printed: the services get theirs only through --env-file (mode 600 files under PLANE_DIR) and the seed
# reads them from stdin, so neither VERBOSE output, DEBUG=true's trace, a command line nor a log line carries them;
# container log lines shown on a failure are redacted. A container or network is only removed when it carries this harness's label
# (do-agent-aws.plane=<CONTAINER>), so a same-named one of someone else is never touched.
# Recipe and provenance: plane/README.md.

source .env

if [ "${DEBUG}" == "true" ]; then
	set -x
fi

LABEL_KEY=do-agent-aws.plane
LABEL="${LABEL_KEY}=${CONTAINER}"
AUTH_FILE=${PLANE_DIR}/plane.env
SEED_PY=$(pwd)/plane/seed.py
API=${PLANE_NAME}-api
# name|network aliases on PLANE_INTERNAL_NETWORK (upstream's compose service names, which the proxy image's Caddyfile
# and the services' own settings use); on PLANE_NETWORK the agent reaches the proxy as plane-proxy
SERVICES="db|plane-db redis|plane-redis mq|plane-mq minio|plane-minio api|api worker|worker beat-worker|beat-worker web|web space|space admin|admin live|live proxy|proxy"
VOLUMES="pgdata redisdata uploads rabbitmq proxy-config proxy-data"
IMAGES="${PLANE_BACKEND_IMAGE} ${PLANE_FRONTEND_IMAGE} ${PLANE_SPACE_IMAGE} ${PLANE_ADMIN_IMAGE} ${PLANE_LIVE_IMAGE} ${PLANE_PROXY_IMAGE} ${PLANE_POSTGRES_IMAGE} ${PLANE_REDIS_IMAGE} ${PLANE_MQ_IMAGE} ${PLANE_MINIO_IMAGE}"

fail()
{
	echo "plane: ERROR - $*" >&2
	exit 1
}

# quiet / unquiet - no xtrace while plane.env's secrets are in variables or on a traced line: DEBUG=true (set -x
# above) traces the rest of plane.sh, never a secret (the same pattern as kanban.sh)
quiet()
{
	{ set +x; } 2> /dev/null
}

unquiet()
{
	if [ "${DEBUG}" == "true" ]; then
		set -x
	fi
}

# run <command> - echo it when VERBOSE=true, execute it unless DRY_RUN=true (the repo scripts' convention)
run()
{
	if [ "${VERBOSE}" == "true" ]; then
		echo "$*"
	fi
	if [ "${DRY_RUN}" == "false" ]; then
		eval "$*"
	fi
}

rand_hex()
{
	if command -v openssl > /dev/null 2>&1; then
		openssl rand -hex "$1"
	else
		head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'
	fi
}

# kv <KEY> - the value of KEY in plane.env (the last assignment wins, as in a sourced file)
kv()
{
	sed -n "s/^$1=//p" "${AUTH_FILE}" 2>/dev/null | tail -1
}

# The generated secrets of plane.env: the board login, the agent's API key, Plane's two server keys and the passwords
# of its database, queue and object store
SECRET_KEYS="PLANE_ADMIN_PASSWORD PLANE_API_KEY PLANE_SECRET_KEY PLANE_LIVE_SERVER_SECRET_KEY PLANE_DB_PASSWORD PLANE_MQ_PASSWORD PLANE_MINIO_SECRET_KEY"

# gen_secret <KEY> - a fresh random value for one of SECRET_KEYS
gen_secret()
{
	case "$1" in
	PLANE_API_KEY) echo "plane_api_$(rand_hex 16)" ;;
	PLANE_SECRET_KEY|PLANE_LIVE_SERVER_SECRET_KEY) rand_hex 32 ;;
	*) rand_hex 16 ;;
	esac
}

# redact - drop the secrets of plane.env from text shown on the terminal or written to a log. The values reach sed
# through a pipe (process substitution; printf is a shell builtin), never a command line or a file, so no process
# listing ever shows them; sed's special characters in a value are escaped
redact()
{
	quiet
	sed -f <(
		for K in ${SECRET_KEYS}; do
			V=$(kv "${K}")
			[ -n "${V}" ] && printf 's/%s/***/g\n' "$(printf '%s' "${V}" | sed 's/[]\/$*.^&[]/\\&/g')"
		done
	)
	RC=$?
	unquiet
	return ${RC}
}

# write_env_file <path> - stdin to a mode-600 file: written beside it (mktemp creates it 600) and moved over it, so a
# failed write never leaves a truncated file and an existing file never keeps a wider mode
write_env_file()
{
	TMP=$(mktemp "$1.XXXXXX") || fail "cannot write $1"
	if ! cat > "${TMP}" || ! chmod 600 "${TMP}" || ! mv -f "${TMP:?}" "${1:?}"; then
		rm -f "${TMP:?}"
		fail "cannot write $1"
	fi
}

plane_pull()
{
	for I in ${IMAGES}; do
		if docker image inspect "${I}" > /dev/null 2>&1; then
			echo "plane: ${I} present"
		else
			run "docker image pull -q ${I}" || fail "cannot pull ${I} (anonymous pull from Docker Hub)"
		fi
	done
}

plane_init()
{
	if [ "${DRY_RUN}" != "false" ]; then
		echo "plane: DRY_RUN - would create ${AUTH_FILE} when missing and refresh the env files beside it"
		return 0
	fi
	quiet
	# a private directory: only its owner may list it or swap a file in it
	{ install -d -m 700 "${PLANE_DIR}" && chmod 700 "${PLANE_DIR}"; } || fail "cannot create ${PLANE_DIR}"
	if [ ! -f "${AUTH_FILE}" ]; then
		write_env_file "${AUTH_FILE}" << EOF
# Plane board login, the agent's API key and the server secrets, generated by ./plane.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# The home page's Plane tile signs you in as PLANE_ADMIN_EMAIL (PLANE_LOGIN_BYPASS=true in .env); Plane's own login
# page at http://plane.localhost:<home port>/ takes the same email and password. The agent's goal mirror
# (/agent/plane-sync.py) sends PLANE_API_KEY as X-Api-Key. The DB, MQ and MINIO values are the passwords of Plane's
# database, queue and object store. Keep the file private: mode 600, under the gitignored wd/. Delete it to rotate
# every value on the next ./stop.sh + ./run.sh; the board's data in its volumes stays.
PLANE_ADMIN_EMAIL=agent@do-agent-aws.local
EOF
		echo "plane: generated the board's secrets file ${AUTH_FILE} (mode 600)"
	fi
	chmod 600 "${AUTH_FILE}"
	# every secret it lacks gets a fresh random value (a new file, or one written before a key existed)
	ADD=""
	for K in ${SECRET_KEYS}; do
		[ -n "$(kv "${K}")" ] || ADD="${ADD}${K}=$(gen_secret "${K}")"$'\n'
	done
	if [ -n "${ADD}" ]; then
		{ cat "${AUTH_FILE}"; printf '%s' "${ADD}"; } | write_env_file "${AUTH_FILE}"
	fi
	unset ADD
	for K in PLANE_ADMIN_EMAIL ${SECRET_KEYS}; do
		[ -n "$(kv "${K}")" ] || fail "${AUTH_FILE} has no value for ${K} - fix it, or delete the file to generate a new one"
	done
	# Plane's instance-metrics exporter (license/bgtasks/telemetry_metrics.py) sends to OTLP_ENDPOINT, by default
	# https://telemetry.plane.so. The api queues a push at every start (register_instance), and the worker runs it
	# before the seed can turn telemetry off: a closed loopback port, so no export can leave whatever the timing or
	# the flag (and the services' network has no egress either, see plane_start)
	PLANE_OTLP_ENDPOINT=http://127.0.0.1:9
	# The per-service env files, derived on every start: upstream's deployments/cli/community docker-compose.yml and
	# variables.env at v1.4.2. The browser origin is plane.localhost on the home port. The database, queue and object
	# store get the random passwords of plane.env: a new volume takes them at its first start, and plane_start applies
	# them to an existing one (apply_datastore_passwords)
	ORIGIN=http://plane.localhost:${PORT_EXTERNAL_HOME}
	DBPW=$(kv PLANE_DB_PASSWORD)
	MQPW=$(kv PLANE_MQ_PASSWORD)
	S3PW=$(kv PLANE_MINIO_SECRET_KEY)
	write_env_file "${PLANE_DIR}/db.env" << EOF
POSTGRES_USER=plane
POSTGRES_PASSWORD=${DBPW}
POSTGRES_DB=plane
PGDATA=/var/lib/postgresql/data
EOF
	# The two sizes upstream leaves at one per host CPU (Celery's prefork pool, RabbitMQ's Erlang schedulers, which
	# also busy-wait), bounded by .env: PLANE_WORKER_CONCURRENCY, PLANE_MQ_SCHEDULERS
	write_env_file "${PLANE_DIR}/mq.env" << EOF
RABBITMQ_DEFAULT_USER=plane
RABBITMQ_DEFAULT_PASS=${MQPW}
RABBITMQ_DEFAULT_VHOST=plane
RABBITMQ_SERVER_ADDITIONAL_ERL_ARGS=+S ${PLANE_MQ_SCHEDULERS:-2}:${PLANE_MQ_SCHEDULERS:-2} +sbwt none +sbwtdcpu none +sbwtdio none
RABBITMQ_CTL_ERL_ARGS=+S 1:1 +sbwt none +sbwtdcpu none +sbwtdio none
EOF
	write_env_file "${PLANE_DIR}/minio.env" << EOF
MINIO_ROOT_USER=access-key
MINIO_ROOT_PASSWORD=${S3PW}
EOF
	write_env_file "${PLANE_DIR}/proxy.env" << EOF
APP_DOMAIN=plane.localhost
FILE_SIZE_LIMIT=5242880
CERT_EMAIL=
CERT_ACME_CA=https://acme-v02.api.letsencrypt.org/directory
CERT_ACME_DNS=
LISTEN_HTTP_PORT=80
LISTEN_HTTPS_PORT=443
BUCKET_NAME=uploads
SITE_ADDRESS=:80
EOF
	write_env_file "${PLANE_DIR}/live.env" << EOF
API_BASE_URL=http://api:8000
LIVE_SERVER_SECRET_KEY=$(kv PLANE_LIVE_SERVER_SECRET_KEY)
REDIS_HOST=plane-redis
REDIS_PORT=6379
REDIS_URL=redis://plane-redis:6379/
EOF
	{ cat << EOF
WEB_URL=${ORIGIN}
DEBUG=0
CORS_ALLOWED_ORIGINS=${ORIGIN}
GUNICORN_WORKERS=1
USE_MINIO=1
DATABASE_URL=postgresql://plane:${DBPW}@plane-db/plane
SECRET_KEY=$(kv PLANE_SECRET_KEY)
AMQP_URL=amqp://plane:${MQPW}@plane-mq:5672/plane
API_KEY_RATE_LIMIT=60/minute
MINIO_ENDPOINT_SSL=0
LIVE_SERVER_SECRET_KEY=$(kv PLANE_LIVE_SERVER_SECRET_KEY)
WEBHOOK_ALLOWED_IPS=
WEBHOOK_ALLOWED_HOSTS=
PGHOST=plane-db
PGDATABASE=plane
POSTGRES_USER=plane
POSTGRES_PASSWORD=${DBPW}
POSTGRES_DB=plane
POSTGRES_PORT=5432
PGDATA=/var/lib/postgresql/data
REDIS_HOST=plane-redis
REDIS_PORT=6379
REDIS_URL=redis://plane-redis:6379/
MINIO_ROOT_USER=access-key
MINIO_ROOT_PASSWORD=${S3PW}
AWS_REGION=
AWS_ACCESS_KEY_ID=access-key
AWS_SECRET_ACCESS_KEY=${S3PW}
AWS_S3_ENDPOINT_URL=http://plane-minio:9000
AWS_S3_BUCKET_NAME=uploads
CELERY_WORKER_CONCURRENCY=${PLANE_WORKER_CONCURRENCY:-2}
OTLP_ENDPOINT=${PLANE_OTLP_ENDPOINT}
EOF
	sed -n '/^APP_DOMAIN=/,$p' "${PLANE_DIR}/proxy.env"; } | write_env_file "${PLANE_DIR}/app.env"
	unquiet
}

# ours_container / ours_network <name> - 0 when it carries this harness's label
ours_container()
{
	[ "$(docker container inspect -f "{{index .Config.Labels \"${LABEL_KEY}\"}}" "$1" 2>/dev/null)" == "${CONTAINER}" ]
}

ours_network()
{
	[ "$(docker network inspect -f "{{index .Labels \"${LABEL_KEY}\"}}" "$1" 2>/dev/null)" == "${CONTAINER}" ]
}

exists()
{
	docker container inspect "$1" > /dev/null 2>&1
}

# show_logs <name> - the last container log lines, with plane.env's secrets redacted
show_logs()
{
	echo "plane: last log lines of $1:" >&2
	docker container logs --tail 25 "$1" 2>&1 | redact >&2
}

# wait_ready <name> <seconds> - until the container is running and, when it has a healthcheck, healthy
wait_ready()
{
	[ "${DRY_RUN}" == "false" ] || return 0
	for i in $(seq 1 "$2"); do
		STATE=$(docker container inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null)
		case "${STATE}" in
		"running healthy"|"running none")
			echo "plane: $1 ready after ${i}s"
			return 0
			;;
		dead*|exited*|"")
			echo "plane: $1 is not running (${STATE:-gone})" >&2
			show_logs "$1"
			return 1
			;;
		esac
		sleep 1
	done
	echo "plane: $1 not ready after $2s (state: ${STATE})" >&2
	show_logs "$1"
	return 1
}

# start_sidecar <service> <aliases> <image> <options> [<command>] - (re)create one service on PLANE_INTERNAL_NETWORK.
# A running one of ours on the current image and settings (a hash of the image, network, options, command and env
# file, kept in a label) is left alone, so ./run.sh can be re-run; a stopped one, or one whose image or settings
# changed, is replaced.
start_sidecar()
{
	NAME=${PLANE_NAME}-$1
	ALIASES=""
	for A in ${2//,/ }; do
		ALIASES="${ALIASES} --network-alias ${A}"
	done
	IMG=$3
	OPTS=$4
	ARGS=$5
	ENV_FILE=$(echo "${OPTS}" | sed -n 's/.*--env-file \([^ ]*\).*/\1/p')
	CONFIG=$( { echo "${IMG} ${PLANE_INTERNAL_NETWORK}${ALIASES} ${OPTS} ${ARGS}"; docker image inspect -f '{{.Id}}' "${IMG}" 2>/dev/null; [ -n "${ENV_FILE}" ] && cat "${ENV_FILE}" 2>/dev/null; } | sha256sum | cut -c1-16)
	# DRY_RUN shows the command a fresh host runs, whatever is running here
	if [ "${DRY_RUN}" == "false" ] && exists "${NAME}"; then
		ours_container "${NAME}" || fail "a container named ${NAME} exists and is not this harness's (no ${LABEL} label) - refusing to touch it; set CONTAINER in .env to another name"
		RUNNING=$(docker container inspect -f '{{.State.Running}}' "${NAME}" 2>/dev/null)
		HAS=$(docker container inspect -f "{{index .Config.Labels \"${LABEL_KEY}.config\"}}" "${NAME}" 2>/dev/null)
		if [ "${RUNNING}" == "true" ] && [ "${HAS}" == "${CONFIG}" ]; then
			echo "plane: ${NAME} already running"
			return 0
		fi
		run "docker container rm -f -v ${NAME} > /dev/null"
	fi
	run "docker container run -d --name ${NAME} --label ${LABEL} --label ${LABEL_KEY}.config=${CONFIG} --network ${PLANE_INTERNAL_NETWORK}${ALIASES} ${OPTS} ${IMG} ${ARGS} > /dev/null" \
		|| fail "could not start ${NAME}"
}

# apply_datastore_passwords - plane.env's database and queue passwords, applied to the running datastores over stdin,
# never on a command line. A new volume already took them at its first start; an existing one (plane.env deleted to
# rotate, or a volume from before these passwords existed) takes them here. MinIO reads its root password from its
# environment at every start.
apply_datastore_passwords()
{
	if [ "${DRY_RUN}" != "false" ]; then
		echo "plane: DRY_RUN - would apply the database and queue passwords over stdin"
		return 0
	fi
	quiet
	printf "ALTER ROLE plane PASSWORD '%s';\n" "$(kv PLANE_DB_PASSWORD)" \
		| timeout 60 docker container exec -i "${PLANE_NAME}-db" psql -v ON_ERROR_STOP=1 -q -U plane -d plane > /dev/null 2>&1 \
		|| fail "could not apply the board database's password"
	# A new queue node creates its user from mq.env only some time after its health check passes (measured on a busy
	# host: ping at +34 s, the user at +99 s), so wait for the user before checking its password (bounded: a user
	# deleted by hand is re-created below)
	for _ in $(seq 1 60); do
		docker container exec "${PLANE_NAME}-mq" rabbitmqctl -q list_users 2> /dev/null | grep -q '^plane[[:space:]]' && break
		sleep 2
	done
	# rabbitmqctl takes a new password only on its command line (change_password) or on stdin (add_user, and
	# authenticate_user to check it). It reads stdin only without -q: with -q the 3.13 CLI waits for it forever
	if ! kv PLANE_MQ_PASSWORD | timeout 60 docker container exec -i "${PLANE_NAME}-mq" rabbitmqctl authenticate_user plane > /dev/null 2>&1; then
		docker container exec "${PLANE_NAME}-mq" rabbitmqctl -q delete_user plane > /dev/null 2>&1
		{ kv PLANE_MQ_PASSWORD | timeout 60 docker container exec -i "${PLANE_NAME}-mq" rabbitmqctl add_user plane \
			&& docker container exec "${PLANE_NAME}-mq" rabbitmqctl -q set_user_tags plane administrator \
			&& docker container exec "${PLANE_NAME}-mq" rabbitmqctl -q set_permissions -p plane plane '.*' '.*' '.*'; } > /dev/null 2>&1 \
			|| fail "could not apply the board queue's password"
		echo "plane: applied plane.env's queue password to the existing queue volume"
	fi
	unquiet
}

# wait_migrator <name> - the one-shot migrator's exit status, in MIG_RC. docker container wait is bounded by
# PLANE_MIGRATE_TIMEOUT (default 1800 s). A stalling docker daemon can hold the wait past that although the migrator
# has finished (measured on a loaded host: the wait timed out on a migrator that had exited 0), so after a timeout
# the container's own state decides: exited 0 passes; still running, another code or no answer does not
wait_migrator()
{
	MIG_RC=$(timeout "${PLANE_MIGRATE_TIMEOUT:-1800}" docker container wait "$1" 2> /dev/null)
	if [ -z "${MIG_RC}" ]; then
		MIG_STATE=$(timeout 120 docker container inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$1" 2> /dev/null)
		echo "plane: docker container wait $1 gave no answer within ${PLANE_MIGRATE_TIMEOUT:-1800}s (PLANE_MIGRATE_TIMEOUT); the migrator's own state: ${MIG_STATE:-no answer}"
		[ "${MIG_STATE}" == "exited 0" ] && MIG_RC=0
	fi
}

# api_python <code> - run python in the api container (plane.sh's view of the stack: no host port to curl)
api_python()
{
	docker container exec "${API}" python -c "$1" 2>/dev/null
}

# served_setup_done - is_setup_done as the Plane proxy serves /api/instances/ (the value the web app gates on),
# or an HTTP error
served_setup_done()
{
	api_python "
import json, urllib.request, urllib.error
try:
    d = json.load(urllib.request.urlopen('http://proxy:80/api/instances/', timeout=10))
    print(str((d.get('instance') or d).get('is_setup_done')).lower())
except urllib.error.HTTPError as e:
    print('http-%d' % e.code)
except Exception as e:
    print('unreachable')"
}

plane_start()
{
	plane_init
	for I in ${IMAGES}; do
		[ "${DRY_RUN}" == "false" ] || break
		docker image inspect "${I}" > /dev/null 2>&1 || fail "the image ${I} is missing - run ./build.sh (or ./plane.sh pull) first"
	done
	# The services' network has no egress (--internal): nothing on it can reach a third party - Plane's metrics push
	# (telemetry.plane.so) and the api's GitHub release check at every start (register_instance, no setting
	# upstream) fail fast. The agent's network (PLANE_NETWORK) keeps egress; on it only the proxy joins the agent.
	for N in ${PLANE_INTERNAL_NETWORK} ${PLANE_NETWORK}; do
		OPT=""
		[ "${N}" == "${PLANE_INTERNAL_NETWORK}" ] && OPT="--internal "
		if [ "${DRY_RUN}" == "false" ] && docker network inspect "${N}" > /dev/null 2>&1; then
			ours_network "${N}" || fail "a network named ${N} exists and is not this harness's (no ${LABEL} label) - refusing to use it"
			if [ -n "${OPT}" ] && [ "$(docker network inspect -f '{{.Internal}}' "${N}")" != "true" ]; then
				# an install from before the network was internal: take the board's containers off it (they are
				# re-created below; the data is in the volumes) and re-create it
				for C in $(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "${N}"); do
					ours_container "${C}" || fail "the network ${N} holds ${C}, which is not this harness's - refusing to re-create it"
					run "docker container rm -f -v ${C} > /dev/null" || fail "could not remove ${C}"
				done
				run "docker network rm ${N} > /dev/null" || fail "could not remove the network ${N}"
				run "docker network create --label ${LABEL} ${OPT}${N} > /dev/null" || fail "could not create the network ${N}"
				echo "plane: re-created the network ${N} with --internal (no egress for the board's services)"
			fi
		else
			run "docker network create --label ${LABEL} ${OPT}${N} > /dev/null" || fail "could not create the network ${N}"
		fi
	done
	for V in ${VOLUMES}; do
		if [ "${DRY_RUN}" != "false" ] || ! docker volume inspect "${PLANE_NAME}-${V}" > /dev/null 2>&1; then
			run "docker volume create --label ${LABEL} ${PLANE_NAME}-${V} > /dev/null" || fail "could not create the volume ${PLANE_NAME}-${V}"
		fi
	done
	R="--restart unless-stopped"
	# Health checks every 2 s while a service starts (Docker 25+ --health-start-interval), then every 60 s: the
	# RabbitMQ check starts an Erlang VM each time, which at a 5 s interval is several cores of CPU on a many-CPU host
	H="--health-start-period 180s --health-start-interval 2s --health-interval 60s --health-timeout 10s --health-retries 3"
	D=${PLANE_DIR}
	# Datastores first, each waited for, then the one-shot migrator, then the app (upstream's depends_on order)
	start_sidecar db plane-db "${PLANE_POSTGRES_IMAGE}" "${R} --env-file ${D}/db.env -v ${PLANE_NAME}-pgdata:/var/lib/postgresql/data --health-cmd 'pg_isready -h 127.0.0.1 -U plane -d plane' ${H}" "postgres -c max_connections=1000"
	start_sidecar redis plane-redis "${PLANE_REDIS_IMAGE}" "${R} -v ${PLANE_NAME}-redisdata:/data --health-cmd 'valkey-cli ping' ${H}"
	# RabbitMQ keeps its data under its node name, rabbit@<hostname>: a fixed hostname keeps the volume's data (users,
	# queues) across a new container instead of starting an empty node beside the old one
	start_sidecar mq plane-mq "${PLANE_MQ_IMAGE}" "${R} --hostname plane-mq --env-file ${D}/mq.env -v ${PLANE_NAME}-rabbitmq:/var/lib/rabbitmq --health-cmd 'rabbitmq-diagnostics -q ping' ${H}"
	start_sidecar minio plane-minio "${PLANE_MINIO_IMAGE}" "${R} --env-file ${D}/minio.env -v ${PLANE_NAME}-uploads:/export --health-cmd 'curl -fsS http://127.0.0.1:9000/minio/health/live' ${H}" "server /export --console-address :9090"
	for S in db redis mq minio; do
		wait_ready "${PLANE_NAME}-${S}" 180 || fail "the board's ${S} did not become ready"
	done
	apply_datastore_passwords
	# Migrations: a fresh container every start (a no-op when nothing is pending); its log stays in PLANE_DIR
	MIG=${PLANE_NAME}-migrator
	if [ "${DRY_RUN}" == "false" ] && exists "${MIG}"; then
		ours_container "${MIG}" || fail "a container named ${MIG} exists and is not this harness's - refusing to touch it"
		run "docker container rm -f -v ${MIG} > /dev/null"
	fi
	run "docker container run -d --name ${MIG} --label ${LABEL} --network ${PLANE_INTERNAL_NETWORK} --network-alias migrator --env-file ${D}/app.env ${PLANE_BACKEND_IMAGE} ./bin/docker-entrypoint-migrator.sh > /dev/null" \
		|| fail "could not start ${MIG}"
	if [ "${DRY_RUN}" == "false" ]; then
		wait_migrator "${MIG}"
		timeout 120 docker container logs "${MIG}" 2>&1 | redact | write_env_file "${D}/migrator.log"
		[ "${MIG_RC}" == "0" ] || { show_logs "${MIG}"; fail "the database migrations failed (exit ${MIG_RC:-timeout}; log ${D}/migrator.log)"; }
		echo "plane: database migrations applied ($(grep -c '  Applying ' "${D}/migrator.log") new; log ${D}/migrator.log)"
		docker container rm -v "${MIG}" > /dev/null
	fi
	start_sidecar api api "${PLANE_BACKEND_IMAGE}" "${R} --env-file ${D}/app.env" ./bin/docker-entrypoint-api.sh
	start_sidecar worker worker "${PLANE_BACKEND_IMAGE}" "${R} --env-file ${D}/app.env" ./bin/docker-entrypoint-worker.sh
	start_sidecar beat-worker beat-worker "${PLANE_BACKEND_IMAGE}" "${R} --env-file ${D}/app.env" ./bin/docker-entrypoint-beat.sh
	start_sidecar web web "${PLANE_FRONTEND_IMAGE}" "${R}"
	start_sidecar space space "${PLANE_SPACE_IMAGE}" "${R}"
	start_sidecar admin admin "${PLANE_ADMIN_IMAGE}" "${R}"
	start_sidecar live live "${PLANE_LIVE_IMAGE}" "${R} --env-file ${D}/live.env"
	# the proxy alone also joins the agent's network (a second --network, Docker 25+)
	start_sidecar proxy proxy "${PLANE_PROXY_IMAGE}" "${R} --network name=${PLANE_NETWORK},alias=plane-proxy --env-file ${D}/proxy.env -v ${PLANE_NAME}-proxy-config:/config -v ${PLANE_NAME}-proxy-data:/data"
	[ "${DRY_RUN}" == "false" ] || return 0
	# Ready = the proxy serves /api/instances/ (the api answers once register_instance, configure_instance and
	# create_bucket have run; the 502s before that are the normal start order, not a reason to restart anything)
	for i in $(seq 1 300); do
		SERVED=$(served_setup_done)
		case "${SERVED}" in
		true|false)
			echo "plane: the proxy serves /api/instances/ after ${i}s (is_setup_done=${SERVED})"
			return 0
			;;
		esac
		sleep 1
	done
	show_logs "${API}"
	fail "the Plane proxy did not serve /api/instances/ within 300s (last: ${SERVED})"
}

plane_seed()
{
	[ "${DRY_RUN}" == "false" ] || { echo "plane: DRY_RUN - would seed the admin, workspace, project and API token"; return 0; }
	[ -f "${SEED_PY}" ] || fail "missing ${SEED_PY}"
	exists "${API}" || fail "the board's api container ${API} is not running - ./plane.sh start first"
	# The settings and plane.env's KEY=value lines, a marker line, then the seed itself - all on stdin
	OUT=$( { cat "${AUTH_FILE}"
		echo "PLANE_WORKSPACE=${PLANE_WORKSPACE}"
		# Plane refuses - . and other punctuation in a project name (Project.FORBIDDEN_IDENTIFIER_CHARS_PATTERN)
		echo "PLANE_PROJECT_NAME=$(echo "${CONTAINER}" | sed -E 's/[^A-Za-z0-9_]+/ /g')"
		echo "PLANE_PROJECT_IDENTIFIER=${PLANE_PROJECT_IDENTIFIER}"
		echo "__SEED_PY__"
		cat "${SEED_PY}"; } | docker container exec -i "${API}" python manage.py shell -c "$(cat << 'EOF'
import sys
SEED = {}
for line in iter(sys.stdin.readline, ""):
    if line.strip() == "__SEED_PY__":
        break
    if "=" in line and not line.startswith("#"):
        k, v = line.rstrip("\n").split("=", 1)
        SEED[k.strip()] = v
exec(compile(sys.stdin.read(), "seed.py", "exec"))
EOF
)" 2>&1)
	RC=$?
	echo "${OUT}" | redact | grep -E '^(seed: |PROJECT_ID=)'
	if [ "${RC}" -ne 0 ] || ! echo "${OUT}" | grep -q '^PROJECT_ID='; then
		echo "${OUT}" | redact | tail -20 >&2
		fail "the seed failed (rc=${RC})"
	fi
	# THE check: the web app gates the whole app on the SERVED value, which comes from a cache - a DB write and even
	# a successful sign-in prove nothing about it. Poll it, nudging the cache on a miss; fail loud if it never flips.
	for i in $(seq 1 10); do
		SERVED=$(served_setup_done)
		[ "${SERVED}" == "true" ] && break
		docker container exec "${API}" python manage.py shell -c "from django.core.cache import cache; cache.clear()" > /dev/null 2>&1
		sleep 2
	done
	[ "${SERVED}" == "true" ] || fail "the proxy serves is_setup_done=${SERVED} after the seed and cache.clear() - the web app would show the setup wizard"
	echo "plane: the proxy serves is_setup_done=true - the board opens without a setup wizard"
}

plane_down()
{
	# -v: a container's anonymous volumes go with it - without it every stop left the minio image's /data volume
	# behind (its VOLUME directive; the board mounts its uploads at /export); the named data volumes stay either way
	for NAME in $(docker ps -a --filter "label=${LABEL}" --format '{{.Names}}'); do
		run "docker container rm -f -v ${NAME} > /dev/null" && echo "plane: removed ${NAME}"
	done
	for S in ${SERVICES}; do
		NAME=${PLANE_NAME}-${S%%|*}
		if exists "${NAME}" && ! ours_container "${NAME}"; then
			echo "plane: WARNING - ${NAME} is not this harness's (no ${LABEL} label); left untouched" >&2
		fi
	done
	for N in ${PLANE_NETWORK} ${PLANE_INTERNAL_NETWORK}; do
		docker network inspect "${N}" > /dev/null 2>&1 || continue
		if ours_network "${N}"; then
			run "docker network rm ${N} > /dev/null" && echo "plane: removed the network ${N}" \
				|| echo "plane: the network ${N} is still in use (is the agent container still running?); left in place" >&2
		else
			echo "plane: WARNING - the network ${N} is not this harness's; left untouched" >&2
		fi
	done
	if docker volume inspect "${PLANE_NAME}-pgdata" > /dev/null 2>&1; then
		echo "plane: the board's data stays in the volumes ${PLANE_NAME}-{${VOLUMES// /,}} (docker volume rm deletes it)"
	fi
}

plane_status()
{
	docker ps -a --filter "label=${LABEL}" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}'
	for V in ${VOLUMES}; do
		docker volume inspect "${PLANE_NAME}-${V}" > /dev/null 2>&1 && echo "volume ${PLANE_NAME}-${V}: present" || echo "volume ${PLANE_NAME}-${V}: absent"
	done
	[ -f "${AUTH_FILE}" ] && echo "secrets file: ${AUTH_FILE}" || echo "secrets file: not generated yet (the first ./run.sh creates ${AUTH_FILE})"
	SERVED=$(exists "${API}" && served_setup_done)
	echo "served is_setup_done: ${SERVED:-no api container}"
	[ "${SERVED}" == "true" ]
}

case "$1" in
	"pull")
		plane_pull
		;;
	"init")
		plane_init
		;;
	"start")
		plane_start
		;;
	"seed")
		plane_seed
		;;
	"up")
		plane_start
		plane_seed
		;;
	"down")
		plane_down
		;;
	"status")
		plane_status
		;;
	*)
		echo "Usage: $0 pull|init|start|seed|up|down|status (see docs/manual/boards.md \"Plane board\")"
		exit 1
		;;
esac
