#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Re-renders the home page's nginx config and reloads nginx when the container's default-route gateway
# changes. The home listener admits the host's published-port traffic by its source address, the default
# route's gateway (home-render.sh); `docker network connect` on a RUNNING container moves the default route
# to the new network's gateway, and until a re-render the host's own published port is answered 403 (measured
# in testing). Started by ui-start.sh with the home proxy, stopped by ui-stop.sh (pidfile home-watch).
#   UI_HOME_ROUTE_WATCH_INTERVAL  seconds between checks (default 5)
#   UI_HOME_GATEWAY               set by the operator = a static list: nothing to watch, the watcher exits
#   UI_HOME_ROUTE_TABLE           a file with `ip route` output read instead of the live table (tests)
# Every re-render is one line in ${UI_DIR}/home-watch.log; ${UI_DIR}/home-watch.gateways holds the list in force.

UI_DIR=${UI_DIR:-/wd/ui}
AGENT_DIR=$(cd "$(dirname "$0")" && pwd)
INTERVAL=${UI_HOME_ROUTE_WATCH_INTERVAL:-5}
if [ -n "${UI_HOME_GATEWAY}" ]; then
	echo "home-watch: UI_HOME_GATEWAY is set (${UI_HOME_GATEWAY}) - a static list, nothing to watch"
	exit 0
fi
LAST=$("${AGENT_DIR}/home-render.sh" --print-gateways)
echo "${LAST}" > "${UI_DIR}/home-watch.gateways"
echo "home-watch: watching the default route every ${INTERVAL}s (gateway(s) in force: ${LAST:-none})"
while true; do
	sleep "${INTERVAL}"
	CUR=$("${AGENT_DIR}/home-render.sh" --print-gateways)
	[ "${CUR}" == "${LAST}" ] && continue
	echo "home-watch: $(date -u +%FT%TZ) default-route gateway changed '${LAST}' -> '${CUR}' - re-rendering and reloading nginx"
	if "${AGENT_DIR}/home-render.sh" > /dev/null && nginx -c "${UI_DIR}/home/nginx.conf" -s reload 2>&1; then
		LAST=${CUR}
		echo "${LAST}" > "${UI_DIR}/home-watch.gateways"
	else
		echo "home-watch: re-render or reload failed - retrying on the next check"
	fi
done
