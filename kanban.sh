#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Self-hosted kanban board - the vibe-kanban board server, Electric and Postgres as sidecar containers of the agent
# container (docs/manual/boards.md "Kanban board"). A host-side helper of build.sh, run.sh and stop.sh, also usable by hand:
#   ./kanban.sh build   - build the board server image KANBAN_IMAGE from the public upstream source at KANBAN_VK_SHA
#                         plus the vendored patches kanban/patches/*.patch, in order (build.sh calls it)
#   ./kanban.sh init    - create the board login file KANBAN_DIR/kanban.env on first use (mode 600) and derive the
#                         per-container env files from it (run.sh calls it for TO=compose; up calls it)
#   ./kanban.sh up      - TO=docker: start the three sidecars and wait for them to be healthy (run.sh calls it before it
#                         starts the agent container): the database and Electric on KANBAN_INTERNAL_NETWORK only (an
#                         internal network: no route out, and the agent is not on it), the board server on that one
#                         and on KANBAN_NETWORK, the network the agent container joins
#   ./kanban.sh db-password [<container>]
#                       - set the database role's password to the login file's KANBAN_DB_PASSWORD (up does it on
#                         every start; run.sh calls it for TO=compose with the compose database container)
#   ./kanban.sh down    - remove the three sidecars and their two networks; the data volumes stay (stop.sh calls it)
# With UI_KANBAN_RELAY=true (docs/manual/boards.md "Kanban board", the relay), build also builds the upstream relay server
# KANBAN_RELAY_IMAGE from the same checkout and the board image with kanban/patches-relay/*.patch after the others, init
# also writes relay.env, and up starts the relay as a fourth sidecar: on KANBAN_INTERNAL_NETWORK, where it reaches the
# database, and on KANBAN_NETWORK, where the agent reaches it as kanban-relay. Off (the default), none of this.
#   ./kanban.sh status  - show the sidecars and their health
# No sidecar publishes a host port: the board is reached through the agent container's home proxy at
# kanban.localhost. No secret is printed or passed as a command-line argument of any process: the login and the
# server secrets reach the containers through --env-file (mode-600 files under KANBAN_DIR) and the database password
# through psql's stdin, the secret handling runs with tracing off even with DEBUG=true, and the container log lines
# shown on a failure are redacted through a mode-600 sed script. (docker inspect of a sidecar shows its environment,
# as for any container.) A container or network is only ever removed when it carries this harness's label
# (do-agent-aws.kanban=<CONTAINER>), so a same-named container of someone else is never touched.
# Recipe and provenance: kanban/README.md.

source .env

if [ "${DEBUG}" == "true" ]; then
	set -x
fi

LABEL_KEY=do-agent-aws.kanban
LABEL="${LABEL_KEY}=${CONTAINER}"
PATCH_DIR=$(pwd)/kanban/patches
# the patches of the relay's board, applied after the others only with UI_KANBAN_RELAY=true
RELAY_PATCH_DIR=$(pwd)/kanban/patches-relay
AUTH_FILE=${KANBAN_DIR}/kanban.env
SECRET_KEYS="SELF_HOST_LOCAL_AUTH_PASSWORD VIBEKANBAN_REMOTE_JWT_SECRET ELECTRIC_ROLE_PASSWORD KANBAN_DB_PASSWORD"

fail()
{
	echo "kanban: ERROR - $*" >&2
	exit 1
}

# quiet / unquiet - no xtrace while secrets are in variables (DEBUG=true would otherwise print them)
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

# run <command> - echo it when VERBOSE=true, execute it unless DRY_RUN=true (the repo scripts' convention). The board's
# network names go into these commands through shq (.env), so a name reaches docker as one word and nothing in it runs
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

# kv <KEY> - the value of KEY in the login file (the last assignment wins, as in a sourced file)
kv()
{
	sed -n "s/^$1=//p" "${AUTH_FILE}" 2> /dev/null | tail -1
}

# redact - drop the secrets of the login file from text shown on the terminal (container logs on a failure); the
# values reach sed through a pipe (process substitution; printf is a builtin), never its command line or a file, so
# there is no temporary file whose failure could let text through unredacted
redact()
{
	quiet
	sed -f <(
		for K in ${SECRET_KEYS}; do
			V=$(kv "${K}")
			[ -n "${V}" ] && printf 's/%s/***/g\n' "${V}"
		done
	)
	unquiet
}

