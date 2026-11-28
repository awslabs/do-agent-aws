# North Star — the `issues` spoke

Outward drafts are evidence-driven, scrubbed and human-confirmed; nothing is ever posted automatically. The spoke keeps
the person's open issues and pull requests triaged from what GitHub says at each scan - which conflict, whose checks
fail, where changes were requested, what waits for an answer - and tells `agent` only what changed. It reads GitHub
through a front that refuses every write, never reports a scan that did not complete as "nothing new", stages every
reply with its evidence for a person, and posts only through the GO gate: a person's GO naming the draft's sha256.

## The rule

A row counts only when a tracked check exists that FAILS if the property is removed (the register's rule,
`docs/NORTH-STAR.md`). A row without such a check scores **NO**, whatever the code looks like. **YES\*** below means
the check exists and fails with the property removed; it becomes **YES** when it is recorded passing on main.

## The rows

| ID | The spoke must | Check that fails if the property is removed | Verdict | Caveat |
|---|---|---|---|---|
| IS-1 | Post nothing without a person's GO naming the draft's sha256 and a person at a terminal typing its first 12 characters: no GO, an empty GO, a GO for another sha256, no terminal, other characters typed, a draft posted before, a draft that is a link, too large or cannot be hashed, or a record whose send line is not the command, and nothing is sent; no session may run post.sh or write a GO | `Container-Root/test-issues-spoke.sh` check 6 [go-gate]: a planted draft, no GO, a wrong GO, each other refusal planted alone, the right GO without a terminal and with other characters typed, then typed (exactly one comment from the private copy, read back), a second post; a draft rewritten after its hash and the private copy rewritten after its hash both send only the bytes the GO named or nothing; the shared deny rules on post.sh and the GO files | **YES\*** | every session runs as root in one container: one that built a pseudo-terminal around its deny rules, or a person running post.sh under a wrapper such as `script`, could pass the terminal check |
| IS-2 | Send a draft only when it is scrubbed: the harness's privacy scan finds nothing in it | check 6 [go-gate]: a draft with a token shape and a matching GO is refused | **YES\*** | with the vendored tree its `redact-scan.sh --strict` gates too: a planted tree whose scan refuses is refused (check 6) |
| IS-3 | Read GitHub only: every call of its cycle is a read, and the front refuses each write form before gh runs | check 2 [front-refuses-writes] (`loop.sh --self-test`) and check 4 [cycle-rows-read-only] (every recorded call a read, no refusal) | **YES\*** | the front binds the scripts, not the session (charter, "Honest limits") |
| IS-4 | Run no cycle without a token: wait for GitHub instead | check 3 [waiting-for-github] | **YES\*** | |
| IS-5 | Surface conflicts, failing checks, requested changes and owed replies from the items' state | check 4 [cycle-rows-read-only] | **YES\*** | the fixtures are a recording stub, not GitHub |
| IS-6 | Never call a scan that did not complete "nothing new" | check 4 [cycle-rows-read-only]: a failing read makes the scan PARTIAL, exit 1, the last complete scan kept | **YES\*** | |
| IS-7 | Answer `agent` from its scan: which pull requests conflict | check 5 [hub-asks-conflicting] | **YES\*** | |
| IS-8 | Base every outward claim on verified evidence: a `file:line` at a named commit, the three channels read | none: prose quality has no tracked check | **NO** | the draft's record asks for it; a person checks it at the GO |
| IS-9 | Keep its own session from posting: its pane holds no GitHub token and runs without the hub's permission bypass, its settings deny the write paths (incl. the gh shim, the gate, the private directory, the tracker and the agent tree) and its hook covers the file-writing tools as well as Bash and the GitHub tools, refusing a file write to those paths, the operator token, post.sh, GO files and every GitHub write form; the shim and the private copy live outside the session's working directory | check 6b [session-walls], and the shim's location + rewrite in check 4 | **YES\*** | the walls bind the session's tools, not a sandbox: every session runs as root in one container, and one that reads another process's environment around its deny rules is stopped by its charter alone |
| IS-10 | Keep its UIs current: the Board, the Goals board and the Project board (Plane) show its rows (the Board and the Project board only with the Plane board on, `UI_PLANE=true`; it is off by default) | none: the boards have no path for a spoke's rows yet, and their data still comes from the hub's autonomy loop | **NO** | `status.json` carries the rows for that hook |
| IS-11 | Read through the vendored issues tracker's front and send through its gates where the image carries it | check 2 [front-refuses-writes] runs its `scripts/gh-ro`, and check 6 [go-gate] its `redact-scan.sh --strict`, both hooks and the place of the hook's audit line | **YES\*** | the front's GraphQL reads are checked by its owner's tests, not here |
| IS-12 | Scan the scope it names: repositories named are read by the spoke's own scan, the vendored scan only inventories the login's own items | check 4b [named-repos-own-scan], with a planted tree | **YES\*** | the vendored scan's rows are checked by its owner's tests; the stub serves the spoke's own scan |
