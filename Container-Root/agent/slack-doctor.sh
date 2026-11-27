#!/usr/bin/env bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
# slack-doctor.sh — proves the person's Slack setup for the harness, one row per check.
#
#   slack-doctor.sh               token, scopes, channels (read-only: nothing is posted)
#   slack-doctor.sh --post-test   also the post round-trip and the thread round-trip in
#                                 SLACK_TEST_CHANNEL (two messages, labelled, in the person's own channel)
#
# Reads SLACK_BOT_TOKEN, SLACK_CHANNELS (comma-separated ids), SLACK_TEST_CHANNEL (for --post-test).
# SLACK_API_BASE (default https://slack.com/api) may name a LOOPBACK stub for a hermetic run:
# http://127.0.0.1:<port>, or that with a path of letters, digits and . _ ~ - /. Anything else is refused before
# any request: a name, a third host, or a user part (http://127.0.0.1:1@host would send the token to host).
#
# Exit 0: every row PASS. Exit 1: at least one GAP (the row says what to change). Exit 2: usage.
# No answer from the API at all is the token row alone: every later request would wait out its own 20 s for nothing.
# Writes only a private mktemp directory, removed at exit. Prints no token, and puts none on any
# command line: it reaches curl as a config line on stdin (-K -), the Authorization header is the
# only place it travels. test23.sh proves both against the loopback stub in test-lib/.
set -euo pipefail

BASE="${SLACK_API_BASE:-https://slack.com/api}"
POST_TEST=0
case "${1:-}" in
  --post-test) POST_TEST=1 ;;
  "") ;;
  -h|--help) sed -n '4,19p' "$0"; exit 0 ;;
  *) echo "usage: slack-doctor.sh [--post-test]" >&2; exit 2 ;;
esac
# a loopback stub only: the port's digits, then nothing or a path of plain characters. A user part
# (http://127.0.0.1:1@host) would make curl send the token to the host after the @.
LOOPBACK='^http://127\.0\.0\.1:[0-9]{1,5}(/[A-Za-z0-9._~/-]*)?$'
if [ "$BASE" != "https://slack.com/api" ] && ! [[ "$BASE" =~ $LOOPBACK ]]; then
  echo "SLACK_API_BASE must be https://slack.com/api or http://127.0.0.1:<port>[/<path>]; refusing $BASE" >&2; exit 2
fi

# the scopes the manifest grants, and why each row needs them
REQUIRED_SCOPES="channels:history groups:history im:history mpim:history channels:read groups:read im:read mpim:read users:read"
POST_SCOPE="chat:write"
UPLOAD_SCOPE="files:write"   # the second opt-in: /agent/slack-upload.sh attaching a file; absent = fine, reported, never a GAP

ROWS=()      # "STATE|check|detail"
GAPS=0
row() {      # state check detail
  ROWS+=("$1|$2|$3")
  [ "$1" = "GAP" ] && GAPS=$((GAPS + 1)) || true
}
finish() {   # the table, then exit 1 when a row is a GAP, else 0
  printf '%-5s %-22s %s\n' STATE CHECK DETAIL
  for r in "${ROWS[@]}"; do
    IFS='|' read -r st ck dt <<<"$r"
    printf '%-5s %-22s %s\n' "$st" "$ck" "$dt"
  done
  if [ "$GAPS" -gt 0 ]; then
    echo "slack-doctor: $GAPS GAP(s) — fix the rows above, restart the harness, run again"; exit 1
  fi
  echo "slack-doctor: PASS — the harness can read the channels$( [ "$POST_TEST" = 1 ] && echo ', post, and follow threads')"
  exit 0
}

# curl's body and headers land in a private directory (mode 0700, unpredictable name), gone at exit
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT

# call METHOD key=value... -> prints "<http status>\n<x-oauth-scopes header>\n<body>"
call() {
  local method="$1"; shift
  local args=() code tok
  for kv in "$@"; do args+=(--data-urlencode "$kv"); done
  # The token reaches curl as a config line on STDIN (-K -), never on argv: a command line is readable
  # by every user on the host (ps, /proc/<pid>/cmdline) for as long as the request runs. curl's config
  # syntax quotes with "" and escapes \ and " inside; a Slack token has neither, the escapes are belt
  # and braces. Always a POST (Slack accepts it for every method; a bare auth.test would otherwise GET).
  tok="${SLACK_BOT_TOKEN//\\/\\\\}"; tok="${tok//\"/\\\"}"
  rm -f "${WORK:?}/body" "${WORK:?}/headers"
  code="$(printf 'header = "Authorization: Bearer %s"\n' "$tok" |
          curl -sS -m 20 -X POST -K - -o "${WORK}/body" -D "${WORK}/headers" -w '%{http_code}' \
               "${args[@]}" "${BASE}/${method}" 2>/dev/null)" || true
  echo "${code:-000}"
  grep -i '^x-oauth-scopes:' "${WORK}/headers" 2>/dev/null | sed 's/^[^:]*: *//' | tr -d '\r' || true
  echo
  cat "${WORK}/body" 2>/dev/null || true
}
# json FIELD <<< body  -> the field or ""
jf() { python3 -I -c 'import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print(""); sys.exit(0)
v=d
for k in sys.argv[1].split("."):
    v=v.get(k) if isinstance(v,dict) else None
print("" if v is None else (json.dumps(v) if isinstance(v,(dict,list)) else v))' "$1"; }

# ---- 1. token ---------------------------------------------------------------------------
if [ -z "${SLACK_BOT_TOKEN:-}" ]; then
  row GAP token "SLACK_BOT_TOKEN is not set — export the Bot User OAuth Token (xoxb-…) in .env.local beside the harness's .env (or in the host shell), then ./stop.sh && ./run.sh"
else
  case "$SLACK_BOT_TOKEN" in
    xoxb-*) ;;
    xoxp-*) row GAP token "a USER token (xoxp-): the harness refuses to post in a person's name — install the app and use its Bot User OAuth Token (xoxb-)" ;;
    xapp-*) row GAP token "an app-level token (xapp-): the Web API needs the Bot User OAuth Token (xoxb-)" ;;
    *)      row GAP token "not a bot token shape (expected xoxb-…)" ;;
  esac
fi
SCOPES=""
NO_ANSWER=0
if [ -n "${SLACK_BOT_TOKEN:-}" ]; then
  out="$(call auth.test)"
  status="$(printf '%s\n' "$out" | sed -n 1p)"; SCOPES="$(printf '%s\n' "$out" | sed -n 2p)"; body="$(printf '%s\n' "$out" | sed '1,2d')"
  if [ "$status" = "000" ]; then
    row GAP token "no answer from ${BASE} (network, DNS or the base is wrong)"
    NO_ANSWER=1
  elif [ "$(jf ok <<<"$body")" = "True" ]; then
    row PASS token "auth.test ok — bot user $(jf user_id <<<"$body") in team $(jf team <<<"$body")"
  else
    row GAP token "auth.test failed: $(jf error <<<"$body") (HTTP $status) — invalid_auth/token_revoked/account_inactive mean a new install and a new token"
  fi
fi
# nothing answered: the later rows would only repeat the token row, each after its own timeout
if [ "$NO_ANSWER" = 1 ]; then finish; fi

# ---- 2. scopes ---------------------------------------------------------------------------
if [ -n "$SCOPES" ]; then
  missing=""
  for s in $REQUIRED_SCOPES; do
    case ",$(echo "$SCOPES" | tr -d ' ')," in *",$s,"*) ;; *) missing="$missing $s" ;; esac
  done
  if [ -n "$missing" ]; then
    row GAP scopes "missing scope$( [ "$(echo $missing | wc -w)" -gt 1 ] && echo s):$missing — add to the manifest's bot scopes, reinstall the app, replace SLACK_BOT_TOKEN"
  else
    row PASS scopes "every read scope granted ($(echo $REQUIRED_SCOPES | wc -w) of $(echo $REQUIRED_SCOPES | wc -w))"
  fi
  case ",$(echo "$SCOPES" | tr -d ' ')," in
    *",$POST_SCOPE,"*) row PASS chat:write "granted — a human's Send click on a staged reply can post" ;;
    *) if [ "$POST_TEST" = 1 ]; then row GAP chat:write "missing scope chat:write — needed for --post-test and for the write surface's Send; omit both for a read-only install"
       else row PASS chat:write "not granted — read-only install; the write surface cannot send (fine unless you want it to)"; fi ;;
  esac
  case ",$(echo "$SCOPES" | tr -d ' ')," in
    *",$UPLOAD_SCOPE,"*) row PASS files:write "granted — /agent/slack-upload.sh can attach a file (a chart, a report) in a watched channel or thread" ;;
    *) row PASS files:write "not granted — the agent cannot attach files (fine unless you want /agent/slack-upload.sh: add files:write to the manifest's bot scopes, reinstall the app, replace SLACK_BOT_TOKEN)" ;;
  esac
elif [ -n "${SLACK_BOT_TOKEN:-}" ]; then
  row GAP scopes "auth.test returned no x-oauth-scopes header — cannot list granted scopes (a stub or proxy stripped it?)"
fi

# ---- 3. channels -------------------------------------------------------------------------
if [ -z "${SLACK_CHANNELS:-}" ]; then
  row GAP channels "SLACK_CHANNELS is not set (comma-separated channel ids the bot was invited to)"
