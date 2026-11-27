#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

MAX_ITER=10
DRY_RUN=0
RESUME=0
PRINT_PROMPT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --max)          MAX_ITER="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --print-prompt) PRINT_PROMPT=1; DRY_RUN=1; shift ;;
    --resume-last)  RESUME=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

STATE=${LOOP_STATE:-dashboard/state.json}
SITE_FILE="${SHIPPED_TREE_DENYLIST_FILE:-scripts/test_shipped_tree.local.conf}"
LOOP_ENV=$( [ -f "$SITE_FILE" ] && sed -n 's/^LOOP_ENV="\(.*\)"[[:space:]]*$/\1/p' "$SITE_FILE" | head -1 || true)
LOG=${LOOP_LOG:-dashboard/loop-log.jsonl}
mkdir -p dashboard

actionable() {
  python3 scripts/loop_pick.py "$STATE" "$LOG"
}

build_prompt() {
  local line="$1" item tag title why
  item=${line%%$'\t'*}; rest=${line#*$'\t'}; tag=${rest%% *}; rest=${rest#* }
  title=${rest%%$'\t'*}; why=${rest#*$'\t'}; [ "$why" = "$rest" ] && why=""
  printf '%s\n' \
"You are one iteration of the worker loop." \
"" \
"Work EXACTLY this item, chosen by the deterministic picker (scripts/loop_pick.py):" \
"    ITEM:   $item" \
"    TAG:    $tag" \
"    TITLE:  $title" \
"    WHY:    ${why:-we_owe: a human is waiting on a reply}" \
"Do NOT pick a different item. If this one turns out not to be actionable, log needs-human FOR THIS" \
"ITEM, give a one-line reason and stop. Max 1 item this iteration." \
"" \
"GitHub reads go ONLY through the bounded read-only wrapper: scripts/gh-ro <gh args>  (e.g." \
"scripts/gh-ro pr view 123 --repo o/r --json state; scripts/gh-ro run view <id> --repo o/r --log;" \
"scripts/gh-ro api repos/o/r/pulls/123). It forwards reads and refuses writes. pr-timeline <repo> <num>" \
"is also allowed (3-channel history). Plain gh is not permitted in this worker; anything that would" \
"write to GitHub is not this worker's job — STAGE it under scratch/ and classify needs-human." \
"" \
"Handling by TAG (the state.json row is a pointer, not the truth — deep-dive first):" \
"  owe                 -> a human is waiting: read the thread (pr-timeline), draft the reply, STAGE it." \
"  A-approved-stuck    -> APPROVED but unmergeable (DIRTY/CONFLICTING/BEHIND): 100% ours, the cheapest" \
"                         merge on the board. Rebase OUR fork branch on upstream/main, re-apply our" \
"                         units (never --ours/--theirs), verify with the repo unit gate, STAGE. Push only" \
"                         if mechanical AND verified AND the repo is ours; otherwise needs-human + diff." \
"  B-changes-requested -> address the reviewer thread: read the full timeline (bin/pr-timeline) and the code at the PR head, check each technical claim;" \
"                         draft the reply/fix in the reviewer's register, stage." \
"  C-red-ci            -> read the ACTUAL failing job log FIRST (scripts/gh-ro run view --log). If the" \
"                         red is a trigger convention / permission gate (a CI run awaiting maintainer approval)" \
"                         it is NOT our defect => needs-human, do not churn." \
"                         If it is our code/test/lint defect with a small own-branch fix => fix, stage." \
"  D-conflict          -> merge conflict on a non-approved PR: rebase OUR fork branch, resolve, verify," \
"                         STAGE; semantic conflict or external repo => needs-human with the staged diff." \
"" \
"Then: append ONE JSON line to dashboard/loop-log.jsonl:" \
'{"ts":"<utc-iso>","repo":"<o/r>","number":<n>,"axis":"we_owe|needs_attention","bucket":"<tag>","outcome":"replied|fixed|staged|closed|needs-human|failed","detail":"<one line>","urls":["..."]}' \
"Refresh the dashboard: python3 scripts/gh-dashboard.py --open-only" \
"Final message: ONE line — the item, the outcome, the URL if any." \
"" \
"Hard rules: never post anything to GitHub from this loop: stage it under scratch/<topic>/ beside a FILING-READY.md" \
"record (origin + evidence at a named commit, dedup in open AND closed states, redact-scan --strict result, the exact" \
"send command, verify steps, watch trigger) and log outcome=staged (the installed PreToolUse gate" \
"block-gh-write.sh blocks outward writes; the noise hook blocks matching comments — see README to install both);" \
"never force-push; never push to a repo we do not own; never push a semantic/non-mechanical rebase" \
"without human review (STAGE it); never close a PR we do not own; never auto-comment on an external" \
"repo; max 1 item this iteration."
}

WORKER_ALLOWED_TOOLS=(
  "Bash(scripts/gh-ro:*)" "Bash(./scripts/gh-ro:*)"
  "Bash(pr-timeline:*)" "Bash(scripts/redact-scan.sh:*)"
  "Bash(python3 scripts/gh-dashboard.py:*)" "Bash(python3 scripts/loop_pick.py:*)"
  "Bash(jq:*)" "Bash(cat:*)" "Bash(ls:*)" "Bash(grep:*)" "Bash(head:*)" "Bash(tail:*)" "Bash(wc:*)"
  "Bash(git status:*)" "Bash(git log:*)" "Bash(git diff:*)" "Bash(git show:*)"
  "Read" "Grep" "Glob"
  "Edit(scratch/**)" "Write(scratch/**)" "Edit(dashboard/**)" "Write(dashboard/**)"
)
WORKER_DENIED_TOOLS=(
  "Edit(scripts/**)" "Write(scripts/**)" "Edit(bin/**)" "Write(bin/**)" "Edit(.claude/**)" "Write(.claude/**)"
  "Edit(.claude-plugin/**)" "Write(.claude-plugin/**)" "Edit(.git/**)" "Write(.git/**)"
)
export PATH="$PWD/bin:$PATH"

for i in $(seq 1 "$MAX_ITER"); do
  NEXT=$(actionable | head -1 || true)
  if [ -z "$NEXT" ]; then
    echo "[loop] no actionable items — done after $((i-1)) iteration(s)"
    break
  fi
  echo "[loop] iter $i/$MAX_ITER → $NEXT"
  PROMPT=$(build_prompt "$NEXT")
  if [ "$PRINT_PROMPT" = "1" ]; then
    printf '%s\n' "$PROMPT"
    exit 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    continue
  fi
  RESUME_ARGS=()
  SESSION_FILE=dashboard/last-session.id
  if [ "$RESUME" = "1" ] && [ -s "$SESSION_FILE" ]; then
    RESUME_ARGS=(--resume "$(cat "$SESSION_FILE")")
    echo "[loop]   resuming session $(cut -c1-8 "$SESSION_FILE")"
  fi
  RESULT=$(env $LOOP_ENV claude -p "$PROMPT" "${RESUME_ARGS[@]}" \
      ${LOOP_MODEL:+--model "$LOOP_MODEL"} \
      --permission-mode default \
      --allowedTools "${WORKER_ALLOWED_TOOLS[@]}" \
      --disallowedTools "${WORKER_DENIED_TOOLS[@]}" \
      --max-turns 25 \
      --output-format json 2>>dashboard/loop-stderr.log) || {
    echo "[loop] iteration $i failed (claude exit $?)" >&2
    ITEM=${NEXT%%$'\t'*}
    printf '{"ts":"%s","repo":"%s","number":%s,"outcome":"failed","detail":"claude -p nonzero exit"}\n' \
      "$(date -u +%FT%TZ)" "${ITEM%%#*}" "${ITEM#*#}" >> "$LOG"
    sleep 30
    continue
  }
  echo "$RESULT" | jq -r '
    "[loop]   result: \(((.result // "") | tostring)[:160])",
    "[loop]   cost: $\((((.total_cost_usd // 0) * 100 | round) / 100))  session: \(((.session_id // "?") | tostring)[:8])"' \
    || echo "[loop]   result: (unparseable claude -p output)"
  echo "$RESULT" | jq -r '.session_id // empty' > dashboard/last-session.id || true
done

if [ "$DRY_RUN" = "0" ] && command -v gh-comment-audit >/dev/null; then
  echo "[loop] running gh-comment-audit --days 1"
  gh-comment-audit --days 1 | tail -5 || true
fi
echo "[loop] log: $LOG"
