#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""agent-chat.py - the Agent chat page: the agent's tmux pane in the browser, and a box that types a message into it.

Talking to the agent without Slack. Serves http://127.0.0.1:UI_PORT_CHAT (default 8094) inside the agent container;
/agent/ui-start.sh starts it with the other UIs (UI_CHAT=true in .env) and the home proxy routes the host
chat.localhost to it (/agent/home-render.sh). The home page's "Agent chat" tile opens it in a new tab. The session it
shows and types into is the shared agent tmux session (AGENT_TMUX_SESSION_NAME, default agent) - the one the browser
terminal at /tmux/ shows - and within it the pane a person attached to the session would be looking at.

Routes, and all of them:
  GET  /         the page: the pane's text, HTML-escaped, with the state of the pane, the send box and an
                 acknowledgement line; the page refreshes the text from /pane every two seconds
  GET  /pane     the pane's current text as text/plain: `tmux capture-pane -p` of the session's active pane, the last
                 AGENT_CHAT_LINES lines of its history included - what a person sees in the terminal, nothing else
  GET  /state    JSON: the session and pane this page talks to, the pane's foreground command, whether a send would
                 be accepted right now and, when not, why; what the pane's bottom shows (the agent's prompt, a menu,
                 or neither) and, for a menu, its question and options
  POST /send     {"text": "..."}: types the text into the pane as LITERAL keystrokes (`tmux send-keys -l`, so tmux
                 reads no key names out of it) and then, as a separate keystroke, Enter. The answer says that the text
                 reached the session's prompt and was submitted - a transport acknowledgement, never a statement about
                 what the agent did with it; the pane shows that
  POST /answer   {"option": N, "key": "..."}: answers the menu the pane shows with option N - the one key "N", exactly as
                 a person would press it, and Enter only if the menu is still up with that option highlighted. "key"
                 names the menu the page showed (its question and options); a menu that has changed since is refused
  GET  /healthz  200 while the server runs: the home page's status dot (its /__probe/chat location) and ui-status.sh

