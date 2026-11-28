#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Host-side tests of the self-hosted kanban board (docs/manual/boards.md "Kanban board"). Like test-exec.sh they run on the
# HOST, not in the in-container /test*.sh suite: the board's server is its own image and runs in sidecar
# containers that test.sh's throwaway container has no access to.
#   ./test-kanban.sh bundle - the board server image's static bundle is the restored board, not the sunset page
#                             (test.sh runs it; it needs only the image ./build.sh built)
#   ./test-kanban.sh live   - with ./run.sh up: the board answers through the home port's kanban.localhost route
#   ./test-kanban.sh neighbours - with ./run.sh up (docker target): the board's database and Electric are on their
#                             internal network alone and cannot reach the agent container's listeners; the board
#                             server, the agent's one neighbour, is refused by the home port (421 for a name that is
#                             not a loopback one, 403 on one) and gets no answer from the
#                             terminal (not run by test.sh)
# Each check FAILS if the property is removed:
#   bundle 1. the image KANBAN_IMAGE exists and its /srv/static holds the app (index.html)
#   bundle 2. the sunset copy of vibe-kanban 0.1.44 ("has been retired", "Project sunset") is in no file of it
#   bundle 3. the restored board's own string literals are: "kanban-left", "kanban-right" and "kanban-separator",
#             the board and issue-panel layout of the restored ProjectKanban.tsx (an unpatched build bundles none
#             of them). "noProjectFound" is only reported: an unpatched build bundles it too (an i18n string)
#   bundle 4. no telemetry endpoint is compiled in: no Sentry DSN ingest host (ingest[.<region>].sentry.io) and no
#             PostHog project key (phc_...) in any file - both match the npm runner's prebuilt binary, which has
#             them; the library code of both stays (its default hosts are never called without a key)
#   bundle 5. the image's labels name the pinned commit KANBAN_VK_SHA and exactly the vendored patches
#             kanban/patches/*.patch, in order, with the sha256 of their contents (an image built before a patch was
#             added, or before a patch was edited under the same name, fails); with the relay on (UI_KANBAN_RELAY=true)
#             the relay's kanban/patches-relay/*.patch follow them, as kanban.sh build applies them
#   bundle 6. the board names its cards goals, and its New Goal panel says what a new goal does (kanban/patches/0003):
#             the bundle carries the panel's note ("A new goal goes to the goals file") and the English Goal help text
#             ("Each goal represents a feature or problem to solve"). The Issue wording stays in the bundle as the
#             components' t() defaults and in the other languages' files, which the English board never shows, so
#             its count is only reported
#   bundle 7. the settings dialog says where this harness's agents are set when no host is linked (kanban/patches/0004):
#             the bundle carries "open the Agent workspaces tile on the harness home page"
#   bundle 8. no optional third-party fetch is compiled in (kanban/patches/0005): no Google Fonts stylesheet
#             (fonts.googleapis.com), no GitHub star count (api.github.com/repos/BloopAI) and no Discord online count
#             (discord.com/api/guilds) in any file
#   bundle 9. a goal card's full instructions sit behind a labelled disclosure (kanban/patches/0007): the bundle carries
#             "Show full instructions" and "Hide full instructions"
#   bundle 10. the shapes on a second origin and comments saved before their text leaves the box (kanban/patches/0008):
#              the bundle reads the harness-sync-origin meta and carries "Saving..." and the not-saved message
#   bundle 11. the base images by digest (H-4b): kanban.sh pins every image a FROM of the board's upstream Dockerfile
#              names (KANBAN_BUILD_BASES, ECR Public) and its # syntax= frontend (KANBAN_BUILD_SYNTAX), the image's label
#              says it was built with those pins, and kanban.sh refuses an unpinned base, a pin by tag and an unpinned
#              frontend (PLANTED Dockerfiles; CONTROL: a stage name, scratch and --platform); the two sidecar images
#              (KANBAN_POSTGRES_IMAGE, KANBAN_ELECTRIC_IMAGE) are pinned by digest
#   live 1. a local login with the generated email and password, sent to the published home port with
#           Host kanban.localhost (the home proxy's route), answers 200 with an access token. This is the
#           database check: a login writes the user and its session (with the database stopped it answers 500,
#           while / still answers 200 - the static app shell proves nothing)
#   live 2. the same login with a wrong password answers 401: local sign-in is on and checks the password. It is
#           NOT a database check: the server compares the password before it queries the database, so a
#           stopped database still answers 401 (measured)
#   live 3. the project list of the login's organization answers 200 (a database read)
#   live 4. / through the route is the board's app ("Vibe Kanban Remote") with the home badge injected
#   live 5. the one-click sign-in behind the home page's Goals board tile (/__harness/sign-in on the route), sent
#           as the tile's click sends it (Referer: the home page), answers a no-store page that may not be framed,
#           stores a board session in the board app's IndexedDB and carries no password; without that Referer, or
#           with another site's Referer or Origin, it answers 403, and a foreign Host (what a DNS-rebinding page
#           sends) gets no session
#   live 6. the home page's two vibe-kanban tiles open in a new tab: the Goals board tile the one-click sign-in,
#           the Agent workspaces tile the runner's /workspaces (its start page sends a first visit through an
#           onboarding that ends in a vibe-kanban cloud sign-in), and the runner's app answers there with the home
#           badge (the board's has it too, live 4). What each tab shows takes a browser; this check reads the
#           page and the answers
#   live 7. both routes answer with exactly the own-origin Content-Security-Policy (every source the page's own
#           origin, its websocket, data:/blob: or loopback frames): the browser refuses the third-party requests
#           compiled into vibe-kanban 0.1.44 (Sentry and PostHog in the runner, Google Fonts, the GitHub star and
#           Discord counts in both). The board's policy also lets the page reach its live-sync origin,
#           http://kanban-sync.localhost:<port>, and nothing else more
#   live 8. the home page's same-origin status probes answer 204 (GET-only, status-only, like every tile probe):
#           /__probe/kanban (the sign-in helper's read of the board's database - with the database stopped it answers
#           500) and /__probe/vk-runner
#   live 9. the container start seeded the board, with no fire needed (/agent/kanban-sync.py seed, started by
#           ui-start.sh): within 90 s the one-click sign-in lands on /projects/<id>, the agent's project - its id
#           derives from CONTAINER (KANBAN_PROJECT) as kanban-sync.py and the sign-in derive it, its name is the goal
#           set's - which has the four columns and at least one card - with no goals file, the card of the shipped
#           default goals' standing goal
#   live 10. the agent runner's database is in the persisted host folder AGENT_STATE_PATH_EXTERNAL/vibe-kanban
#           (AGENT_STATE_VOL_MAP), so its settings, workspaces and keys survive ./stop.sh and ./run.sh (the round
#           trip itself needs a stop and a run, so it is not run here)
#   live 11. a request from another site's page (Origin: https://evil.example) gets no Access-Control-Allow-Origin or
#           -Credentials header on the board route: the board server allows any Origin with credentials, and the
#           home proxy drops both
#   live 12. the agent runner's persisted settings have analytics_enabled false, the value a first start gives them;
#           settings the user had before may have it true, and then this start's one-line notice must be in
#           wd/ui/vibe-kanban-analytics.notice, which every start rewrites (docker target; on compose the start log is
#           not on the host, so true fails)
#   live 13. the board's access token lasts 15 minutes (kanban/patches/0008): the login's token has exp - iat = 900.
#            With 120 s a token expired while a request waited behind the shapes' long-polls
#   live 14. the board's live sync on its second origin (kanban/patches/0008 and the home proxy's kanban-sync.localhost
#            route): the board page names it (the harness-sync-origin meta); a shape read there from the board's
#            origin answers 200 with the Electric headers, Access-Control-Allow-Origin for that origin alone, the five
#            Electric headers exposed and no Allow-Credentials; from another origin it carries no CORS header; and
#            the sync host serves nothing but the shapes (404 elsewhere)
#   live 15. with the relay on (UI_KANBAN_RELAY=true; skipped when it is off): the agent runner is signed in to the board
#            (its /api/info through vk-runner.localhost says loggedin), the board lists it as an online host (its
#            machine id), and the relay opens a session to it through the board's route (POST /v1/relay/create/<host>
#            on kanban.localhost answers 200 with a session id). The runner's sign-in is stored before it starts, not
#            made through the runner's own sign-in, which turns its analytics on: live 12 fails then
#   live 16. one card says what the agent does next (kanban-sync.py's agent line): the card of the goal the loop's next
#            fire starts on - the first open goal of the goals file on the host (the default goals' standing goal
#            without one), read as kanban-sync.py reads it - leads its description with one "**Agent:**" line, is an
#            open card (not Done or Cancelled), and no other card of the project has the line; the board's order
#            (KANBAN_CARD_ORDER) is not assumed
# Prints "Test-kanban-<bundle|live> PASSED" or "... FAILED: <reason>" and exits 0 or 1. Never prints the
# password or the session token: the login is sent on stdin and the token in a mode-600 header file.