# base_args <Dockerfile> - the build arguments that pin the Dockerfile's base images and its # syntax= frontend by
# digest, the Dockerfile itself unchanged: --build-context <FROM name>=docker-image://<KANBAN_BUILD_BASES ref> for each
# image a FROM names (a stage name and scratch are not images), and --build-arg BUILDKIT_SYNTAX=KANBAN_BUILD_SYNTAX. A
# base image or a frontend without a pin by digest fails the build, so a new KANBAN_VK_SHA that brings another base
# image cannot pull one by its tag
base_args()
{
	local DF=$1 STAGES=" " SEEN=" " ARGS="" NAME STAGE REF B I
	local -a W
	[ -f "${DF}" ] || fail "no Dockerfile at ${DF}"
	while read -r -a W; do
		[ "${#W[@]}" -ge 2 ] || continue
		case "${W[0]}" in [Ff][Rr][Oo][Mm]) ;; *) continue ;; esac
		I=1
		while [ "${I}" -lt "${#W[@]}" ] && [ "${W[${I}]:0:2}" == "--" ]; do I=$((I + 1)); done
		NAME=${W[${I}]}
		STAGE=""
		if [ "${#W[@]}" -gt $((I + 2)) ]; then
			case "${W[$((I + 1))]}" in [Aa][Ss]) STAGE=${W[$((I + 2))]} ;; esac
		fi
		case "${STAGES}${SEEN}" in *" ${NAME} "*) ;; *)
			if [ "${NAME}" != "scratch" ]; then
				REF=""
				for B in ${KANBAN_BUILD_BASES}; do [ "${B%%=*}" == "${NAME}" ] && REF=${B#*=}; done
				[[ "${REF}" =~ @sha256:[0-9a-f]{64}$ ]] || fail "${DF} uses the base image ${NAME}, which KANBAN_BUILD_BASES does not pin by digest"
				ARGS="${ARGS} --build-context ${NAME}=docker-image://${REF}"
				SEEN="${SEEN}${NAME} "
			fi ;;
		esac
		[ -n "${STAGE}" ] && STAGES="${STAGES}${STAGE} "
	done < "${DF}"
	if grep -qiE '^#[[:space:]]*syntax[[:space:]]*=' "${DF}"; then
		[[ "${KANBAN_BUILD_SYNTAX}" =~ @sha256:[0-9a-f]{64}$ ]] || fail "${DF} names a # syntax= frontend, and KANBAN_BUILD_SYNTAX does not pin one by digest"
		ARGS="${ARGS} --build-arg BUILDKIT_SYNTAX=${KANBAN_BUILD_SYNTAX}"
	fi
	echo "${ARGS# }"
}