The write is bounded like the browser terminal's keystrokes, and narrower:
  - only the hub's pane: a session the registry (SPOKES_REGISTRY, /agent/spokes/registry.json) lists as a spoke or as
    the supervisor is refused with 409, whatever AGENT_TMUX_SESSION_NAME says - a spoke is messaged by the hub
    (docs/INTER-AGENT-MESSAGING.md), never typed into from the browser, and its menus are never answered from here
  - the pane is checked right before each of the two keystrokes: it must belong to the configured session and its
    foreground command must be the agent CLI (pane_current_command in AGENT_CHAT_COMMANDS, default "claude"). A pane
    running a shell, or anything else, is refused with 409 and the reason - nothing is ever typed into a shell. When
    the agent leaves the pane between the text and the Enter, the Enter is not sent and the answer says so
  - a message is typed only at the agent's PROMPT. When the agent shows a menu instead - an approval ("Do you want to
    proceed?" with numbered choices), a question with options, a selection list - a message is refused with 409 naming
    the menu, because a menu reads keys: letters are ignored and the Enter would pick the highlighted choice, an
    approval the person never gave. The page shows the menu's text and, for numbered choices, one button per option;
    a button sends that option's number through /answer, nothing else. A list without numbers is answered in the
    terminal. The prompt and a menu are read from the pane's text as Claude Code draws them (the prompt a "❯" line
    between two horizontal rules, a menu's highlighted item "❯ 1. ..." or "❯ [✔] ..."); when the pane runs claude and
    shows neither - it is starting, or a dialog without a cursor is up - a message is refused too, saying so. For
    another agent CLI in AGENT_CHAT_COMMANDS only a menu is refused (its prompt's shape is not known here). The pane
    is read again after the text and before the Enter: a menu that appeared meanwhile leaves the text at the prompt
    unsubmitted, and the answer says so
  - POST only, and only from this page's own origin: the request's Origin (or, from a browser that sends none, its
    Referer) must be http(s)://chat.localhost on the port the request arrived on (its Host); anything else is 403.
    No answer carries a CORS header and every answer forbids framing, so another site's page can neither read the
    pane nor type into it. Every route but /healthz also refuses a Host that is not chat.localhost (403): a DNS
    rebinding page arrives with its own name
  - the text is capped (AGENT_CHAT_MAX_LEN characters, default 4000; the body at a few bytes per character), and
    every control character in it - newlines, tabs, escape sequences, DEL, the C1 range - becomes a space, so a
    message is one line typed at the prompt and nothing in it can drive the terminal
  - the text never meets a shell here: tmux is called with an argument list, the message one argument. One tmux rule
    applies to that argument: a trailing ";" would be read as a command separator (and a trailing "\\;" as ";"), so a
    message that ends in ";" is handed over as text[:-1] + "\\;" and arrives exactly
  - sends are serialized: one lock around the whole check - text - check - Enter sequence, so two messages at once
    arrive as two lines, each followed by its own Enter, never interleaved; the page also sends one message at a time
  - UI_TMUX_WRITABLE other than exactly "true" (the rule of the terminal, the dashboard and the tile) is a watch-only
    harness: the page still shows the pane, a POST is 403
  - the command check compares the pane's foreground process name with AGENT_CHAT_COMMANDS: a guard against typing
    into the wrong program (a shell at the prompt), not authentication - a process named claude passes it
  - the agent CLI reads the message as typed input, so its own syntax applies (for Claude Code: a message starting
    with "!" is its bash mode, one starting with "/" a command) - the page is as capable as the terminal, behind the
    same boundary
Every answer carries Cache-Control: no-store (the pane's text and an acknowledgement are of this moment),
X-Content-Type-Options: nosniff, X-Frame-Options DENY and the Content-Security-Policy - the ones the standard library
writes itself (501 for a method the page has no handler for, 431 for too many header lines) included. The one answer
without them is the standard library's to a request line that names no HTTP version: an HTTP/0.9 answer, which by
protocol has no status line and no headers, only the library's error page as its body. A request whose
body does not arrive within AGENT_CHAT_READ_TIMEOUT seconds is dropped, and a tmux that does not answer within
AGENT_CHAT_TMUX_TIMEOUT seconds is an error answer, never an unanswered request. The trust boundary is the harness's:
loopback only, behind the home proxy, through the SSH tunnel, exactly like the writable terminal at /tmux/. Nothing is
logged but the method, path and status.

Settings (environment; ui-start.sh passes them on from .env):
  UI_PORT_CHAT (8094)              AGENT_TMUX_SESSION_NAME (agent)     AGENT_CHAT_COMMANDS (claude; space-separated)
  SPOKES_REGISTRY (/agent/spokes/registry.json: the sessions this page must never type into)
  AGENT_CHAT_MAX_LEN (4000)        AGENT_CHAT_LINES (400)              UI_TMUX_WRITABLE (true)
  AGENT_CHAT_HOST (chat.localhost: the host name the page answers on, the one home-render.sh routes)
  AGENT_CHAT_READ_TIMEOUT (10 s: a request's body)   AGENT_CHAT_TMUX_TIMEOUT (10 s: one tmux call)
"""
import hashlib
import html
import json
import os
import re
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("UI_PORT_CHAT", "8094"))
SESSION = os.environ.get("AGENT_TMUX_SESSION_NAME", "agent") or "agent"
REGISTRY = os.environ.get("SPOKES_REGISTRY", "/agent/spokes/registry.json") or "/agent/spokes/registry.json"
COMMANDS = set((os.environ.get("AGENT_CHAT_COMMANDS", "claude") or "claude").split())
MAX_LEN = int(os.environ.get("AGENT_CHAT_MAX_LEN", "4000"))
LINES = int(os.environ.get("AGENT_CHAT_LINES", "400"))
# exactly "true" is writable - the rule ttyd, the tmux-agent dashboard and the home page's tile apply to the same flag
WRITABLE = os.environ.get("UI_TMUX_WRITABLE", "true") == "true"
READ_TIMEOUT = float(os.environ.get("AGENT_CHAT_READ_TIMEOUT", "10"))
TMUX_TIMEOUT = float(os.environ.get("AGENT_CHAT_TMUX_TIMEOUT", "10"))
# one send at a time: the check - text - check - Enter sequence of one message never interleaves with another's
SEND_LOCK = threading.Lock()
SECURITY_HEADERS = (
    ("Cache-Control", "no-store"),
    ("X-Content-Type-Options", "nosniff"),
    ("X-Frame-Options", "DENY"),
    ("Referrer-Policy", "same-origin"),
    ("Content-Security-Policy", "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; "
                                "connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"),
)
CHAT_HOST = os.environ.get("AGENT_CHAT_HOST", "chat.localhost") or "chat.localhost"
HOST_OK = re.compile(r"^" + re.escape(CHAT_HOST) + r"(:[0-9]{1,5})?$", re.I)
ORIGIN_OK = re.compile(r"^https?://" + re.escape(CHAT_HOST) + r"(?::([0-9]{1,5}))?(?:/|$)", re.I)
# C0 controls (newline, tab, escape, ...), DEL and the C1 range: none of them belongs in a line typed at a prompt
CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")
COMMANDS_SHOWN = ", ".join(sorted(COMMANDS))
# The prompt and a menu as the agent CLI draws them. Claude Code's input prompt is a "❯" line between two horizontal
# rules (the typed text, if any, after the cursor, wrapping below it). A selection menu - an approval, a question with
# options, a checkbox list - hides the prompt and highlights one item with the same cursor: "❯ 1. Yes" with its
# siblings "  2. ...", or "❯ [✔] name". The pane's own earlier inputs are echoed as "❯ text" too, without rules or
# siblings; they are neither. These shapes are Claude Code's, so the prompt rule applies to a pane running claude.
PROMPT_SHAPE_COMMANDS = {"claude"}
CURSOR = re.compile(r"^\s*❯(?:\s+(.*?))?\s*$")
RULE = re.compile(r"^\s*[─━]{8,}")
OPTION = re.compile(r"^\s*(❯\s+)?(\d{1,2})\.\s+(\S.*?)\s*$")
CHECKBOX = re.compile(r"^\s*(❯\s+)?\[([ ✔✓x])\]\s+(\S.*?)\s*$")
DIVIDER = re.compile(r"^\s*[─━╌┄┈═╭╮╰╯│]{3,}")
MENU_LINES = 40          # the pane's bottom, where the prompt or a menu is: as many lines as a tall terminal shows
MENU_CONTEXT = 8         # lines of the dialog above the options shown with the menu (the command to approve, the question)
ANSWER_WAIT = float(os.environ.get("AGENT_CHAT_ANSWER_WAIT", "1.5"))   # how long a menu is given to react to a key

PAGE = """<!DOCTYPE html>
<html lang="en" class="hs-root">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Agent chat - do-agent-aws harness</title>
<link rel="stylesheet" href="/__harness/harness.css">
<style>
/* the harness look (docs/UI-STYLE.md): the tokens and components of /__harness/harness.css, linked above and served on
   this host too; only this page's own layout is here, every colour one of the tokens, so the page follows both themes */
html, body { height: 100%; }
body.hs-page { display: flex; flex-direction: column; font-size: 14px; line-height: 1.4; }
header.hs-header { padding: 10px var(--hs-space-3); }
header.hs-header h1 { font-size: 17px; }
header.hs-header p { margin: 3px 0 0; font-size: 12px; }
#state { padding: 6px var(--hs-space-3); font-size: 12px; background: var(--hs-surface); border-bottom: 1px solid var(--hs-border); color: var(--hs-muted); }
/* a state is a word (in the text token) with a shape filled in the fixed status step, never a colour alone */
#state::before, #ack.ok::before, #ack.bad::before { content: ""; display: inline-block; width: 10px; height: 10px; border-radius: 50%; border: 2px solid var(--hs-fg); margin-right: 6px; vertical-align: -1px; }
#state.ready { color: var(--hs-fg); }
#state.ready::before { background: var(--hs-ok); }
#state.off { color: var(--hs-fg); }
#state.off::before { background: linear-gradient(90deg, var(--hs-warn) 50%, transparent 50%); }
/* hold: the pane runs the agent, but a menu or a dialog is up instead of its prompt - a square in the warning step */
#state.hold { color: var(--hs-fg); }
#state.hold::before { border-radius: 2px; background: var(--hs-warn); }
#pane { flex: 1; margin: 0; padding: var(--hs-space-2) var(--hs-space-3) 14px; overflow: auto; white-space: pre-wrap; overflow-wrap: anywhere; font: 13px/1.35 var(--hs-mono); color: var(--hs-fg); }
/* the menu the agent shows: its text as the pane shows it, one button per numbered option */
#menu { padding: var(--hs-space-2) var(--hs-space-3); background: var(--hs-surface); border-top: 2px solid var(--hs-warn); }
#menu h2 { margin: 0 0 4px; font-size: 13px; color: var(--hs-fg); }
#menu pre { margin: 0 0 8px; max-height: 9em; overflow: auto; white-space: pre-wrap; overflow-wrap: anywhere; font: 12px/1.35 var(--hs-mono); color: var(--hs-fg); }
#menu .opt { margin: 0 8px 6px 0; padding: 7px 12px; font: 600 13px var(--hs-font); color: var(--hs-bg); background: var(--hs-accent); border: 0; border-radius: var(--hs-radius); cursor: pointer; }
#menu .opt:disabled { background: var(--hs-muted); cursor: not-allowed; }
#menu .hint { margin: 0; font-size: 12px; color: var(--hs-muted); }
#send { display: flex; gap: 8px; padding: var(--hs-space-2) var(--hs-space-3); background: var(--hs-surface); border-top: 1px solid var(--hs-border); }
#text { flex: 1; padding: 9px 10px; font: 14px var(--hs-font); color: var(--hs-fg); background: var(--hs-bg); border: 1px solid var(--hs-border); border-radius: var(--hs-radius); }
#text:disabled { color: var(--hs-muted); }
#button { padding: 9px 18px; font: 600 14px var(--hs-font); color: var(--hs-bg); background: var(--hs-accent); border: 0; border-radius: var(--hs-radius); cursor: pointer; }
#button:disabled { background: var(--hs-muted); color: var(--hs-bg); cursor: not-allowed; }
#ack { min-height: 1.2em; padding: 0 var(--hs-space-3) var(--hs-space-2) var(--hs-space-3); font-size: 12px; color: var(--hs-muted); background: var(--hs-surface); }
#ack.ok { color: var(--hs-fg); }
#ack.ok::before { background: var(--hs-ok); }
#ack.bad { color: var(--hs-fg); }
#ack.bad::before { border-radius: 2px; background: var(--hs-bad); }
#ack:empty { padding-bottom: 6px; }
/* under 481 px the harness home badge sits at the bottom left (home-render.sh's phone rule): leave it room below the
   send row, so it never covers the box */
@media (max-width: 480px) { #ack, #ack:empty { padding-bottom: 50px; } }
/* wider: the badge sits at the bottom right; the send row and the acknowledgement end before it */
@media (min-width: 481px) { #send, #ack { padding-right: 150px; } }
</style>
</head>
<body class="hs-page">
<header class="hs-header">
<h1>Agent chat</h1>
<p>the agent's tmux session <code>__SESSION__</code>, as the <a id="terminal" href="/tmux/">browser terminal</a> shows it,
refreshed every two seconds. A message typed below is typed at the agent's prompt and submitted with Enter.</p>
</header>
<div id="state">checking the agent session&#8230;</div>
<pre id="pane">__PANE__</pre>
<div id="menu" hidden>
<h2>The agent is asking</h2>
<pre id="menu-text"></pre>
<div id="menu-options"></div>
<p class="hint" id="menu-hint"></p>
</div>
<div id="send">
<input id="text" type="text" maxlength="__MAX_LEN__" autocomplete="off" spellcheck="false" placeholder="message the agent (Enter to send)">
<button id="button" type="button">Send</button>
</div>
<div id="ack"></div>
<script>
(function () {
  var pane = document.getElementById('pane'), state = document.getElementById('state'), ack = document.getElementById('ack');
  var text = document.getElementById('text'), button = document.getElementById('button');
  var menu = document.getElementById('menu'), menuText = document.getElementById('menu-text');
  var menuOptions = document.getElementById('menu-options'), menuHint = document.getElementById('menu-hint');
  // the terminal link: the home listener on the port this page is on (chat.localhost:<port> -> localhost:<port>)
  document.getElementById('terminal').href = '//' + location.host.replace(/^[^.]+\\./, '') + '/tmux/';
  var inFlight = false;
  // the menu the agent shows, rebuilt only when it is another menu (its key), so a button under the pointer stays
  function renderMenu(m) {
    if (!m) { menu.hidden = true; menu.dataset.key = ''; menuOptions.textContent = ''; return; }
    if (!menu.hidden && menu.dataset.key === m.key) return;
    menu.dataset.key = m.key;
    menuText.textContent = m.context.join('\\n');
    menuOptions.textContent = '';
    if (m.kind === 'numbered') {
      m.options.forEach(function (o) {
        var b = document.createElement('button');
        b.type = 'button'; b.className = 'opt'; b.textContent = o.n + '. ' + o.text;
        b.addEventListener('click', function () { answer(m.key, o.n, o.text); });
        menuOptions.appendChild(b);
      });
      menuHint.textContent = 'A button presses that option\\'s number in the session, exactly as the key would in the terminal, and nothing else. ' +
        'The screen above shows what the agent does with it.';
    } else {
      menuHint.textContent = 'A selection list has no numbers to press: answer it in the browser terminal (the link above).';
    }
    menu.hidden = false;
  }
  function refresh() {
    fetch('/pane', { cache: 'no-store' }).then(function (r) { return r.text().then(function (t) { return { ok: r.ok, text: t }; }); })
      .then(function (p) {
        var stick = pane.scrollTop + pane.clientHeight >= pane.scrollHeight - 40;
        pane.textContent = p.text;
        if (stick) pane.scrollTop = pane.scrollHeight;
      }).catch(function () { state.className = 'off'; state.textContent = 'the chat backend is not answering'; });
    fetch('/state', { cache: 'no-store' }).then(function (r) { return r.json(); }).then(function (s) {
      var typing = s.writable && !s.hold;
      if (typing) {
        state.className = 'ready';
        state.textContent = 'session ' + s.session + ', pane ' + s.pane + ' runs ' + s.command + ' at its prompt - a message is typed there';
      } else if (s.writable) {
        state.className = 'hold';
        state.textContent = 'not typing: ' + s.hold;
      } else {
        state.className = 'off';
        state.textContent = 'sending is off: ' + s.reason;
      }
      text.disabled = button.disabled = !typing;
      renderMenu(s.writable ? s.menu : null);
    }).catch(function () {});
  }
  function answer(key, n, label) {
    if (inFlight) return;
    inFlight = true;
    ack.className = ''; ack.textContent = 'answering\\u2026';
    fetch('/answer', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ option: n, key: key }), cache: 'no-store' })
      .then(function (r) { return r.json().then(function (j) { return { ok: r.ok, status: r.status, json: j }; }); })
      .then(function (a) {
        if (a.ok && a.json.answered) {
          ack.className = 'ok';
          ack.textContent = 'Answered the menu at ' + a.json.at + ' with option ' + n + ' (' + label + '): ' + a.json.how + ' pressed in the session. ' +
            'That is the transport only - the screen above shows what the agent does with it.';
        } else {
          ack.className = 'bad';
          ack.textContent = 'Not answered (HTTP ' + a.status + '): ' + (a.json.error || 'no reason given');
        }
        inFlight = false;
        setTimeout(refresh, 400);
      }).catch(function () { ack.className = 'bad'; ack.textContent = 'Not answered: the chat backend did not answer'; inFlight = false; });
  }
  function send() {
    var v = text.value.trim();
    if (!v || inFlight) return;
    inFlight = true;
    button.disabled = true;
    ack.className = ''; ack.textContent = 'sending\\u2026';
    fetch('/send', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ text: v }), cache: 'no-store' })
      .then(function (r) { return r.json().then(function (j) { return { ok: r.ok, status: r.status, json: j }; }); })
      .then(function (a) {
        if (a.ok && a.json.sent) {
          if (text.value.trim() === v) text.value = '';
          ack.className = 'ok';
          ack.textContent = 'Sent to the session at ' + a.json.at + ' (' + a.json.chars + ' characters typed at the prompt and submitted). ' +
            'That is the transport only - the screen above shows what the agent does with it.';
        } else {
          ack.className = 'bad';
          ack.textContent = 'Not sent (HTTP ' + a.status + '): ' + (a.json.error || 'no reason given');
        }
        inFlight = false;
        button.disabled = false;
        setTimeout(refresh, 400);
      }).catch(function () { ack.className = 'bad'; ack.textContent = 'Not sent: the chat backend did not answer'; inFlight = false; button.disabled = false; });
  }
  button.addEventListener('click', send);
  text.addEventListener('keydown', function (e) { if (e.key === 'Enter') { e.preventDefault(); send(); } });
  refresh();
  setInterval(refresh, 2000);
})();
</script>
</body>
</html>
"""


def tmux(*args):
    """One tmux call with an argument list - the message is one argument, whatever it contains; never a shell. Never
    raises: a tmux that does not answer in time, or is not there, is a failed call whose stderr says so."""
    try:
        return subprocess.run(["tmux", *args], capture_output=True, text=True, timeout=TMUX_TIMEOUT, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as e:
        return subprocess.CompletedProcess(["tmux", *args], -1, "", f"tmux did not answer ({e.__class__.__name__})")


def pane():
    """(pane id, foreground command, error) for the session's active pane. tmux exits 0 with EMPTY output for a
    target that does not exist, so the id is checked by shape; '=name:' pins the exact session name (a bare name
    prefix-matches, so a session agent-2 would satisfy a check for agent)."""
    r = tmux("display-message", "-t", f"={SESSION}:", "-p",
             "#{pane_id}\t#{pane_current_command}\t#{pane_dead}\t#{session_name}")
    if r.returncode == -1:
        return None, "", r.stderr
    f = r.stdout.rstrip("\n").split("\t")
    if r.returncode != 0 or len(f) != 4 or not re.fullmatch(r"%[0-9]+", f[0]):
        return None, "", f"no tmux session named {SESSION!r} (AGENT_TMUX_SESSION=true creates it at container start)"
    pane_id, command, dead, name = f
    if name != SESSION:
        return None, command, f"tmux resolved another session, {name!r}"
    if dead != "0":
        return None, command, "the agent session's pane has exited"
    return pane_id, command, ""


def registry_role(name):
    """The role the registry gives a session - hub, supervisor or spoke - or None for a session it does not list (or a
    registry that is not there or not readable: then no session is a spoke). Read at every check: it is small."""
    try:
        sessions = json.load(open(REGISTRY, encoding="utf-8")).get("sessions") or []
    except (OSError, ValueError, AttributeError):
        return None
    for e in sessions:
        if isinstance(e, dict) and e.get("session_name") == name:
            return e.get("role") if isinstance(e.get("role"), str) else "an entry"
    return None


def writable():
    """(ok, pane id, command, reason) - whether a send would be accepted right now."""
    if not WRITABLE:
        return False, None, "", "this harness is watch-only (UI_TMUX_WRITABLE=false in .env): the page shows the pane, nothing is typed"
    pane_id, command, error = pane()
    if error:
        return False, None, command, error
    role = registry_role(SESSION)
    if role is not None and role != "hub":
        return False, pane_id, command, (f"the session {SESSION!r} is the registry's {role} ({REGISTRY}), not the hub: the Agent "
                                          "chat types only into the pane of the agent you talk to - a spoke is messaged by the hub "
                                          "(docs/INTER-AGENT-MESSAGING.md), never typed into from here")
    if command not in COMMANDS:
        return False, pane_id, command, (f"the agent session's pane runs {command!r}, not the agent CLI ({COMMANDS_SHOWN}) - "
                                          "nothing is typed into it; start the agent in the pane, or wait for it")
    return True, pane_id, command, ""


def capture():
    """The active pane's text (its last LINES lines of history included), or an error."""
    pane_id, _, error = pane()
    if error:
        return None, error
    r = tmux("capture-pane", "-p", "-t", pane_id, "-S", f"-{LINES}")
    if r.returncode != 0:
        return None, "tmux could not read the pane: " + r.stderr.strip()
    # the pane's trailing empty rows are not part of what was written to it
    return re.sub(r"\n*\Z", "\n", r.stdout), ""