source .env

D=$(mktemp -d)
trap 'rm -rf "${D:?}"' EXIT

NAME=$1
fail()
{
	echo "Test-kanban-${NAME} FAILED: $1"
	exit 1
}

bundle()
{
	docker image inspect "${KANBAN_IMAGE}" > /dev/null 2>&1 \
		|| fail "the board server image ${KANBAN_IMAGE} is missing - run ./build.sh (or ./kanban.sh build)"
	echo "image ${KANBAN_IMAGE} $(docker image inspect -f '{{.Id}} revision={{index .Config.Labels "org.opencontainers.image.revision"}}' "${KANBAN_IMAGE}")"
	# one line per marker: <marker>|<number of files under /srv/static that contain it>
	COUNTS=$(docker container run --rm --network none --no-healthcheck --entrypoint /bin/sh "${KANBAN_IMAGE}" -c '
		cd /srv/static || exit 3
		[ -f index.html ] || exit 4
		for m in "has been retired" "Project sunset" "kanban-right" "kanban-separator" "kanban-left" "noProjectFound" \
			"A new goal goes to the goals file" "Each goal represents a feature or problem to solve" \
			"Each issue represents a feature or problem to solve" \
			"open the Agent workspaces tile on the harness home page" \
			"fonts.googleapis.com" "api.github.com/repos/BloopAI" "discord.com/api/guilds" \
			"Show full instructions" "Hide full instructions" \
			"harness-sync-origin" "Saving..." "Your comment was not saved"; do
			echo "${m}|$(grep -rlF "${m}" . | wc -l)"
		done
		echo "sentry DSN ingest host|$(grep -rlE "ingest(\.[a-z0-9-]+)?\.sentry\.io" . | wc -l)"
		echo "PostHog project key|$(grep -rlE "phc_[A-Za-z0-9]{20,}" . | wc -l)"')
	RC=$?
	[ "${RC}" -eq 0 ] || fail "no /srv/static app in ${KANBAN_IMAGE} (rc=${RC})"
	while IFS= read -r LINE; do
		echo "  files containing: ${LINE}"
	done <<< "${COUNTS}"
	echo "ok 1 - ${KANBAN_IMAGE} serves an app from /srv/static"
	count()
	{
		echo "${COUNTS}" | grep -F "$1|" | cut -d'|' -f2
	}
	for m in "has been retired" "Project sunset"; do
		[ "$(count "${m}")" == "0" ] || fail "the bundle carries the sunset copy '${m}' - the board-restore patch is not in this build"
	done
	echo "ok 2 - no sunset copy (has been retired, Project sunset)"
	for m in "kanban-left" "kanban-right" "kanban-separator"; do
		[ "$(count "${m}")" -ge 1 ] 2>/dev/null || fail "the restored board's '${m}' is not in the bundle"
	done
	echo "ok 3 - the restored board is in the bundle (kanban-left, kanban-right, kanban-separator)"
	for m in "sentry DSN ingest host" "PostHog project key"; do
		[ "$(count "${m}")" == "0" ] || fail "the bundle carries a ${m} - a telemetry-enabled build (kanban/README.md)"
	done
	echo "ok 4 - no telemetry endpoint compiled into the bundle (no Sentry DSN ingest host, no PostHog project key)"
	# kanban.sh build labels the image with the pinned commit and the patches it applied, in order (an image built
	# before a patch was added lacks it: one without 0002 still shows the cloud's shutdown banner); with the relay on,
	# the relay's patches after the vendored ones
	WANT_FILES=$(find kanban/patches -maxdepth 1 -name '*.patch' | sort)
	if [ "${UI_KANBAN_RELAY}" == "true" ]; then
		RELAY_FILES=$(find kanban/patches-relay -maxdepth 1 -name '*.patch' 2> /dev/null | sort)
		[ -n "${RELAY_FILES}" ] || fail "UI_KANBAN_RELAY=true, and kanban/patches-relay has no patch"
		WANT_FILES="${WANT_FILES}"$'\n'"${RELAY_FILES}"
	fi
	WANT=$(echo "${WANT_FILES}" | while read -r P; do [ -n "${P}" ] && basename "${P}"; done | paste -sd, -)
	WANT_SHA=$(echo "${WANT_FILES}" | while read -r P; do [ -n "${P}" ] && cat "${P}"; done | sha256sum | cut -c1-64)
	HAVE=$(docker image inspect -f '{{index .Config.Labels "do-agent-aws.kanban.patches"}}' "${KANBAN_IMAGE}")
	HAVE_SHA=$(docker image inspect -f '{{index .Config.Labels "do-agent-aws.kanban.patches.sha256"}}' "${KANBAN_IMAGE}")
	REV=$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "${KANBAN_IMAGE}")
	[ -n "${WANT}" ] || fail "no vendored patch under kanban/patches"
	[ "${HAVE}" == "${WANT}" ] || fail "${KANBAN_IMAGE} was built with the patches [${HAVE}], not [${WANT}] - run ./build.sh (or ./kanban.sh build)"
	[ "${HAVE_SHA}" == "${WANT_SHA}" ] \
		|| fail "${KANBAN_IMAGE} was built from other patch contents (sha256 ${HAVE_SHA:-not labelled}; the patches now: ${WANT_SHA}) - run ./build.sh (or ./kanban.sh build)"
	[ "${REV}" == "${KANBAN_VK_SHA}" ] || fail "${KANBAN_IMAGE} was built from ${REV:-an unlabelled commit}, not the pin ${KANBAN_VK_SHA} - run ./build.sh"
	echo "ok 5 - built from the pin ${KANBAN_VK_SHA:0:9} with every vendored patch, in order and as they are now (${WANT}; sha256 ${WANT_SHA:0:12})"
	for m in "A new goal goes to the goals file" "Each goal represents a feature or problem to solve"; do
		[ "$(count "${m}")" -ge 1 ] 2>/dev/null || fail "the bundle lacks '${m}' - the Goals board patch (0003) is not in this build"
	done
	echo "ok 6 - the board's cards are goals, and its New Goal panel says what a new goal does"
	[ "$(count "open the Agent workspaces tile on the harness home page")" -ge 1 ] 2>/dev/null \
		|| fail "the bundle lacks the settings dialog's no-host guidance - patch 0004 is not in this build"
	echo "ok 7 - with no host linked, the settings dialog says the agents are set in the agent runner (the Agent workspaces tile)"
	for m in "fonts.googleapis.com" "api.github.com/repos/BloopAI" "discord.com/api/guilds"; do
		[ "$(count "${m}")" == "0" ] || fail "the bundle still fetches '${m}' - patch 0005 is not in this build"
	done
	echo "ok 8 - no optional third-party fetch compiled in (no Google Fonts, no GitHub star count, no Discord count)"
	for m in "Show full instructions" "Hide full instructions"; do
		[ "$(count "${m}")" -ge 1 ] 2>/dev/null || fail "the bundle lacks '${m}' - patch 0007 is not in this build"
	done
	echo "ok 9 - a goal card's full instructions sit behind a labelled disclosure"
	for m in "harness-sync-origin" "Saving..." "Your comment was not saved"; do
		[ "$(count "${m}")" -ge 1 ] 2>/dev/null || fail "the bundle lacks '${m}' - patch 0008 is not in this build"
	done
	echo "ok 10 - the board reads its sync origin from the page and saves a comment before its text leaves the box"
	# 11. the base images by digest: kanban.sh's own base_args, read from it as test-kubernetes.sh reads run.sh's function
	eval "$(sed -n '/^base_args()/,/^}/p' kanban.sh)"
	declare -F base_args > /dev/null || fail "11: kanban.sh has no base_args"
	DF=${KANBAN_SRC_DIR}/crates/remote/Dockerfile
	[ -f "${DF}" ] || fail "11: no upstream checkout at ${KANBAN_SRC_DIR} (./build.sh makes it)"
	ARGS=$( (base_args "${DF}") 2>&1) || fail "11: kanban.sh refuses the board's Dockerfile at the pin: ${ARGS}"
	# every image the Dockerfile's FROM lines name (stage names and scratch are not), read here on their own
	FROMS=$(awk 'toupper($1) == "FROM" { i = 2; while ($i ~ /^--/) i++; n = $i; if (!(n in st) && n != "scratch") print n; if (toupper($(i + 1)) == "AS") st[$(i + 2)] = 1 }' "${DF}" | sort -u)
	[ -n "${FROMS}" ] || fail "11: no FROM image in ${DF}"
	for F in ${FROMS}; do
		[[ " ${ARGS} " =~ " --build-context ${F}=docker-image://"[^\ ]+@sha256:[0-9a-f]{64}" " ]] || fail "11: the board build does not pin its base image ${F} by digest: ${ARGS}"
	done
	if grep -qiE '^#[[:space:]]*syntax[[:space:]]*=' "${DF}"; then
		[[ " ${ARGS} " =~ " --build-arg BUILDKIT_SYNTAX="[^\ ]+@sha256:[0-9a-f]{64}" " ]] || fail "11: the board build does not pin its # syntax= frontend by digest: ${ARGS}"
	fi
	HAVE=$(docker image inspect -f '{{index .Config.Labels "do-agent-aws.kanban.bases.sha256"}}' "${KANBAN_IMAGE}")
	WANT=$(printf '%s' "${ARGS}" | sha256sum | cut -c1-64)
	[ "${HAVE}" == "${WANT}" ] || fail "11: ${KANBAN_IMAGE} was built from other base images (sha256 ${HAVE:-not labelled}; the pins now: ${WANT}) - run ./build.sh (or ./kanban.sh build)"
	# PLANTED: a base image without a pin, a pin by tag only, and a # syntax= line with no frontend pin are refused;
	# CONTROL: a stage name, scratch and a --platform flag are not base images to pin
	printf 'FROM --platform=linux/amd64 node:20-alpine AS web\nFROM web\nFROM scratch\n' > "${D}/Dockerfile.ok"
	OK=$( (base_args "${D}/Dockerfile.ok") 2>&1) || fail "11: CONTROL: a stage name, scratch or a --platform flag is refused: ${OK}"
	[ "$(grep -o -- '--build-context' <<< "${OK}" | wc -l | tr -d ' ')" == "1" ] || fail "11: CONTROL: the stage name or scratch got a build context: ${OK}"
	printf 'FROM alpine:3.20\n' > "${D}/Dockerfile.unpinned"
	OUT=$( (base_args "${D}/Dockerfile.unpinned") 2>&1) && fail "11: a base image KANBAN_BUILD_BASES does not pin is accepted: ${OUT}"
	OUT=$( (KANBAN_BUILD_BASES="node:20-alpine=public.ecr.aws/docker/library/node:20-alpine"; base_args "${D}/Dockerfile.ok") 2>&1) && fail "11: a pin by tag only is accepted: ${OUT}"
	printf '# syntax=docker/dockerfile:1.6\nFROM node:20-alpine\n' > "${D}/Dockerfile.syntax"
	OUT=$( (KANBAN_BUILD_SYNTAX=docker/dockerfile:1.6; base_args "${D}/Dockerfile.syntax") 2>&1) && fail "11: a # syntax= frontend without a pin by digest is accepted: ${OUT}"
	for I in "${KANBAN_POSTGRES_IMAGE}" "${KANBAN_ELECTRIC_IMAGE}"; do
		[[ "${I}" =~ @sha256:[0-9a-f]{64}$ ]] || fail "11: the sidecar image ${I} is not pinned by digest"
	done
	echo "ok 11 - the board's base images ($(echo ${FROMS} | tr ' ' ',')) and its # syntax= frontend are pinned by digest and the image was built with those pins; an unpinned base, a pin by tag and an unpinned frontend are refused (control: stage names, scratch and --platform pass); both sidecar images are pinned by digest"
}