kanban_build()
{
	PATCHES=$(find "${PATCH_DIR}" -maxdepth 1 -name '*.patch' 2> /dev/null | sort)
	if [ "${UI_KANBAN_RELAY}" == "true" ]; then
		RELAY_PATCHES=$(find "${RELAY_PATCH_DIR}" -maxdepth 1 -name '*.patch' 2> /dev/null | sort)
		[ -n "${RELAY_PATCHES}" ] || fail "UI_KANBAN_RELAY=true, and ${RELAY_PATCH_DIR} has no patch"
		PATCHES="${PATCHES} ${RELAY_PATCHES}"
	fi
	[ -f "${PATCH_DIR}/0001-restore-project-kanban-board.patch" ] || fail "missing ${PATCH_DIR}/0001-restore-project-kanban-board.patch"
	command -v git > /dev/null 2>&1 || fail "git is required to fetch ${KANBAN_VK_REPO}"
	mkdir -p "${KANBAN_SRC_DIR}" || fail "cannot create ${KANBAN_SRC_DIR}"
	if [ ! -d "${KANBAN_SRC_DIR}/.git" ]; then
		git -C "${KANBAN_SRC_DIR}" init -q || fail "git init ${KANBAN_SRC_DIR} failed"
		git -C "${KANBAN_SRC_DIR}" remote add origin "${KANBAN_VK_REPO}" || fail "git remote add failed"
	fi
	# Only a checkout of KANBAN_VK_REPO is ever reset below - never a clone of something else at that path
	ORIGIN=$(git -C "${KANBAN_SRC_DIR}" remote get-url origin 2> /dev/null)
	[ "${ORIGIN}" == "${KANBAN_VK_REPO}" ] || fail "${KANBAN_SRC_DIR} is a checkout of '${ORIGIN}', not ${KANBAN_VK_REPO} - point KANBAN_SRC_DIR at an empty folder"
	# Exactly the pinned commit, fetched shallow by its sha - no branch or tag can move under the build
	if ! git -C "${KANBAN_SRC_DIR}" cat-file -e "${KANBAN_VK_SHA}^{commit}" 2> /dev/null; then
		echo "kanban: fetching ${KANBAN_VK_REPO} ${KANBAN_VK_SHA}"
		git -C "${KANBAN_SRC_DIR}" fetch -q --depth 1 origin "${KANBAN_VK_SHA}" \
			|| fail "cannot fetch ${KANBAN_VK_SHA} from ${KANBAN_VK_REPO}"
	fi
	# The checkout is build input only: every build starts from a clean tree at the pin
	git -C "${KANBAN_SRC_DIR}" checkout -q --force --detach "${KANBAN_VK_SHA}" || fail "checkout of ${KANBAN_VK_SHA} failed"
	git -C "${KANBAN_SRC_DIR}" clean -q -fdx || fail "git clean ${KANBAN_SRC_DIR} failed"
	HEAD_SHA=$(git -C "${KANBAN_SRC_DIR}" rev-parse HEAD)
	[ "${HEAD_SHA}" == "${KANBAN_VK_SHA}" ] || fail "checkout is ${HEAD_SHA}, not the pinned ${KANBAN_VK_SHA}"
	# Check each patch before applying it - never apply blind - and prove what they change afterwards: 0001 removes
	# the sunset gate, 0002 the vibe-kanban cloud's shutdown banner from the project pages, 0003 makes the cards goals
	# (kanban/README.md)
	for P in ${PATCHES}; do
		git -C "${KANBAN_SRC_DIR}" apply --check "${P}" || fail "$(basename "${P}") does not apply to ${KANBAN_VK_SHA}"
		git -C "${KANBAN_SRC_DIR}" apply "${P}" || fail "applying $(basename "${P}") failed"
	done
	BOARD_TSX=${KANBAN_SRC_DIR}/packages/web-core/src/pages/kanban/ProjectKanban.tsx
	if grep -q ProjectSunsetPage "${BOARD_TSX}"; then
		fail "${BOARD_TSX} still renders ProjectSunsetPage after the patches"
	fi
	SHELL_TSX=${KANBAN_SRC_DIR}/packages/remote-web/src/app/layout/RemoteAppShell.tsx
	if grep -qF "isExportRoute || (isSignedIn && isProjectRoute)" "${SHELL_TSX}"; then
		fail "${SHELL_TSX} still shows the cloud shutdown banner on the project pages after the patches"
	fi
	# 0003: the cards are goals (GOAL-n keys, the Goal noun) and the New Goal panel says what a new goal does
	EN_JSON=${KANBAN_SRC_DIR}/packages/web-core/src/i18n/locales/en/common.json
	ORGS_RS=${KANBAN_SRC_DIR}/crates/remote/src/db/organizations.rs
	if ! grep -qF '"newIssue": "New Goal"' "${EN_JSON}" || ! grep -qF '"newGoalDispatchNote"' "${EN_JSON}"; then
		fail "${EN_JSON} does not name the cards goals or lacks the New Goal note after the patches"
	fi
	grep -qF '"GOAL".to_string()' "${ORGS_RS}" || fail "${ORGS_RS} does not give a new organization the GOAL key prefix after the patches"
	# 0004: the settings dialog's host lookup is bounded, and with no host it says where this harness's agents are set
	HOSTS_TSX=${KANBAN_SRC_DIR}/packages/web-core/src/shared/dialogs/settings/settings/SettingsHostContext.tsx
	SETTINGS_EN=${KANBAN_SRC_DIR}/packages/web-core/src/i18n/locales/en/settings.json
	if ! grep -qF "hostLookupTimedOut" "${HOSTS_TSX}" || ! grep -qF "Agent workspaces" "${SETTINGS_EN}"; then
		fail "the settings dialog's host lookup is not bounded, or its no-host text does not name the agent runner, after the patches"
	fi
	# 0005: no web font from Google Fonts, no GitHub-star or Discord-count call
	CSS=${KANBAN_SRC_DIR}/packages/web-core/src/app/styles/new/index.css
	HOOKS=${KANBAN_SRC_DIR}/packages/web-core/src/shared/hooks
	if grep -qF "fonts.googleapis.com" "${CSS}" || grep -qF "api.github.com" "${HOOKS}/useGitHubStars.ts" \
		|| grep -qF "discord.com" "${HOOKS}/useDiscordOnlineCount.ts"; then
		fail "the board still loads a web font or calls GitHub or Discord for its counts after the patches"
	fi
	# 0006: harness mode hides the community and remote-service entry points
	MODE_TS=${KANBAN_SRC_DIR}/packages/web-core/src/shared/lib/harnessMode.ts
	SHELL_TSX2=${KANBAN_SRC_DIR}/packages/remote-web/src/app/layout/RemoteAppShell.tsx
	if [ ! -f "${MODE_TS}" ] || ! grep -qF "showCommunityLinks={!DO_AGENT_AWS_HARNESS_MODE}" "${SHELL_TSX2}"; then
		fail "the board's harness mode is missing after the patches"
	fi
	# 0007: a goal card's "## Full instructions" section is behind a labelled disclosure
	DISCLOSURE_TSX=${KANBAN_SRC_DIR}/packages/web-core/src/pages/kanban/GoalDescriptionDisclosure.tsx
	if [ ! -f "${DISCLOSURE_TSX}" ] || ! grep -qF "GoalDescriptionDisclosure" "${KANBAN_SRC_DIR}/packages/web-core/src/pages/kanban/KanbanIssuePanelContainer.tsx"; then
		fail "the goal card's full-instructions disclosure is missing after the patches"
	fi
	# 0008: the shapes on the page's sync origin, a comment saved before its text leaves the box, a 15-minute token
	SYNC_TS=${KANBAN_SRC_DIR}/packages/web-core/src/shared/lib/electric/syncOrigin.ts
	if [ ! -f "${SYNC_TS}" ] || ! grep -qF "toSyncOriginUrl(input)" "${KANBAN_SRC_DIR}/packages/web-core/src/shared/lib/electric/collections.ts" \
		|| ! grep -qF "isSavingComment" "${KANBAN_SRC_DIR}/packages/ui/src/components/IssueCommentsSection.tsx" \
		|| ! grep -qF "ACCESS_TOKEN_TTL_SECONDS: i64 = 900;" "${KANBAN_SRC_DIR}/crates/remote/src/auth/jwt.rs"; then
		fail "the board's sync origin, its saving comments or its 15-minute access token are missing after the patches"
	fi
	# relay on: its board shows Pair a remote device again (kanban/patches-relay/0101)
	if [ "${UI_KANBAN_RELAY}" == "true" ] && ! grep -qF "onPairHostClick={isSignedIn ? handlePairHostClick : undefined}" "${SHELL_TSX2}"; then
		fail "UI_KANBAN_RELAY=true, and the board still hides Pair a remote device after the relay's patches"
	fi
	PATCH_NAMES=$(for P in ${PATCHES}; do basename "${P}"; done | paste -sd, -)
	# and their contents, in the same order: an edited patch that kept its name still tells the images apart
	PATCHES_SHA256=$(for P in ${PATCHES}; do cat "${P}"; done | sha256sum | cut -c1-64)
	echo "kanban: ${KANBAN_VK_SHA} + ${PATCH_NAMES} applied; the board component is restored, without the cloud's banner, and its cards are goals"
	# The upstream Dockerfile, unchanged. A plain image build needs no ssh-agent: its --mount=type=ssh serves only
	# the private billing crate, which the Dockerfile strips when FEATURES is empty (kanban/README.md)
	# The base images and the # syntax= frontend by digest (base_args), both images' before either builds; the label
	# records the board's, so an image built before a pin moved is told apart (test-kanban.sh bundle 11)
	BOARD_BASES=$(base_args "${KANBAN_SRC_DIR}/crates/remote/Dockerfile") || exit 1
	if [ "${UI_KANBAN_RELAY}" == "true" ]; then
		RELAY_BASES=$(base_args "${KANBAN_SRC_DIR}/crates/relay-tunnel/Dockerfile") || exit 1
	fi
	BOARD_BASES_SHA256=$(printf '%s' "${BOARD_BASES}" | sha256sum | cut -c1-64)
	run "docker image build ${KANBAN_BUILD_OPTS} ${BOARD_BASES} --label org.opencontainers.image.source=${KANBAN_VK_REPO} --label org.opencontainers.image.revision=${KANBAN_VK_SHA} --label ${LABEL_KEY}.patches=${PATCH_NAMES} --label ${LABEL_KEY}.patches.sha256=${PATCHES_SHA256} --label ${LABEL_KEY}.bases.sha256=${BOARD_BASES_SHA256} -f ${KANBAN_SRC_DIR}/crates/remote/Dockerfile -t ${KANBAN_IMAGE} ${KANBAN_SRC_DIR}" \
		|| return $?
	# relay on: the upstream relay server, its Dockerfile unchanged, from the same checkout at the pin
	if [ "${UI_KANBAN_RELAY}" == "true" ]; then
		run "docker image build ${KANBAN_BUILD_OPTS} ${RELAY_BASES} --label org.opencontainers.image.source=${KANBAN_VK_REPO} --label org.opencontainers.image.revision=${KANBAN_VK_SHA} -f ${KANBAN_SRC_DIR}/crates/relay-tunnel/Dockerfile -t ${KANBAN_RELAY_IMAGE} ${KANBAN_SRC_DIR}" \
			|| fail "the relay image ${KANBAN_RELAY_IMAGE} did not build"
	fi
}