def screen_state(text):
    """What the pane's bottom shows, read from its text: ("prompt", None) - the agent's input prompt, where a message
    can be typed; ("menu", menu) - a selection menu with the cursor on one item; ("other", None) - neither (the agent
    starting, a dialog without a cursor, a program that draws its prompt another way). The menu: its kind (numbered -
    an approval or a question with options, answerable by number; list - a checkbox list, answered in the terminal),
    the dialog's lines above the options (what is being approved), its question, the options with the highlighted one,
    and a key naming exactly this menu (the question and the options), so an answer is matched to what the page showed.
    The last cursor line decides: the prompt has a rule right above it and one below (the typed text may wrap in
    between); a menu's cursor sits on a numbered or checkbox item among its siblings; an echoed earlier input is neither."""
    lines = text.rstrip("\n").split("\n")[-MENU_LINES:]
    cursors = [i for i, l in enumerate(lines) if CURSOR.match(l)]
    if not cursors:
        return "other", None
    i = cursors[-1]
    below = lines[i + 1:i + 31]
    if i > 0 and RULE.match(lines[i - 1]) and any(RULE.match(l) for l in below) and not any(CURSOR.match(l) for l in below):
        return "prompt", None
    for kind, pat in (("numbered", OPTION), ("list", CHECKBOX)):
        if not pat.match(lines[i]):
            continue
        # the item's siblings above and below; between items a menu may show an item's description (indented under
        # it) or a rule (a question menu's last choices sit under one) - never a blank line or other text
        def filler(l):
            s = l.strip()
            return bool(s) and bool(RULE.match(l) or DIVIDER.match(l) or (l.startswith("    ") and not pat.match(l)))
        rows = [i]
        j = i + 1
        while j < len(lines) and (pat.match(lines[j]) or filler(lines[j])):
            if pat.match(lines[j]):
                rows.append(j)
            j += 1
        j = i - 1
        while j >= 0 and (pat.match(lines[j]) or filler(lines[j])):
            if pat.match(lines[j]):
                rows.insert(0, j)
            j -= 1
        options = []
        for k in rows:
            g = pat.match(lines[k])
            if kind == "numbered":
                options.append({"n": int(g.group(2)), "text": g.group(3), "selected": bool(g.group(1))})
            else:
                options.append({"n": len(options) + 1, "text": g.group(3), "checked": g.group(2) != " ", "selected": bool(g.group(1))})
        if kind == "numbered" and (len(options) < 2 or [o["n"] for o in options] != list(range(1, len(options) + 1))):
            return "other", None
        # the dialog above the options, up to its top rule: the command to approve, the question
        context = []
        for l in reversed(lines[:rows[0]]):
            if RULE.match(l) or len(context) >= MENU_CONTEXT:
                break
            s = l.strip()
            if s and not DIVIDER.match(s):
                context.insert(0, s)
        questions = [s for s in context if s.endswith("?")]
        question = questions[-1] if questions else (context[0] if context else "")
        # the key names this dialog: its text above the options too, so two approvals with the same choices for two
        # different commands are two menus
        key = hashlib.sha1("\n".join(context + [question] + [o["text"] for o in options]).encode(), usedforsecurity=False).hexdigest()[:16]
        return "menu", {"kind": kind, "question": question[:200], "context": context, "options": options, "key": key,
                        "selected": next((o["n"] for o in options if o["selected"]), None)}
    return "other", None