live()
{
	AUTH=${KANBAN_DIR}/kanban.env
	[ -f "${AUTH}" ] || fail "no board login file ${AUTH} - run ./run.sh first"
	EMAIL=$(sed -n 's/^SELF_HOST_LOCAL_AUTH_EMAIL=//p' "${AUTH}" | tail -1)
	PASSWORD=$(sed -n 's/^SELF_HOST_LOCAL_AUTH_PASSWORD=//p' "${AUTH}" | tail -1)
	if [ -z "${EMAIL}" ] || [ -z "${PASSWORD}" ]; then
		fail "${AUTH} lacks the email or the password"
	fi
	URL=http://127.0.0.1:${PORT_EXTERNAL_HOME}
	ROUTE="Host: kanban.localhost:${PORT_EXTERNAL_HOME}"
	login()
	{
		# login <password> <body file> - prints the HTTP code; the body (with the token) stays in the file
		printf '{"email":"%s","password":"%s"}' "${EMAIL}" "$1" | curl -s -o "$2" -w '%{http_code}' --max-time 10 \
			-H "${ROUTE}" -H "Content-Type: application/json" --data @- "${URL}/v1/auth/local/login"
	}
	HTTP=$(login "${PASSWORD}" "${D}/login.json")
	TOKEN=$(sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p' "${D}/login.json")
	if [ "${HTTP}" != "200" ] || [ -z "${TOKEN}" ]; then
		fail "login through ${URL} (Host kanban.localhost) answered ${HTTP}, token $(if [ -n "${TOKEN}" ]; then echo present; else echo absent; fi)"
	fi
	echo "ok 1 - login through the home port's kanban.localhost route: 200 with an access token (${#TOKEN} chars; the database answered)"
	HTTP=$(login "not-the-${PASSWORD}" "${D}/bad.json")
	[ "${HTTP}" == "401" ] || fail "a wrong password answered ${HTTP}, not 401"
	echo "ok 2 - a wrong password: 401 (local sign-in checks the password)"
	( umask 077; printf 'Authorization: Bearer %s\n' "${TOKEN}" > "${D}/auth.hdr" )
	HTTP=$(curl -s -o "${D}/orgs.json" -w '%{http_code}' --max-time 10 -H "${ROUTE}" -H @"${D}/auth.hdr" "${URL}/v1/organizations")
	ORG=$(sed -n 's/^{"organizations":\[{"id":"\([^"]*\)".*/\1/p' "${D}/orgs.json")
	if [ "${HTTP}" != "200" ] || [ -z "${ORG}" ]; then
		fail "the organization list answered ${HTTP}"
	fi
	HTTP=$(curl -s -o "${D}/projects.json" -w '%{http_code}' --max-time 10 -H "${ROUTE}" -H @"${D}/auth.hdr" \
		"${URL}/v1/projects?organization_id=${ORG}")
	if [ "${HTTP}" != "200" ] || ! grep -q '"projects":' "${D}/projects.json"; then
		fail "the project list answered ${HTTP}"
	fi
	echo "ok 3 - the project list: 200 ($(grep -o '"id":' "${D}/projects.json" | wc -l) project(s))"
	BODY=$(curl -s --max-time 10 -H "${ROUTE}" "${URL}/")
	echo "${BODY}" | grep -qF "<title>Vibe Kanban Remote</title>" || fail "/ through kanban.localhost is not the board's app"
	echo "${BODY}" | grep -qF "href=\"//localhost:${PORT_EXTERNAL_HOME}/\"" || fail "the board's page lacks the home badge"
	echo "ok 4 - / through kanban.localhost: the board's app, with the home badge"
	HOME_REF="Referer: http://localhost:${PORT_EXTERNAL_HOME}/"
	HTTP=$(curl -s -D "${D}/signin.hdr" -o "${D}/signin.html" -w '%{http_code}' --max-time 15 -H "${ROUTE}" -H "${HOME_REF}" "${URL}/__harness/sign-in")
	if [ "${HTTP}" != "200" ] || ! grep -qF 'indexedDB.open("rf-auth", 1)' "${D}/signin.html" \
		|| ! grep -qF '"access_token": "' "${D}/signin.html"; then
		fail "the one-click sign-in answered ${HTTP} without a board session for the board app"
	fi
	grep -qiF 'cache-control: no-store' "${D}/signin.hdr" || fail "the one-click sign-in page may be cached"
	grep -qF -- "${PASSWORD}" "${D}/signin.html" && fail "the one-click sign-in page carries the password"
	grep -qi '^x-frame-options: deny' "${D}/signin.hdr" || fail "the one-click sign-in page may be framed"
	for HDR in "Referer:" "Referer: https://evil.example/" "Origin: https://evil.example"; do
		HTTP=$(curl -s -o "${D}/signin-x.html" -w '%{http_code}' --max-time 15 -H "${ROUTE}" -H "${HDR}" "${URL}/__harness/sign-in")
		if [ "${HTTP}" != "403" ] || grep -qF 'access_token' "${D}/signin-x.html"; then
			fail "a sign-in that did not come from the home page answered ${HTTP} (${HDR})"
		fi
	done
	HTTP=$(curl -s -o "${D}/signin-evil.html" -w '%{http_code}' --max-time 15 -H "Host: evil.example:${PORT_EXTERNAL_HOME}" "${URL}/__harness/sign-in")
	if [ "${HTTP}" == "200" ] || grep -qF 'access_token' "${D}/signin-evil.html"; then
		fail "a foreign Host got a board session from the sign-in (http=${HTTP})"
	fi
	echo "ok 5 - the one-click sign-in: from the home page, a no-store, unframable page with a board session for the board app's IndexedDB, no password; no Referer or another site's gets 403; a foreign Host gets none (http=${HTTP})"
	PAGE=$(curl -s --max-time 10 "${URL}/")
	# new_tab_tile <host route> <path> - 0 when the home page has that tile and it opens in a new tab
	new_tab_tile()
	{
		# the tile's <li> and its link, each attribute matched on its own (home-render.sh's tile() orders them data-host,
		# data-probe, data-path; the link's rel is opener or noopener)
		echo "${PAGE}" | grep -o "<li class=\"tile\"[^>]*data-host=\"$1\"[^>]*><span class=\"dot\"></span><a [^>]*>" \
			| grep -F "data-path=\"$2\"" | grep -qE 'target="_blank" rel="(no)?opener"'
	}
	new_tab_tile kanban /__harness/sign-in || fail "the home page's Goals board tile does not open the one-click sign-in in a new tab"
	new_tab_tile vk-runner /workspaces || fail "the home page's agent runner tile does not open the runner's /workspaces in a new tab"
	# the runner starts later than the board after a ./run.sh: give it up to 90 s
	for i in $(seq 1 30); do
		curl -s --max-time 5 -H "Host: vk-runner.localhost:${PORT_EXTERNAL_HOME}" "${URL}/workspaces" > "${D}/runner.html"
		grep -qF "<title>Vibe Kanban</title>" "${D}/runner.html" && break
		[ "${i}" -eq 30 ] && fail "/workspaces through vk-runner.localhost is not the agent runner's app (90 s)"
		sleep 3
	done
	grep -qF "href=\"//localhost:${PORT_EXTERNAL_HOME}/\"" "${D}/runner.html" || fail "the agent runner's page lacks the home badge"
	echo "ok 6 - the home page opens both views in new tabs: the board through the one-click sign-in, the agent runner at /workspaces (its app answers there, with the home badge)"
	for H in kanban vk-runner; do
		O=${H}.localhost:${PORT_EXTERNAL_HOME}
		# the board's page also connects to its live-sync origin (live 14), plain http: the shapes are fetch long-polls
		SYNC_SRC=""
		[ "${H}" == "kanban" ] && SYNC_SRC=" http://kanban-sync.localhost:${PORT_EXTERNAL_HOME}"
		# the whole policy, word for word: one widened source (font-src *, style-src http:) lets a third party back in
		# nosemgrep: detect-insecure-websocket -- the test asserts the Content-Security-Policy's same-host websocket sources
		WANT="default-src 'self'; connect-src 'self' ws://${O} wss://${O}${SYNC_SRC}; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; worker-src 'self' blob:; frame-src 'self' http://localhost:* http://127.0.0.1:* http://*.localhost:*; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'self'"
		CSP=$(curl -s -D - -o /dev/null --max-time 10 -H "Host: ${O}" "${URL}/" | tr -d '\r' | sed -n 's/^[Cc]ontent-[Ss]ecurity-[Pp]olicy: //p')
		[ "${CSP}" == "${WANT}" ] || fail "${H}.localhost does not answer with exactly the own-origin Content-Security-Policy: [${CSP}]"
	done
	echo "ok 7 - both vibe-kanban routes answer with exactly the own-origin Content-Security-Policy (the board's with its live-sync origin), so the browser refuses third-party requests"
	HTTP=$(curl -s -o "${D}/probe-board.txt" -w '%{http_code}' --max-time 15 "${URL}/__probe/kanban")
	[ "${HTTP}" == "204" ] || fail "the Goals board tile's status probe /__probe/kanban answered ${HTTP}: $(cat "${D}/probe-board.txt")"
	HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${URL}/__probe/vk-runner")
	[ "${HTTP}" == "204" ] || fail "the runner tile's status probe /__probe/vk-runner answered ${HTTP}"
	echo "ok 8 - the tiles' same-origin status probes (status-only): /__probe/kanban 204, /__probe/vk-runner 204"
	# the container start seeds the board in the background (/agent/kanban-sync.py seed): give it up to 90 s
	for i in $(seq 1 30); do
		curl -s -o "${D}/signin9.html" --max-time 15 -H "${ROUTE}" -H "${HOME_REF}" "${URL}/__harness/sign-in"
		PROJECT=$(sed -n 's|.*var target = "/projects/\([0-9a-f-]*\)";.*|\1|p' "${D}/signin9.html")
		[ -n "${PROJECT}" ] && break
		[ "${i}" -eq 30 ] && fail "the one-click sign-in does not land on the agent's project 90 s after the start (the seed's log is /wd/ui/kanban-seed.log in the container)"
		sleep 3
	done
	# the agent's project: uuidv5 of "project:<KANBAN_PROJECT>" in the harness namespace (kanban-sync.py, kanban-signin.py;
	# run.sh passes CONTAINER); its name is the goal set's (kanban-sync.py), so the id is what identifies it
	uuid5()
	{
		# uuid5 <namespace uuid> <name> - RFC 4122 version 5 (SHA-1), as Python's uuid.uuid5
		local NSHEX=${1//-/} H
		H=$( { printf '%b' "$(printf '%s' "${NSHEX}" | sed 's/../\\x&/g')"; printf '%s' "$2"; } | sha1sum | cut -c1-32)
		printf '%s-%s-5%s-%02x%s-%s\n' "${H:0:8}" "${H:8:4}" "${H:13:3}" $(( (16#${H:16:2} & 16#3f) | 16#80 )) "${H:18:2}" "${H:20:12}"
	}
	WANT_PROJECT=$(uuid5 403ef658-05ce-59aa-97e8-8aea9ecc4f02 "project:${CONTAINER}")
	HTTP=$(curl -s -o "${D}/project.json" -w '%{http_code}' --max-time 10 -H "${ROUTE}" -H @"${D}/auth.hdr" "${URL}/v1/projects/${PROJECT}")
	if [ "${PROJECT}" != "${WANT_PROJECT}" ] || [ "${HTTP}" != "200" ]; then
		fail "the project the sign-in lands on (${PROJECT}) is not the agent's project ${WANT_PROJECT} (KANBAN_PROJECT ${CONTAINER}; http=${HTTP})"
	fi
	PROJECT_NAME=$(sed -n 's/.*"name":"\([^"]*\)".*/\1/p' "${D}/project.json" | head -1)
	curl -s -o "${D}/statuses.json" --max-time 10 -H "${ROUTE}" -H @"${D}/auth.hdr" "${URL}/v1/project_statuses?project_id=${PROJECT}"
	for C in "To do" "In progress" "In review" "Done"; do
		grep -qF "\"name\":\"${C}\"" "${D}/statuses.json" || fail "the agent's project has no ${C} column"
	done
	curl -s -o "${D}/issues.json" --max-time 10 -H "${ROUTE}" -H @"${D}/auth.hdr" "${URL}/v1/issues?project_id=${PROJECT}"
	CARDS=$(grep -o '"title":"' "${D}/issues.json" | wc -l)
	[ "${CARDS}" -ge 1 ] || fail "the agent's project has no card: the goals were not mirrored at the start"
	# without a goals file (AUTONOMY_LOOP_GOALS, under the project's wd/ on the host), the card of the shipped default
	# goals' standing goal
	GOALS_HOST=wd/${AUTONOMY_LOOP_GOALS#/wd/}
	if [ "${AUTONOMY_LOOP_GOALS#/wd/}" != "${AUTONOMY_LOOP_GOALS}" ] && [ ! -f "${GOALS_HOST}" ]; then
		STANDING=$(sed -n 's/^## \(Standing goal .*\)$/\1/p' Container-Root/agent/goals-default.md | head -1)
		[ -n "${STANDING}" ] || fail "Container-Root/agent/goals-default.md has no '## Standing goal' heading"
		grep -qF "\"title\":\"${STANDING}\"" "${D}/issues.json" || fail "no goals file, and no card of the default goals' '${STANDING}'"
	fi
	echo "ok 9 - the start seeded the board: the one-click sign-in lands on the agent's project (${PROJECT}, KANBAN_PROJECT ${CONTAINER}, shown as \"${PROJECT_NAME}\"), with its four columns and ${CARDS} card(s)"
	if [ -n "${AGENT_STATE_PATH_EXTERNAL}" ]; then
		RUNNER_STATE=${AGENT_STATE_PATH_EXTERNAL}/vibe-kanban
		compgen -G "${RUNNER_STATE}/db*.sqlite" > /dev/null \
			|| fail "the agent runner's database is not in the persisted folder ${RUNNER_STATE} (AGENT_STATE_VOL_MAP in .env): its settings and workspaces would not survive ./stop.sh and ./run.sh"
		echo "ok 10 - the agent runner keeps its database, settings and keys in the persisted host folder ${RUNNER_STATE}"
	else
		echo "ok 10 - skipped: AGENT_STATE_PATH_EXTERNAL is empty (ephemeral agent state)"
	fi
	# the board server answers any Origin with credentials allowed; the app is same-origin, and the route drops both
	CORS=$(curl -s -D - -o /dev/null --max-time 10 -H "${ROUTE}" -H "Origin: https://evil.example" "${URL}/v1/health" | tr -d '\r' | grep -i '^access-control-allow-')
	[ -z "${CORS}" ] || fail "the board route passes the board server's CORS headers to another site's page: ${CORS}"
	echo "ok 11 - the board route answers another site's Origin without CORS headers (no Access-Control-Allow-Origin or -Credentials)"
	# the runner's analytics: off in the settings a first start gives it; settings that existed before are the user's,
	# and with analytics on this start must have said so (its notice file, wd/ui on the docker target; the runner's
	# appended log can still hold the notice of an earlier start, so it does not count)
	if [ -n "${AGENT_STATE_PATH_EXTERNAL}" ]; then
		RUNNER_CONFIG=${AGENT_STATE_PATH_EXTERNAL}/vibe-kanban/config.json
		[ -f "${RUNNER_CONFIG}" ] || fail "the agent runner has no settings in ${RUNNER_CONFIG}"
		if grep -qE '"analytics_enabled"[[:space:]]*:[[:space:]]*false' "${RUNNER_CONFIG}"; then
			echo "ok 12 - the agent runner's analytics are off (${RUNNER_CONFIG})"
		elif grep -qF "vibe-kanban: NOTICE - analytics are on in" wd/ui/vibe-kanban-analytics.notice 2> /dev/null; then
			echo "ok 12 - the agent runner's analytics are on in settings that existed before this start, and this start said so (wd/ui/vibe-kanban-analytics.notice)"
		else
			fail "the agent runner's analytics are on (${RUNNER_CONFIG}) and no notice said so: the runner sends usage events to vibe-kanban's PostHog"
		fi
	else
		echo "ok 12 - skipped: AGENT_STATE_PATH_EXTERNAL is empty (ephemeral agent state)"
	fi
	# the access token's lifetime, from live 1's login (its payload's exp and iat; the token itself is not printed)
	TTL=$(printf '%s' "${TOKEN}" | python3 -c 'import base64, json, sys
p = sys.stdin.read().split(".")[1]
c = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
print(c["exp"] - c["iat"])' 2> /dev/null)
	[ "${TTL}" == "900" ] || fail "the board's access token lasts ${TTL:-an unreadable time} s, not 900 (15 minutes) - patch 0008 is not in this board"
	echo "ok 13 - the board's access token lasts 15 minutes (exp - iat = ${TTL} s)"
	# the board's live sync on its second origin: the page names it, and it serves the shapes to the board's origin alone
	SYNC_HOST="kanban-sync.localhost:${PORT_EXTERNAL_HOME}"
	BOARD_ORIGIN="http://kanban.localhost:${PORT_EXTERNAL_HOME}"
	curl -s --max-time 10 -H "${ROUTE}" "${URL}/" | grep -qF "<meta name=\"harness-sync-origin\" content=\"//${SYNC_HOST}\">" \
		|| fail "the board page does not name its live-sync origin (no harness-sync-origin meta for ${SYNC_HOST})"
	SHAPE="${URL}/v1/shape/user/workspaces?offset=-1"
	HDRS=$(curl -s -D - -o "${D}/shape.json" --max-time 30 -H "Host: ${SYNC_HOST}" -H "Origin: ${BOARD_ORIGIN}" \
		-H @"${D}/auth.hdr" "${SHAPE}" | tr -d '\r')
	echo "${HDRS}" | head -1 | grep -q ' 200' || fail "a shape read on ${SYNC_HOST} answered: $(echo "${HDRS}" | head -1)"
	echo "${HDRS}" | grep -qi '^electric-offset: ' || fail "the shape read on ${SYNC_HOST} lacks the electric-offset header"
	echo "${HDRS}" | grep -qixF "access-control-allow-origin: ${BOARD_ORIGIN}" \
		|| fail "${SYNC_HOST} does not let the board's origin read the shape: $(echo "${HDRS}" | grep -i '^access-control-' | tr '\n' ' ')"
	echo "${HDRS}" | grep -qixF "access-control-expose-headers: electric-cursor, electric-handle, electric-offset, electric-schema, electric-up-to-date" \
		|| fail "${SYNC_HOST} does not expose exactly the five Electric headers: $(echo "${HDRS}" | grep -i '^access-control-expose' )"
	echo "${HDRS}" | grep -qi '^access-control-allow-credentials' && fail "${SYNC_HOST} allows credentials"
	HDRS=$(curl -s -D - -o /dev/null --max-time 30 -H "Host: ${SYNC_HOST}" -H "Origin: http://evil.localhost:${PORT_EXTERNAL_HOME}" \
		-H @"${D}/auth.hdr" "${SHAPE}" | tr -d '\r')
	echo "${HDRS}" | grep -qi '^access-control-' && fail "${SYNC_HOST} answers another site's Origin with CORS headers: $(echo "${HDRS}" | grep -i '^access-control-' | tr '\n' ' ')"
	HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Host: ${SYNC_HOST}" "${URL}/v1/organizations")
	[ "${HTTP}" == "404" ] || fail "${SYNC_HOST} answers ${HTTP} outside the shapes (/v1/organizations), not 404"
	echo "ok 14 - the board's live sync on ${SYNC_HOST}: named by the board page, a shape for the board's origin alone (the Electric headers exposed, no credentials), 404 elsewhere"
	if [ "${UI_KANBAN_RELAY}" != "true" ]; then
		echo "ok 15 - skipped: the relay is off (UI_KANBAN_RELAY=false)"
	else
		# the relay: the runner signed in to the board, the board's online host, and a session to it through the relay
		RUNNER_ROUTE="Host: vk-runner.localhost:${PORT_EXTERNAL_HOME}"
		for i in $(seq 1 30); do
			curl -s -o "${D}/runner-info.json" --max-time 10 -H "${RUNNER_ROUTE}" "${URL}/api/info"
			MACHINE=$(python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))["data"]
print(d["machine_id"] if (d.get("login_status") or {}).get("status") == "loggedin" else "")' "${D}/runner-info.json" 2> /dev/null)
			[ -n "${MACHINE}" ] && break
			[ "${i}" -eq 30 ] && fail "the agent runner is not signed in to the board 90 s after the start (its /api/info login_status is not loggedin; the sign-in's line is in wd/ui/vk-runner-signin.log in the container)"
			sleep 3
		done
		for i in $(seq 1 20); do
			HTTP=$(curl -s -o "${D}/hosts.json" -w '%{http_code}' --max-time 10 -H "${ROUTE}" -H @"${D}/auth.hdr" "${URL}/v1/hosts")
			HOST_ID=$(python3 -c 'import json, sys
print(next((h["id"] for h in json.load(open(sys.argv[1])).get("hosts", []) if h.get("machine_id") == sys.argv[2] and h.get("status") == "online"), ""))' \
				"${D}/hosts.json" "${MACHINE}" 2> /dev/null)
			[ -n "${HOST_ID}" ] && break
			[ "${i}" -eq 20 ] && fail "the board lists no online host that is the agent runner (machine ${MACHINE}; http=${HTTP}) 60 s after it signed in"
			sleep 3
		done
		HTTP=$(curl -s -o "${D}/relay-session.json" -w '%{http_code}' --max-time 15 -X POST -H "${ROUTE}" -H @"${D}/auth.hdr" \
			"${URL}/v1/relay/create/${HOST_ID}")
		if [ "${HTTP}" != "200" ] || ! grep -q '"session_id":' "${D}/relay-session.json"; then
			fail "the relay opened no session to the agent runner through the board's route (POST /v1/relay/create/${HOST_ID}: http=${HTTP})"
		fi
		echo "ok 15 - the relay: the agent runner is signed in to the board and is its online host (machine ${MACHINE}, host ${HOST_ID}), and the relay opens a session to it through kanban.localhost"
	fi
	# the agent line: the project's cards (live 9 read them) and their columns
	curl -s -o "${D}/issues.json" --max-time 10 -H "${ROUTE}" -H @"${D}/auth.hdr" "${URL}/v1/issues?project_id=${PROJECT}"
	# the goal the loop's next fire starts on is the first open goal in FILE order (kanban-sync.py first_open), read here
	# from the goals file on the host (the project's wd/, as live 9 reads it; without one, the shipped default goals'
	# standing goal) as kanban-sync.py reads it: a "- [ ] text" item or a "## Goal ..." / "## Standing goal ..." heading
	# without [x], code fences skipped, the text cut at 250 characters (the board's title length). The agent line is
	# expected on exactly that card, an open one, wherever the board's order puts it (KANBAN_CARD_ORDER=newest-first puts
	# the goal that reached the board last on top, so it is usually the lowest open card), and on no other card
	first_open_goal()
	{
		python3 -c '
import re, sys
CHECKBOX = re.compile(r"^\s*[-*]\s+\[([ xX])\]\s+(\S.*?)\s*$"); HEADING = re.compile(r"^##\s+(\S.*?)\s*$"); DONE = re.compile(r"\[[xX]\]")
fence = False
for line in open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines():
    if line.lstrip().startswith("```"):
        fence = not fence
        continue
    if fence:
        continue
    m = CHECKBOX.match(line)
    if m:
        if m.group(1) == " ":
            print(m.group(2)[:250]); break
        continue
    m = HEADING.match(line)
    if m:
        text = " ".join(DONE.sub("", m.group(1)).split())
        if re.match(r"(standing\s+)?goal\b", text, re.I) and not DONE.search(m.group(1)):
            print(text[:250]); break' "$1"
	}
	if [ -f "${GOALS_HOST}" ]; then NEXT_GOAL=$(first_open_goal "${GOALS_HOST}"); else NEXT_GOAL=$(first_open_goal Container-Root/agent/goals-default.md); fi
	[ -n "${NEXT_GOAL}" ] || fail "no open goal in ${GOALS_HOST} (nor in the default goals) for the agent line to be on"
	CUE=$(NEXT="${NEXT_GOAL}" python3 -c 'import json, os, sys
names = {s["id"]: s["name"] for s in json.load(open(sys.argv[2])).get("project_statuses", [])}
issues = json.load(open(sys.argv[1])).get("issues", [])
cued = [i for i in issues if (i.get("description") or "").startswith("**Agent:** ")]
other = [i for i in issues if "**Agent:**" in (i.get("description") or "") and i not in cued]
ok = len(cued) == 1 and not other and cued[0]["title"] == os.environ["NEXT"] and names.get(cued[0]["status_id"]) not in ("Done", "Cancelled")
print(("ok|" if ok else "bad|") + ((cued[0]["description"] or "").splitlines()[0][:120] if len(cued) == 1 else "") + "|" + " / ".join(
    i["title"] + " (" + str(names.get(i["status_id"])) + "): " + (i["description"] or "").splitlines()[0][:120] for i in cued + other))' "${D}/issues.json" "${D}/statuses.json")
	[ "${CUE%%|*}" == "ok" ] || fail "the agent line is not on exactly the card of the goal the loop works next (\"${NEXT_GOAL}\", the goals file's first open goal), open: ${CUE##*|}"
	echo "ok 16 - one card says what the agent does next: \"$(echo "${CUE}" | cut -d'|' -f2)\" leads the card of the goals file's first open goal (\"${NEXT_GOAL}\"), an open card, and no other card has the line"
}

neighbours()
{
	# The board's database and Electric (third-party images) share an internal network with the board server only
	# (KANBAN_INTERNAL_NETWORK: no route out, and the agent is not on it), so they cannot reach the agent container at
	# all. From inside each, no agent listener may answer: the home port, the one-click sign-in behind it (with the
	# Host and Referer a browser on the home page would send - any client can forge both) and the writable terminal.
	# The board server is on the agent's network too and stays its neighbour: the home listener admits only loopback,
	# the default route's gateway and UI_HOME_ALLOW_FROM (403 otherwise), it answers only loopback names (421 for any
	# other Host, an address included), and the UI backends listen on 127.0.0.1, so from the board server's own
	# network namespace the home port answers 421, the sign-in on kanban.localhost 403, and the terminal not at all.
	# With the relay on (UI_KANBAN_RELAY=true), the relay is on both networks too, a second neighbour, and is probed
	# the same way. Docker target only (the sidecars' container names).
	IP=$(docker container inspect -f "{{(index .NetworkSettings.Networks \"${KANBAN_NETWORK}\").IPAddress}}" "${CONTAINER}" 2> /dev/null)
	[ -n "${IP}" ] || fail "the agent container ${CONTAINER} is not on ${KANBAN_NETWORK} - run ./run.sh first"
	[ "$(docker network inspect -f '{{.Internal}}' "${KANBAN_INTERNAL_NETWORK}" 2> /dev/null)" == "true" ] \
		|| fail "the board's internal network ${KANBAN_INTERNAL_NETWORK} is missing or not internal"
	# networks_of <container> - its networks, space-separated, sorted
	networks_of()
	{
		docker container inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$1" 2> /dev/null | sort | xargs
	}
	for S in "${KANBAN_DB_NAME}" "${KANBAN_ELECTRIC_NAME}"; do
		[ "$(networks_of "${S}")" == "${KANBAN_INTERNAL_NETWORK}" ] \
			|| fail "${S} is on [$(networks_of "${S}")], not on ${KANBAN_INTERNAL_NETWORK} alone"
	done
	networks_of "${CONTAINER}" | tr ' ' '\n' | grep -qxF "${KANBAN_INTERNAL_NETWORK}" \
		&& fail "the agent container is on the board's internal network ${KANBAN_INTERNAL_NETWORK}"
	# answer <sidecar> <URL> [<header>...] - the first status line the sidecar gets from the agent, or "no answer"
	# (Electric's image has curl, the database's busybox wget)
	answer()
	{
		S=$1
		U=$2
		shift 2
		H=()
		if docker container exec "${S}" sh -c 'command -v curl' > /dev/null 2>&1; then
			for X in "$@"; do H+=(-H "${X}"); done
			docker container exec "${S}" curl -s -o /dev/null -D - -m 5 "${H[@]}" "${U}" 2>&1 | grep -m1 -o 'HTTP/[0-9.]* [0-9]*.*' || echo "no answer"
		else
			for X in "$@"; do H+=(--header "${X}"); done
			docker container exec "${S}" wget -S -q -O /dev/null -T 5 "${H[@]}" "${U}" 2>&1 | grep -m1 -o 'HTTP/[0-9.]* [0-9]*.*' || echo "no answer"
		fi
	}
	REACHED=""
	for S in "${KANBAN_DB_NAME}" "${KANBAN_ELECTRIC_NAME}"; do
		for U in "http://${IP}:${PORT_INTERNAL_HOME}/" "http://${IP}:${PORT_INTERNAL_TMUX}/tmux/"; do
			A=$(answer "${S}" "${U}")
			echo "  ${S} -> ${U}: ${A}"
			[ "${A}" == "no answer" ] || REACHED="${REACHED} ${S}->${U}"
		done
		A=$(answer "${S}" "http://${IP}:${PORT_INTERNAL_HOME}/__harness/sign-in" "Host: kanban.localhost:${PORT_EXTERNAL_HOME}" \
			"Referer: http://localhost:${PORT_EXTERNAL_HOME}/")
		echo "  ${S} -> http://${IP}:${PORT_INTERNAL_HOME}/__harness/sign-in (Host kanban.localhost, the home page's Referer): ${A}"
		[ "${A}" == "no answer" ] || REACHED="${REACHED} ${S}->/__harness/sign-in"
	done
	# from_board <container> <curl args> - the first status line that container's network namespace gets (a throwaway
	# container of the agent image, which has curl, joined to that namespace: the board's and the relay's images may
	# have neither curl nor wget, and a missing client must never read as "no answer"), or "no answer"
	from_board()
	{
		N=$1
		shift
		docker container run --rm --name "${CONTAINER}-neighbour-probe" --network "container:${N}" \
			--entrypoint curl "${REGISTRY}${IMAGE}${TAG}" -s -o /dev/null -D - -m 5 "$@" 2> /dev/null \
			| grep -m1 -o 'HTTP/[0-9.]* [0-9]*' || echo "no answer"
	}
	docker container run --rm --entrypoint curl "${REGISTRY}${IMAGE}${TAG}" --version > /dev/null 2>&1 \
		|| fail "the agent image ${REGISTRY}${IMAGE}${TAG} cannot run curl, so the board server's view cannot be probed"
	NEIGHBOURS="${KANBAN_SERVER_NAME}"
	if [ "${UI_KANBAN_RELAY}" == "true" ]; then
		docker container inspect "${KANBAN_RELAY_NAME}" > /dev/null 2>&1 || fail "the relay is on, and its sidecar ${KANBAN_RELAY_NAME} is not running"
		NEIGHBOURS="${NEIGHBOURS} ${KANBAN_RELAY_NAME}"
	fi
	for N in ${NEIGHBOURS}; do
		for U in "http://${IP}:${PORT_INTERNAL_HOME}/" "http://${IP}:${PORT_INTERNAL_HOME}/tmux/"; do
			A=$(from_board "${N}" "${U}")
			echo "  ${N} -> ${U}: ${A}"
			case "${A}" in "no answer"|*" 403"|*" 421") ;; *) REACHED="${REACHED} ${N}->${U}(${A})" ;; esac
		done
		A=$(from_board "${N}" -H "Host: kanban.localhost:${PORT_EXTERNAL_HOME}" -H "Referer: http://localhost:${PORT_EXTERNAL_HOME}/" \
			"http://${IP}:${PORT_INTERNAL_HOME}/__harness/sign-in")
		echo "  ${N} -> http://${IP}:${PORT_INTERNAL_HOME}/__harness/sign-in (Host kanban.localhost, the home page's Referer): ${A}"
		case "${A}" in "no answer"|*" 403") ;; *) REACHED="${REACHED} ${N}->/__harness/sign-in(${A})" ;; esac
		A=$(from_board "${N}" "http://${IP}:${PORT_INTERNAL_TMUX}/tmux/")
		echo "  ${N} -> http://${IP}:${PORT_INTERNAL_TMUX}/tmux/ (the terminal's own port): ${A}"
		[ "${A}" == "no answer" ] || REACHED="${REACHED} ${N}->:${PORT_INTERNAL_TMUX}(${A})"
	done
	[ -z "${REACHED}" ] || fail "a board sidecar reaches the agent container:${REACHED}"
	WHO="the board server, the agent's one neighbour, gets"
	[ "${UI_KANBAN_RELAY}" == "true" ] && WHO="the board server and the relay, the agent's two neighbours, get"
	echo "ok 1 - the board's database and Electric are on ${KANBAN_INTERNAL_NETWORK} alone (internal, without the agent), and no agent listener answers them (home port, one-click sign-in, terminal); ${WHO} 403 or no answer from the home port and the sign-in and no answer from the terminal"
}

case "${NAME}" in
	"bundle")
		bundle
		;;
	"live")
		live
		;;
	"neighbours")
		neighbours
		;;
	*)
		echo "Usage: $0 bundle|live|neighbours"
		exit 1
		;;
esac
echo "Test-kanban-${NAME} PASSED"