# write_env_file <path> - stdin to a file that is mode 600 from its creation (mktemp beside it, then mv)
write_env_file()
{
	TMP=$(mktemp "$1.XXXXXX") || fail "cannot write $1"
	if ! cat > "${TMP:?}" || ! mv -f "${TMP:?}" "${1:?}"; then
		rm -f "${TMP:?}"
		fail "cannot write $1"
	fi
}

kanban_init()
{
	if [ "${DRY_RUN}" != "false" ]; then
		echo "kanban: DRY_RUN - would create ${AUTH_FILE} when missing and refresh the env files beside it"
		return 0
	fi
	# wd/ can be owned by root when a docker run created it before the first ./run.sh: name the one-line fix
	if ! mkdir -p "${KANBAN_DIR}" 2> /dev/null || [ ! -w "${KANBAN_DIR}" ]; then
		fail "cannot write ${KANBAN_DIR} (is wd/ owned by root?); fix it with: sudo install -d -o \"\$(id -u)\" -g \"\$(id -g)\" ${KANBAN_DIR}"
	fi
	# private: nobody else can swap in a login file of their own before a start (the files inside are 600 too)
	chmod 700 "${KANBAN_DIR}" 2> /dev/null || echo "kanban: WARNING - cannot make ${KANBAN_DIR} private (chmod 700)" >&2
	quiet
	if [ ! -f "${AUTH_FILE}" ]; then
		write_env_file "${AUTH_FILE}" << EOF
# Self-hosted kanban board login and server secrets, generated by ./kanban.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Sign in at http://kanban.localhost:<home port>/ with the email and password below (the home page's Goals board
# tile signs you in), and the agent's goal sync (/agent/kanban-sync.py) signs in with the same pair. Keep the file
# private: mode 600, under the gitignored wd/. Delete it to rotate every value on the next ./stop.sh + ./run.sh;
# the board's data in its volume stays (the database password is re-applied on every start).
SELF_HOST_LOCAL_AUTH_EMAIL=agent@do-agent-aws.local
SELF_HOST_LOCAL_AUTH_PASSWORD=$(rand_hex 16)
VIBEKANBAN_REMOTE_JWT_SECRET=$(rand_hex 48)
ELECTRIC_ROLE_PASSWORD=$(rand_hex 24)
KANBAN_DB_PASSWORD=$(rand_hex 24)
EOF
		echo "kanban: generated the board login file ${AUTH_FILE} (mode 600)"
	fi
	chmod 600 "${AUTH_FILE}"
	# a login file from before the database had its own password gets one
	if ! grep -qE "^KANBAN_DB_PASSWORD=.+" "${AUTH_FILE}"; then
		printf 'KANBAN_DB_PASSWORD=%s\n' "$(rand_hex 24)" >> "${AUTH_FILE}" || { unquiet; fail "cannot update ${AUTH_FILE}"; }
		echo "kanban: added a database password to ${AUTH_FILE}"
	fi
	for K in SELF_HOST_LOCAL_AUTH_EMAIL ${SECRET_KEYS}; do
		grep -qE "^${K}=.+" "${AUTH_FILE}" || { unquiet; fail "${AUTH_FILE} has no value for ${K} - fix it, or delete the file to generate a new one"; }
	done
	# The per-container env files, derived on every start so a changed setting applies on the next start (a sidecar
	# whose env file changed is recreated). Hostnames are the network aliases (docker) = service names (compose).
	write_env_file "${KANBAN_DIR}/db.env" << EOF
POSTGRES_DB=remote
POSTGRES_USER=remote
POSTGRES_PASSWORD=$(kv KANBAN_DB_PASSWORD)
EOF
	write_env_file "${KANBAN_DIR}/server.env" << EOF
RUST_LOG=info,remote=info
SERVER_DATABASE_URL=postgres://remote:$(kv KANBAN_DB_PASSWORD)@kanban-db:5432/remote
SERVER_LISTEN_ADDR=0.0.0.0:${PORT_INTERNAL_KANBAN_BOARD}
ELECTRIC_URL=http://kanban-electric:3000
ELECTRIC_ROLE_PASSWORD=$(kv ELECTRIC_ROLE_PASSWORD)
SERVER_PUBLIC_BASE_URL=http://kanban.localhost:${PORT_EXTERNAL_HOME}
VIBEKANBAN_REMOTE_JWT_SECRET=$(kv VIBEKANBAN_REMOTE_JWT_SECRET)
SELF_HOST_LOCAL_AUTH_EMAIL=$(kv SELF_HOST_LOCAL_AUTH_EMAIL)
SELF_HOST_LOCAL_AUTH_PASSWORD=$(kv SELF_HOST_LOCAL_AUTH_PASSWORD)
DIGEST_ENABLED=false
EOF
	write_env_file "${KANBAN_DIR}/electric.env" << EOF
DATABASE_URL=postgresql://electric_sync:$(kv ELECTRIC_ROLE_PASSWORD)@kanban-db:5432/remote?sslmode=disable
PG_PROXY_PORT=65432
LOGICAL_PUBLISHER_HOST=kanban-electric
AUTH_MODE=insecure
ELECTRIC_INSECURE=true
ELECTRIC_MANUAL_TABLE_PUBLISHING=true
ELECTRIC_USAGE_REPORTING=false
ELECTRIC_FEATURE_FLAGS=allow_subqueries,tagged_subqueries
EOF
	# relay on: the relay reads the board's database (its hosts and sessions) and checks the board's session tokens
	if [ "${UI_KANBAN_RELAY}" == "true" ]; then
		write_env_file "${KANBAN_DIR}/relay.env" << EOF
RUST_LOG=info
SERVER_DATABASE_URL=postgres://remote:$(kv KANBAN_DB_PASSWORD)@kanban-db:5432/remote
RELAY_LISTEN_ADDR=0.0.0.0:${PORT_INTERNAL_KANBAN_RELAY}
VIBEKANBAN_REMOTE_JWT_SECRET=$(kv VIBEKANBAN_REMOTE_JWT_SECRET)
EOF
	fi
	unquiet
}