def hold_reason(command, screen, menu):
    """Why a message is not typed right now at a pane that runs the agent CLI, or "" when it is: a menu is up (named),
    or - for a CLI whose prompt shape is known - the prompt is not shown."""
    if screen == "menu":
        q = menu["question"] or "a selection"
        if menu["kind"] == "numbered":
            return (f"the agent is asking {q!r} with {len(menu['options'])} numbered options - a message is not typed into a "
                    "menu (its Enter would answer it); choose an option below, or answer in the browser terminal")
        return (f"the agent shows a selection list ({q!r}, {len(menu['options'])} items) - a message is not typed into it; "
                "answer it in the browser terminal")
    if screen != "prompt" and command in PROMPT_SHAPE_COMMANDS:
        return ("the agent's prompt is not shown (the agent is starting, or a dialog is up) - a message is typed only at "
                "the prompt; wait, or look in the browser terminal")
    return ""


def look():
    """(screen, menu, error): one capture of the pane, read; on a pane that cannot be read, the error."""
    text, error = capture()
    if text is None:
        return "other", None, error
    screen, menu = screen_state(text)
    return screen, menu, ""


def same_origin(headers, host):
    """True when the request came from this page: its Origin, or (a browser without one) its Referer, is
    chat.localhost on the port the request arrived on. Another site's page cannot forge either header; it can only
    suppress the Referer, and a request with neither is refused."""
    port = host.rsplit(":", 1)[1] if ":" in host else "80"
    m = ORIGIN_OK.match(headers.get("Origin") or headers.get("Referer") or "")
    return bool(m) and (m.group(1) or "80") == port


