# Comms channel: email (IMAP)

The comms engine's `email` adapter watches mailboxes on any RFC-3501 IMAP server (Outlook/M365,
Gmail with an app password, a self-hosted server). It is **read-only by transport**: every
mailbox selection is forced read-only (`EXAMINE`), every fetch uses `BODY.PEEK` so your unread
mail is never marked read, and there is no send path at any layer (no SMTP, no APPEND).

## 1. Credential

The adapter authenticates with **IMAP `LOGIN` over TLS** - a username and password, nothing
else. What that means per provider:

* **Outlook / Microsoft 365:** basic auth is disabled on most tenants; you need an
  **app password** (requires MFA to be enabled, and a tenant policy that permits app
  passwords), or a tenant that still allows basic IMAP auth. If your tenant offers neither,
  this adapter cannot connect - **no OAuth2/XOAUTH2 is shipped** (a token dance the engine
  cannot test end-to-end is deliberately not shipped half-done).
* **Gmail:** an app password (Google account → Security → 2-Step Verification → App passwords).
* **Self-hosted:** any account the server accepts over `LOGIN` on port 993.

You also need the IMAP **host** (e.g. `outlook.office365.com`, `imap.gmail.com`) and the
**mailbox names** to watch (`INBOX` is the universal one; others as your server names them).

## 2. Environment variables into the container

The app password is a credential: add `IMAP_PASSWORD` (and `IMAP_USERNAME`, `IMAP_HOST` if you like) to the AWS
Secrets Manager secret the container reads at start (docs/manual/aws.md "Credentials from AWS Secrets Manager" - its step 2
types values in without an echo). The rest are plain settings:

```bash
export IMAP_HOST="outlook.office365.com"     # host shell
export IMAP_USERNAME="you@example.com"
export IMAP_MAILBOXES="INBOX"                # comma-separated, e.g. INBOX,Archive
```

In `.env.local`: `export AGENT_SECRETS_ID=do-agent-aws/credentials` and
`export COMMS_ENV_NAMES="IMAP_HOST IMAP_USERNAME IMAP_PASSWORD IMAP_MAILBOXES"`, then `./stop.sh && ./run.sh`. For a
quick local trial, `read -rs IMAP_PASSWORD; export IMAP_PASSWORD` in the host shell before `./run.sh` works too (typed
unechoed, so it stays out of every file and the shell history), with a start WARNING naming it.

## 3. The instance - UI fields and file form

UI route: adapter `email`, four auth entries - `host` → `IMAP_HOST`, `username` →
`IMAP_USERNAME`, `password` → `IMAP_PASSWORD`, `channels` → `IMAP_MAILBOXES`; monitored channel
id = each mailbox name (e.g. `INBOX`).

File route:

```json
{"name": "email-watch", "adapter": "email",
 "auth": {"host": "env:IMAP_HOST", "username": "env:IMAP_USERNAME",
          "password": "env:IMAP_PASSWORD", "channels": "env:IMAP_MAILBOXES"},
 "channels": [{"id": "INBOX", "label": "inbox", "reply_policy": "never"}]}
```

**The two-place rule:** every mailbox name appears in BOTH `IMAP_MAILBOXES` and `channels[]`,
spelled identically (IMAP mailbox names are server-defined; `INBOX` is case-insensitive by
RFC, everything else may not be).

## 4. Verify, then watch

```sh
docker exec do-agent-aws sh -c 'cd /opt/comms && python3 -m core.doctor --config /wd/comms/settings.json'
```

Expect `DOCTOR OK`. A wrong password surfaces in the health check at LOGIN; a mailbox in only
one of the two places fails `readable` by name. Then:

```sh
docker exec do-agent-aws /agent/comms-watch-start.sh
docker exec do-agent-aws /agent/comms-watch-status.sh
```

Send yourself a message; it appears within the poll interval - **no push**: this is a polling
adapter (IMAP IDLE is deliberately not used), so arrival latency is the poll interval, not
seconds.

## Honest limits

* **Documented and offline-verified only.** The engine's email adapter is proven by its own
  offline test suite against scripted IMAP conversations; its docs state plainly that it has
  not run against a live server as part of the engine's own verification, and it has not been
  run against one here either. Your `core.doctor` run in step 4 is the live
  verification, on your own mailbox.
* No OAuth2, no IDLE (see above); servers that throttle or refuse LOGIN surface through the
  health check, not a rate-limit dialect.
* A `UIDVALIDITY` reset by the server (rare; some migrations do it) restarts the mailbox read
  from the beginning - re-served history lands as duplicates the store absorbs, the direction
  that never loses mail.
* Ordering is mailbox arrival order, not the sender-controlled `Date` header.