# kanban_db_password <container> - the database role's password, from the login file, on every start: a data volume
# keeps the password of its first start, and a new login file brings a new one. The SQL goes on psql's stdin over the
# container's local socket, never onto a command line.
kanban_db_password()
{
	if [ "${DRY_RUN}" != "false" ]; then
		echo "kanban: DRY_RUN - would set the database password in $1"
		return 0
	fi
	[ -n "$1" ] || fail "db-password needs the database container"
	quiet
	PW=$(kv KANBAN_DB_PASSWORD)
	printf "ALTER ROLE remote WITH PASSWORD '%s';\n" "${PW}" | docker exec -i "$1" psql -q -v ON_ERROR_STOP=1 -U remote -d remote > /dev/null
	RC=$?
	PW=""
	unquiet
	[ "${RC}" -eq 0 ] || fail "could not set the database password in $1"
}

# ours_container / ours_network <name> - 0 when it carries this harness's label (type-specific inspects: the DB
# container and its volume share a name)
ours_container()
{
	[ "$(docker container inspect -f "{{index .Config.Labels \"${LABEL_KEY}\"}}" "$1" 2> /dev/null)" == "${CONTAINER}" ]
}

ours_network()
{
	[ "$(docker network inspect -f "{{index .Labels \"${LABEL_KEY}\"}}" "$1" 2> /dev/null)" == "${CONTAINER}" ]
}

# on_network <container> <network> - 0 when the container is attached to the network
on_network()
{
	docker container inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$1" 2> /dev/null | grep -qxF "$2"
}

exists()
{
	docker container inspect "$1" > /dev/null 2>&1
}

# show_logs <name> - the last container log lines, with the login file's secrets redacted
show_logs()
{
	echo "kanban: last log lines of $1:" >&2
	docker container logs --tail 25 "$1" 2>&1 | redact >&2
}

# wait_healthy <name> <seconds> - until the container's healthcheck reports healthy
wait_healthy()
{
	[ "${DRY_RUN}" == "false" ] || return 0
	for i in $(seq 1 "$2"); do
		STATE=$(docker container inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$1" 2> /dev/null)
		case "${STATE}" in
		"running healthy")
			echo "kanban: $1 healthy after ${i}s"
			return 0
			;;
		dead*|"")
			# gone or dead for good; exited/restarting is retried by the restart policy until the timeout
			echo "kanban: $1 is not running (${STATE:-gone})" >&2
			show_logs "$1"
			return 1
			;;
		esac
		sleep 1
	done
	echo "kanban: $1 not healthy after $2s (state: ${STATE})" >&2
	show_logs "$1"
	return 1
}

# start_sidecar <name> <alias> <image> <env file> <network> <options> [<command>] - (re)create one sidecar on
# <network>, where <alias> is its name. A running sidecar of ours on the current image, env file and network is left
# alone, so ./run.sh can be re-run; a stopped one, or one on an older image, env file or network (their hash is a
# label), is replaced.
start_sidecar()
{
	NAME=$1
	ALIAS=$2
	IMG=$3
	ENVF=$4
	NET=$5
	OPTS=$6
	ARGS=$7
	ENV_HASH=$( { cat "${ENVF}" 2> /dev/null; echo "network=${NET}"; } | sha256sum | cut -c1-16)
	if exists "${NAME}"; then
		ours_container "${NAME}" || fail "a container named ${NAME} exists and is not this harness's sidecar (no ${LABEL} label) - refusing to touch it; set CONTAINER in .env to another name"
		RUNNING=$(docker container inspect -f '{{.State.Running}}' "${NAME}" 2> /dev/null)
		ON_IMAGE=$(docker container inspect -f '{{.Image}}' "${NAME}" 2> /dev/null)
		ON_ENV=$(docker container inspect -f "{{index .Config.Labels \"${LABEL_KEY}.env\"}}" "${NAME}" 2> /dev/null)
		WANT_IMAGE=$(docker image inspect -f '{{.Id}}' "${IMG}" 2> /dev/null)
		if [ "${RUNNING}" == "true" ] && [ "${ON_IMAGE}" == "${WANT_IMAGE}" ] && [ "${ON_ENV}" == "${ENV_HASH}" ]; then
			echo "kanban: ${NAME} already running"
			return 0
		fi
		run "docker container rm -f -v ${NAME} > /dev/null"
	fi
	run "docker container run -d --name ${NAME} --label ${LABEL} --label ${LABEL_KEY}.env=${ENV_HASH} --network $(shq "${NET}") --network-alias ${ALIAS} --restart unless-stopped --env-file ${ENVF} ${OPTS} ${IMG} ${ARGS} > /dev/null" \
		|| fail "could not start ${NAME}"
}

kanban_up()
{
	kanban_init
	docker image inspect "${KANBAN_IMAGE}" > /dev/null 2>&1 \
		|| fail "the board server image ${KANBAN_IMAGE} is missing - run ./build.sh (or ./kanban.sh build) first"
	# Two networks: the agent's, shared with the board server only, and an internal one (no route out) of the board
	# server, the database and Electric, so the two third-party images cannot reach the agent container at all
	for N in "${KANBAN_NETWORK}" "${KANBAN_INTERNAL_NETWORK}"; do
		INTERNAL=""
		[ "${N}" == "${KANBAN_INTERNAL_NETWORK}" ] && INTERNAL="--internal"
		if docker network inspect "${N}" > /dev/null 2>&1; then
			ours_network "${N}" || fail "a network named ${N} exists and is not this harness's (no ${LABEL} label) - refusing to use it"
			if [ -n "${INTERNAL}" ] && [ "$(docker network inspect -f '{{.Internal}}' "${N}")" != "true" ]; then
				fail "the network ${N} is not internal - remove it (./kanban.sh down) and run again"
			fi
		else
			run "docker network create ${INTERNAL} --label ${LABEL} $(shq "${N}") > /dev/null" || fail "could not create the network ${N}"
		fi
	done
	for V in "${KANBAN_DB_VOLUME}" "${KANBAN_ELECTRIC_VOLUME}"; do
		docker volume inspect "${V}" > /dev/null 2>&1 || run "docker volume create --label ${LABEL} ${V} > /dev/null" \
			|| fail "could not create the volume ${V}"
	done
	# Start order as upstream: the database, then the server (its migrations create the electric_sync role that
	# Electric logs in with), then Electric. The database password is applied before the server connects with it.
	start_sidecar "${KANBAN_DB_NAME}" kanban-db "${KANBAN_POSTGRES_IMAGE}" "${KANBAN_DIR}/db.env" "${KANBAN_INTERNAL_NETWORK}" \
		"-v ${KANBAN_DB_VOLUME}:/var/lib/postgresql/data --health-cmd 'pg_isready -h 127.0.0.1 -U remote -d remote' --health-interval 5s --health-timeout 5s --health-retries 5 --health-start-period 5s" \
		"postgres -c wal_level=logical"
	wait_healthy "${KANBAN_DB_NAME}" 90 || fail "the board database did not become healthy"
	kanban_db_password "${KANBAN_DB_NAME}"
	start_sidecar "${KANBAN_SERVER_NAME}" kanban-server "${KANBAN_IMAGE}" "${KANBAN_DIR}/server.env" "${KANBAN_INTERNAL_NETWORK}" \
		"--health-cmd 'wget --spider -q http://127.0.0.1:${PORT_INTERNAL_KANBAN_BOARD}/v1/health' --health-interval 5s --health-timeout 5s --health-retries 10 --health-start-period 10s"
	# the one sidecar on the agent's network too, where the agent reaches it by the same name
	on_network "${KANBAN_SERVER_NAME}" "${KANBAN_NETWORK}" \
		|| run "docker network connect --alias kanban-server $(shq "${KANBAN_NETWORK}") ${KANBAN_SERVER_NAME}" \
		|| fail "could not connect ${KANBAN_SERVER_NAME} to ${KANBAN_NETWORK}"
	wait_healthy "${KANBAN_SERVER_NAME}" 180 || fail "the board server did not become healthy"
	start_sidecar "${KANBAN_ELECTRIC_NAME}" kanban-electric "${KANBAN_ELECTRIC_IMAGE}" "${KANBAN_DIR}/electric.env" "${KANBAN_INTERNAL_NETWORK}" \
		"-w /app -v ${KANBAN_ELECTRIC_VOLUME}:/app/persistent --health-interval 5s --health-timeout 5s --health-retries 10 --health-start-period 10s"
	wait_healthy "${KANBAN_ELECTRIC_NAME}" 120 || fail "Electric (the board's live sync) did not become healthy"
	# relay on: the relay, after the server (its migrations create the tables the relay reads), on the internal network
	# for the database and on the agent's, where the agent's runner connects to it as a host and the home proxy sends
	# the board's kanban.localhost/v1/relay/ requests
	if [ "${UI_KANBAN_RELAY}" == "true" ]; then
		docker image inspect "${KANBAN_RELAY_IMAGE}" > /dev/null 2>&1 \
			|| fail "the relay image ${KANBAN_RELAY_IMAGE} is missing - run ./build.sh (or ./kanban.sh build) with UI_KANBAN_RELAY=true first"
		start_sidecar "${KANBAN_RELAY_NAME}" kanban-relay "${KANBAN_RELAY_IMAGE}" "${KANBAN_DIR}/relay.env" "${KANBAN_INTERNAL_NETWORK}" \
			"--health-cmd 'wget --spider -q http://127.0.0.1:${PORT_INTERNAL_KANBAN_RELAY}/health' --health-interval 5s --health-timeout 5s --health-retries 10 --health-start-period 10s"
		on_network "${KANBAN_RELAY_NAME}" "${KANBAN_NETWORK}" \
			|| run "docker network connect --alias kanban-relay $(shq "${KANBAN_NETWORK}") ${KANBAN_RELAY_NAME}" \
			|| fail "could not connect ${KANBAN_RELAY_NAME} to ${KANBAN_NETWORK}"
		wait_healthy "${KANBAN_RELAY_NAME}" 60 || fail "the relay did not become healthy"
	fi
	echo "kanban: board up at http://kanban.localhost:${PORT_EXTERNAL_HOME}/ (through the home port; the home page's Goals board tile signs you in); the login is in ${AUTH_FILE}"
}

kanban_down()
{
	for NAME in "${KANBAN_RELAY_NAME}" "${KANBAN_SERVER_NAME}" "${KANBAN_ELECTRIC_NAME}" "${KANBAN_DB_NAME}"; do
		if exists "${NAME}"; then
			if ours_container "${NAME}"; then
				run "docker container rm -f -v ${NAME} > /dev/null" && echo "kanban: removed ${NAME}"
			else
				echo "kanban: WARNING - ${NAME} is not this harness's sidecar (no ${LABEL} label); left untouched" >&2
			fi
		fi
	done
	for N in "${KANBAN_NETWORK}" "${KANBAN_INTERNAL_NETWORK}"; do
		docker network inspect "${N}" > /dev/null 2>&1 || continue
		if ours_network "${N}"; then
			run "docker network rm $(shq "${N}") > /dev/null" && echo "kanban: removed the network ${N}" \
				|| echo "kanban: the network ${N} is still in use (is the agent container still running?); left in place" >&2
		else
			echo "kanban: WARNING - the network ${N} is not this harness's; left untouched" >&2
		fi
	done
	if docker volume inspect "${KANBAN_DB_VOLUME}" > /dev/null 2>&1; then
		echo "kanban: the board's data stays in the volumes ${KANBAN_DB_VOLUME} and ${KANBAN_ELECTRIC_VOLUME} (docker volume rm ${KANBAN_DB_VOLUME} ${KANBAN_ELECTRIC_VOLUME} deletes it)"
	fi
}

kanban_status()
{
	docker ps -a --filter "label=${LABEL}" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
	for V in "${KANBAN_DB_VOLUME}" "${KANBAN_ELECTRIC_VOLUME}"; do
		docker volume inspect "${V}" > /dev/null 2>&1 && echo "volume ${V}: present" || echo "volume ${V}: absent"
	done
	[ -f "${AUTH_FILE}" ] && echo "login file: ${AUTH_FILE}" || echo "login file: not generated yet (the first ./run.sh creates ${AUTH_FILE})"
	[ "$(docker container inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "${KANBAN_SERVER_NAME}" 2> /dev/null)" == "healthy" ]
}

case "$1" in
	"build")
		kanban_build
		;;
	"init")
		kanban_init
		;;
	"up")
		kanban_up
		;;
	"db-password")
		kanban_db_password "${2:-${KANBAN_DB_NAME}}"
		;;
	"down")
		kanban_down
		;;
	"status")
		kanban_status
		;;
	*)
		echo "Usage: $0 build|init|up|db-password [<container>]|down|status (see docs/manual/boards.md \"Kanban board\")"
		exit 1
		;;
esac