class Handler(BaseHTTPRequestHandler):
    server_version = "do-agent-aws-chat"
    # a request whose body does not arrive in time holds no handler thread: the socket times out and the request is dropped
    timeout = READ_TIMEOUT

    def log_message(self, fmt, *args):
        # method, path and status only - never a message body
        sys.stderr.write("%s %s\n" % (self.log_date_time_string(), fmt % args))

    def end_headers(self):
        # on every answer, the ones the standard library writes itself included (501 for a method without a handler,
        # 400 for a malformed request): no-store, nosniff, no framing, the policy - and never a CORS header
        for name, value in SECURITY_HEADERS:
            self.send_header(name, value)
        super().end_headers()

    def _send(self, code, body, ctype="text/plain; charset=utf-8"):
        raw = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj) + "\n", "application/json")

    def _host(self):
        """The request's Host when it is this page's, else None after a 403 (a DNS-rebinding page's own name)."""
        host = self.headers.get("Host", "")
        if HOST_OK.match(host):
            return host
        self._send(403, f"refused: this page answers only on {CHAT_HOST}, not {host[:80]!r}\n")
        return None

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            return self._send(200, "ok\n")
        if path not in ("/", "/pane", "/state"):
            return self._send(404, "not found\n")
        if not self._host():
            return
        if path == "/pane":
            text, error = capture()
            return self._send(200 if text is not None else 503, text if text is not None else error + "\n")
        if path == "/state":
            ok, pane_id, command, reason = writable()
            screen, menu, hold = "", None, ""
            if ok:
                screen, menu, error = look()
                hold = error or hold_reason(command, screen, menu)
            return self._json(200, {"session": SESSION, "pane": pane_id, "command": command, "writable": ok,
                                    "reason": reason, "screen": screen, "menu": menu, "hold": hold,
                                    "agent_commands": sorted(COMMANDS), "max_len": MAX_LEN})
        # the page: one pane lookup and one capture, nothing else (the page reads /state for the rest)
        text, error = capture()
        shown = text if text is not None else f"(no pane to show: {error})\n"
        page = (PAGE.replace("__SESSION__", html.escape(SESSION))
                    .replace("__MAX_LEN__", str(MAX_LEN))
                    .replace("__PANE__", html.escape(shown)))
        self._send(200, page, "text/html; charset=utf-8")

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path not in ("/send", "/answer"):
            return self._send(404, "not found\n")
        host = self._host()
        if not host:
            return
        if not same_origin(self.headers, host):
            return self._json(403, {"sent": False, "error": f"refused: a message is accepted only from the chat page itself "
                                                              f"(an Origin or Referer of http://{CHAT_HOST} on this port)"})
        if not WRITABLE:
            return self._json(403, {"sent": False, "error": "this harness is watch-only (UI_TMUX_WRITABLE=false in .env): nothing is typed"})
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = -1
        if n <= 0 or n > MAX_LEN * 4 + 256:
            return self._json(413 if n > 0 else 400, {"sent": False, "error": f"the body must be JSON of at most {MAX_LEN * 4 + 256} bytes"})
        try:
            body = json.loads(self.rfile.read(n))
            text = body.get("text")
        except (ValueError, AttributeError):
            return self._json(400, {"sent": False, "error": 'the body must be JSON: {"text": "..."} or {"option": N, "key": "..."}'})
        if path == "/answer":
            return self.answer(body)
        if not isinstance(text, str):
            return self._json(400, {"sent": False, "error": "text must be a string"})
        # one line at the prompt: every control character becomes a space, then the ends are trimmed
        text = CONTROL.sub(" ", text).strip()
        if not text:
            return self._json(400, {"sent": False, "error": "nothing to send"})
        if len(text) > MAX_LEN:
            return self._json(413, {"sent": False, "error": f"the message is {len(text)} characters; the cap is {MAX_LEN}"})
        # tmux reads a trailing ";" in an argument as a command separator (and a trailing "\;" as ";"): a message that
        # ends in ";" is handed over with that one character escaped, and arrives exactly
        keys = text[:-1] + "\\;" if text.endswith(";") else text
        # one message at a time: the whole sequence under the lock, so two senders never interleave text and Enters
        with SEND_LOCK:
            ok, pane_id, command, reason = writable()
            if not ok:
                return self._json(409, {"sent": False, "error": reason})
            # the pane's bottom must be the agent's prompt: a menu reads keys (the Enter would answer it), and a
            # dialog or a starting agent is not a prompt either
            screen, menu, error = look()
            if error:
                return self._json(503, {"sent": False, "error": "the pane could not be read: " + error})
            hold = hold_reason(command, screen, menu)
            if hold:
                return self._json(409, {"sent": False, "error": hold, "screen": screen, "menu": menu})
            # the literal text first (-l: no key names read out of it; --: no option read out of it), then Enter as a
            # keystroke of its own - after a second look at the pane, so the Enter never lands anywhere but at the
            # agent's prompt the text was typed at: not in a shell the agent left behind, not in a menu that opened
            r = tmux("send-keys", "-t", pane_id, "-l", "--", keys)
            if r.returncode != 0:
                return self._json(502, {"sent": False, "error": "tmux did not accept the text: " + r.stderr.strip()})
            ok, pane_now, command_now, reason = writable()
            if not ok or pane_now != pane_id:
                return self._json(409, {"sent": False, "error": "the text was typed but not submitted: before the Enter the pane "
                                                                  + ("changed" if ok else f"stopped qualifying ({reason})")})
            screen, menu, error = look()
            if screen == "menu":
                return self._json(409, {"sent": False, "screen": screen, "menu": menu,
                                        "error": "the text was typed but not submitted: before the Enter the agent opened a menu "
                                                 f"({menu['question'] or 'a selection'}); the text waits at the prompt, the menu is "
                                                 "answered first"})
            r = tmux("send-keys", "-t", pane_id, "Enter")
            if r.returncode != 0:
                return self._json(502, {"sent": False, "error": "the text was typed but tmux did not accept the Enter: " + r.stderr.strip()})
        self._json(200, {"sent": True, "chars": len(text), "session": SESSION, "pane": pane_id, "command": command,
                         "at": time.strftime("%H:%M:%S UTC", time.gmtime()),
                         "note": "typed at the agent's prompt and submitted with Enter - a transport acknowledgement only; "
                                 "the pane shows what the agent does with it"})

    def answer(self, body):
        """POST /answer {"option": N, "key": K}: the menu the pane shows, named by K, is answered with the one key "N" -
        and Enter only if the menu is still up afterwards with option N highlighted (a menu that takes the number as
        the answer gets no Enter, which could land in whatever comes next). Nothing else is typed."""
        n, key = body.get("option"), body.get("key")
        if not isinstance(n, int) or isinstance(n, bool) or not 1 <= n <= 99 or not isinstance(key, str):
            return self._json(400, {"answered": False, "error": 'the body must be JSON: {"option": N, "key": "..."} with N the option number'})
        with SEND_LOCK:
            ok, pane_id, command, reason = writable()
            if not ok:
                return self._json(409, {"answered": False, "error": reason})
            screen, menu, error = look()
            if error:
                return self._json(503, {"answered": False, "error": "the pane could not be read: " + error})
            if screen != "menu" or menu["kind"] != "numbered":
                what = hold_reason(command, screen, menu) or "the pane shows the agent's prompt, not a menu"
                return self._json(409, {"answered": False, "error": "no numbered menu to answer: " + what, "screen": screen, "menu": menu})
            if menu["key"] != key:
                return self._json(409, {"answered": False, "screen": screen, "menu": menu,
                                        "error": f"the menu changed since the page showed it (it now asks {menu['question']!r}) - look again"})
            texts = {o["n"]: o["text"] for o in menu["options"]}
            if n not in texts:
                return self._json(400, {"answered": False, "error": f"option {n} is not one of the menu's 1..{len(texts)}"})
            r = tmux("send-keys", "-t", pane_id, "-l", "--", str(n))
            if r.returncode != 0:
                return self._json(502, {"answered": False, "error": "tmux did not accept the key: " + r.stderr.strip()})
            how, outcome = f"the key {n}", self.settle(key, n)
            if outcome == "selected":
                r = tmux("send-keys", "-t", pane_id, "Enter")
                if r.returncode != 0:
                    return self._json(502, {"answered": False, "error": f"the key {n} was pressed but tmux did not accept the Enter: " + r.stderr.strip()})
                how, outcome = how + ", then Enter", self.settle(key, n)
            elif outcome == "unmoved":
                return self._json(409, {"answered": False, "error": f"the menu did not take the key {n} (its cursor is not on option {n}) - or an identical "
                                                                      "menu followed it; look at the screen and answer again, or in the browser terminal"})
        self._json(200, {"answered": True, "option": n, "text": texts[n], "how": how, "menu_gone": outcome == "gone",
                         "session": SESSION, "pane": pane_id, "at": time.strftime("%H:%M:%S UTC", time.gmtime()),
                         "note": "the key was pressed in the session - a transport acknowledgement only; the pane shows what the agent does with it"})

    @staticmethod
    def settle(key, n):
        """After a key: "gone" - the menu named by key is no longer shown; "selected" - it is, with option n highlighted;
        "unmoved" - it is, with another option highlighted, after ANSWER_WAIT seconds."""
        deadline = time.monotonic() + ANSWER_WAIT
        while True:
            screen, menu, error = look()
            if error or screen != "menu" or menu["key"] != key:
                return "gone"
            if menu["selected"] == n:
                return "selected"
            if time.monotonic() >= deadline:
                return "unmoved"
            time.sleep(0.2)


if __name__ == "__main__":
    # loopback only: the home proxy (chat.localhost) is the one way in, as for every UI behind it
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
