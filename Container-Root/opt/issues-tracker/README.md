# issues-tracker runtime

Read-only GitHub pull request and issue triage tooling with a human-gated pen. Automation
reads GitHub and writes local files; a person posts.

## Contents

| Path | What it is |
|---|---|
| `scripts/gh-ro`, `scripts/gh_ro_api_check.py` | A wrapper that forwards only read invocations to `gh`. |
| `scripts/gh-dashboard.py`, `scripts/scan_coverage.py` | The inventory of PRs and issues, with a coverage proof; writes `dashboard/`. |
| `scripts/loop_pick.py`, `scripts/agent-loop.sh`, `scripts/cron-agent-loop.sh` | The picker and the headless worker loop. |
| `scripts/redact-scan.sh`, `scripts/redact-denylist.example.conf` | The redaction check for outward text. |
| `scripts/test_*` | The test suites. |
| `bin/pr-timeline`, `bin/gh-comment-audit` | One PR's reviews, review threads and comments; a report of recent comments. |
| `.claude/hooks/`, `.claude/settings.example.json` | The PreToolUse hooks that block outward writes and matching comments, and a session-start report. |
| `.claude-plugin/plugin.json` | Loads the tree as a Claude Code plugin. |

## Install

Requirements: `gh` (authenticated), `jq`, `python3` 3.10 or newer, `bash` and `git`; the
`claude` CLI for the worker loop; `flock` for `scripts/cron-agent-loop.sh`.

```bash
cp .claude/settings.example.json .claude/settings.local.json   # installs the PreToolUse hooks; do this first
cp scripts/redact-denylist.example.conf scripts/redact-denylist.conf
```

Site-specific lists and patterns go in a git-ignored site file,
`scripts/test_shipped_tree.local.conf` (or the path in `SHIPPED_TREE_DENYLIST_FILE`). Without
it the tools use neutral built-in defaults.

## Verify

```bash
for t in scripts/test_*.py; do python3 -m unittest "$t"; done
bash scripts/test_redact_scan_generic.sh && bash scripts/test_cron_blackout_gate.sh
```

## License

Apache License 2.0, see `LICENSE`.