elif [ -n "${SLACK_BOT_TOKEN:-}" ]; then
  IFS=',' read -r -a CHANS <<<"$SLACK_CHANNELS"
  for ch in "${CHANS[@]}"; do
    ch="$(echo "$ch" | tr -d ' ')"; [ -n "$ch" ] || continue
    out="$(call conversations.info "channel=$ch")"; body="$(printf '%s\n' "$out" | sed '1,2d')"
    name="$(jf channel.name <<<"$body")"
    if [ "$(jf ok <<<"$body")" != "True" ]; then
      err="$(jf error <<<"$body")"
      case "$err" in
        channel_not_found) row GAP "channel $ch" "channel_not_found — the id is wrong, or the bot cannot see this channel; check the id in the channel's details" ;;
        missing_scope)     row GAP "channel $ch" "missing_scope needed=$(jf needed <<<"$body") — add it to the manifest, reinstall, replace the token" ;;
        *)                 row GAP "channel $ch" "conversations.info failed: $err" ;;
      esac
      continue
    fi
    out="$(call conversations.history "channel=$ch" "limit=1")"; body="$(printf '%s\n' "$out" | sed '1,2d')"
    if [ "$(jf ok <<<"$body")" = "True" ]; then
      row PASS "channel $ch" "readable (${name:-no name: a DM})"
    else
      err="$(jf error <<<"$body")"
      case "$err" in
        not_in_channel) row GAP "channel $ch" "not_in_channel — invite the bot: /invite @<app name> in that channel" ;;
        missing_scope)  row GAP "channel $ch" "missing_scope needed=$(jf needed <<<"$body") — add it to the manifest, reinstall, replace the token" ;;
        *)              row GAP "channel $ch" "conversations.history failed: $err" ;;
      esac
    fi
  done
fi

# ---- 4/5. the round-trips, only when asked ------------------------------------------------
if [ "$POST_TEST" = 1 ]; then
  if [ -z "${SLACK_TEST_CHANNEL:-}" ]; then
    row GAP post-round-trip "SLACK_TEST_CHANNEL is not set — a channel of your own for the two doctor messages"
  elif [ -n "${SLACK_BOT_TOKEN:-}" ]; then
    stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    text="[slack-doctor] round-trip ${stamp} — a setup check; nothing to do"
    out="$(call chat.postMessage "channel=$SLACK_TEST_CHANNEL" "text=$text")"; body="$(printf '%s\n' "$out" | sed '1,2d')"
    if [ "$(jf ok <<<"$body")" != "True" ]; then
      err="$(jf error <<<"$body")"
      case "$err" in
        missing_scope)  row GAP post-round-trip "missing scope $(jf needed <<<"$body") — add chat:write to the manifest, reinstall, replace the token" ;;
        not_in_channel) row GAP post-round-trip "not_in_channel — invite the bot to $SLACK_TEST_CHANNEL" ;;
        *)              row GAP post-round-trip "chat.postMessage failed: $err" ;;
      esac
    else
      ts="$(jf ts <<<"$body")"
      out="$(call conversations.history "channel=$SLACK_TEST_CHANNEL" "latest=$ts" "oldest=$ts" "inclusive=true" "limit=1")"
      hbody="$(printf '%s\n' "$out" | sed '1,2d')"
      if python3 -I -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if any(m.get("ts")==sys.argv[1] and sys.argv[2] in m.get("text","") for m in d.get("messages",[])) else 1)' "$ts" "round-trip ${stamp}" <<<"$hbody"; then
        row PASS post-round-trip "posted ts $ts and read it back by ts from conversations.history"
      else
        row GAP post-round-trip "posted ts $ts but conversations.history did not serve it back — the engine's read-back would call this unproven"
      fi
      # the thread
      out="$(call chat.postMessage "channel=$SLACK_TEST_CHANNEL" "thread_ts=$ts" "text=[slack-doctor] thread reply ${stamp}")"
      rbody="$(printf '%s\n' "$out" | sed '1,2d')"
      if [ "$(jf ok <<<"$rbody")" != "True" ]; then
        row GAP thread-round-trip "chat.postMessage with thread_ts failed: $(jf error <<<"$rbody")"
      else
        rts="$(jf ts <<<"$rbody")"
        out="$(call conversations.replies "channel=$SLACK_TEST_CHANNEL" "ts=$ts")"; tbody="$(printf '%s\n' "$out" | sed '1,2d')"
        if python3 -I -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if any(m.get("ts")==sys.argv[1] for m in d.get("messages",[])) else 1)' "$rts" <<<"$tbody"; then
          row PASS thread-round-trip "reply ts $rts served by conversations.replies under $ts"
        else
          err="$(jf error <<<"$tbody")"
          row GAP thread-round-trip "reply posted but conversations.replies did not serve it${err:+ ($err)} — the thread sweep would never see in-thread answers"
        fi
      fi
    fi
  fi
else
  row PASS post-round-trip "skipped (run with --post-test to post two labelled messages in SLACK_TEST_CHANNEL)"
fi

# ---- the table -----------------------------------------------------------------------------
finish
