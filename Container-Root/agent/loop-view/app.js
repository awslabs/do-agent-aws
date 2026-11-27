// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0
// The Agent loop page: reads data.json (written by /agent/loop-view.py) every few seconds and draws it. Every piece of
// text from the data goes into the page through textContent or a text node - never as markup - and nothing here
// writes anywhere: the only actions are commands to copy. A refresh redraws a section only when its data changed, and
// keeps the keyboard focus and any open details on the element with the same data-key.
'use strict';
(function () {
  var REFRESH_MS = 5000;
  var skew = 0; // server clock minus this browser's, from the Date header (ages stay right on a skewed laptop)
  var drawn = {}; // section id -> the JSON it was last drawn from

  function el(tag, attrs, kids) {
    var n = document.createElement(tag);
    Object.keys(attrs || {}).forEach(function (k) {
      var v = attrs[k];
      if (v === null || v === undefined || v === false) return;
      if (k === 'text') n.textContent = String(v);
      else if (k === 'cls') n.className = v;
      else n.setAttribute(k, String(v));
    });
    (kids || []).forEach(function (c) {
      if (c !== null && c !== undefined) n.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
    });
    return n;
  }
  // replace(n, kids): the focus inside n and every <details> open in it move to the new element with the same data-key
  function replace(n, kids) {
    var a = document.activeElement, focusKey = a && a !== n && n.contains(a) ? a.getAttribute('data-key') : null;
    var open = {};
    Array.prototype.forEach.call(n.querySelectorAll('details[data-key]'), function (d) {
      if (d.open) open[d.getAttribute('data-key')] = true;
    });
    while (n.firstChild) n.removeChild(n.firstChild);
    (kids || []).forEach(function (c) { if (c) n.appendChild(typeof c === 'string' ? document.createTextNode(c) : c); });
    Array.prototype.forEach.call(n.querySelectorAll('[data-key]'), function (x) {
      var k = x.getAttribute('data-key');
      if (x.tagName === 'DETAILS' && open[k]) x.open = true;
      if (focusKey !== null && k === focusKey) { x.focus({ preventScroll: true }); focusKey = null; }
    });
    return n;
  }
  function fill(id, kids) {
    var n = document.getElementById(id);
    return n ? replace(n, kids) : null;
  }
  // unchanged(id, data): true when section id was last drawn from the same data (then it is left as it is)
  function unchanged(id, data) {
    var k = JSON.stringify(data);
    if (drawn[id] === k) return true;
    drawn[id] = k;
    return false;
  }
  function now() { return (Date.now() + skew) / 1000; }
  function epoch(iso) { var t = Date.parse(iso || ''); return isNaN(t) ? null : t / 1000; }
  function ago(iso) { var t = epoch(iso); return t === null ? '-' : human(now() - t) + ' ago'; }
  function human(s) {
    s = Math.max(0, Math.round(s));
    if (s < 120) return s + ' s';
    if (s < 7200) return Math.round(s / 60) + ' min';
    return (s / 3600).toFixed(1) + ' h';
  }
  function utc(iso) { return iso ? String(iso).replace('T', ' ').replace(/Z$/, 'Z') : '-'; }
  function nowUtc() { return utc(new Date(now() * 1000).toISOString().replace(/\.\d+Z$/, 'Z')); }
  var TONE = {
    running: 'good', stopped: 'off', stale: 'warn', 'not started': 'none',
    GREEN: 'good', STALE: 'warn', RED: 'bad', COMPLETE: 'good', STOPPED: 'off',
    ok: 'good', failed: 'bad', timeout: 'bad', interrupted: 'warn',
    attached: 'good', detached: 'off', done: 'good', 'no result': 'warn',
    up: 'good', down: 'bad', off: 'off', unhealthy: 'warn',
    unchanged: 'off', refused: 'warn', answering: 'run', unknown: 'warn'
  };
  var WORD = { timeout: 'timed out', running: 'running' };
  function pill(state, label) {
    var tone = state === 'running' ? 'run' : (TONE[state] || 'none');
    return el('span', { cls: 'pill ' + tone, text: label !== undefined ? label : (WORD[state] || state || 'unknown') });
  }
  function hubPill(state) { return el('span', { cls: 'pill ' + (TONE[state] || 'none'), text: state || 'unknown' }); }
  function ended(f) {
    return f.status === 'ok' ? 'ok' : f.status === 'timeout' ? 'timed out' : String(f.status);
  }
  function firePill(f) {
    var word = f.status === 'running' ? 'running' : ended(f);
    if (f.rc !== null && f.rc !== undefined) word += ' (rc ' + f.rc + ')';
    return el('span', { cls: 'pill ' + (f.status === 'running' ? 'run' : (TONE[f.status] || 'none')), text: word });
  }

  // ---------------------------------------------------------------- overview
  function stat(k, v, d) {
    return el('li', {}, [el('div', { cls: 'k', text: k }), el('div', { cls: 'v' }, [v]), el('div', { cls: 'd', text: d || '' })]);
  }
  // the first line of the page: what the loop is doing now, or how its work ended
  function headline(D) {
    var h = D.hub, g = D.goals, last = D.fires.filter(function (f) { return f.end; })[0];
    var lastTxt = last ? 'Last: fire ' + last.n + ' ended ' + ended(last) + ' (rc ' + last.rc + ') at ' + utc(last.end) + '.' : 'No fire has ended yet.';
    if (h.live_fire) {
      var lf = D.fires.filter(function (f) { return f.live; })[0];
      return { word: 'running', label: 'working', text: 'Fire ' + h.live_fire + ' is running' + (lf ? ' for ' +
        human(now() - epoch(lf.begin)) + '; it times out after ' + h.fire_timeout_s + ' s' : '') + '. ' + (last ? lastTxt : '') };
    }
    if (h.health === 'COMPLETE') return { word: 'COMPLETE', text: 'All ' + g.done + ' goal(s) done. ' + lastTxt };
    if (h.state === 'running' && h.phase === 'IDLE') return { word: h.health, text: 'Idle: nothing to fire against yet (no goals file, no Slack message). ' + lastTxt };
    if (h.state === 'running') return { word: h.health, text: 'Waiting for the next fire (one every ' + h.interval_s + ' s). ' + lastTxt };
    return { word: h.health, text: h.health_reason.charAt(0).toUpperCase() + h.health_reason.slice(1) + '. ' + lastTxt };
  }
  function renderOverview(D) {
    var h = D.hub, s = D.stats, g = D.goals;
    var phase = h.state !== 'running' ? (h.state_line || 'no state line yet')
      : h.phase === 'FIRING' ? 'firing fire ' + h.live_fire
        : h.phase === 'SLEEPING' ? 'sleeping between fires' : h.phase === 'IDLE' ? 'idle - nothing to fire against' : String(h.phase);
    var last = D.fires.filter(function (f) { return f.end; })[0];
    var lastFire = (h.live_fire ? 'fire ' + h.live_fire + ' is running now' : '') +
      (last ? (h.live_fire ? '; before it ' : '') + 'fire ' + last.n + ', ' + ended(last) + ' (rc ' + last.rc + ')' : h.live_fire ? '' : 'none yet');
    var rate = s.success_rate_24h === null ? 'no fire in 24 h' : Math.round(s.success_rate_24h * 100) + '% ok (' + s.ok_24h + ' ok, ' + s.failed_24h + ' not)';
    var goals = !g.exists ? 'no goals file yet' : g.mode === 'sections' ? g.done + ' done - goal sections, done is not marked in the file'
      : g.mode === 'none' ? 'no goal lines in the file' : g.done + ' done';
    var head = headline(D);
    fill('headline', [pill(head.word, head.label), ' ', el('span', { text: head.text })]);
    fill('stats', [
      stat('Health', pill(h.health), h.health_reason),
      stat('Last fire', document.createTextNode(h.live_fire ? 'running' : h.last_fire_end ? ago(h.last_fire_end) : 'none'), lastFire),
      stat('Goals', document.createTextNode(g.exists ? g.open + ' open' : '-'), goals)
    ]);
    fill('diag', [
      stat('Loop', hubPill(h.state), phase + (h.stop_flag ? ' - STOP flag present' : '')),
      stat('Fires in 24 h', document.createTextNode(String(s.fires_24h)), rate),
      stat('Interval', document.createTextNode('every ' + h.interval_s + ' s'), 'a fire times out after ' + h.fire_timeout_s + ' s')
    ]);
    var att = D.attention.map(function (a) { return el('li', { cls: a.level === 'amber' ? 'amber' : 'red', text: a.text }); });
    fill('attention', att.length ? att : [el('li', { cls: 'empty', text: 'Nothing needs attention.' })]);
    if (!unchanged('goals', [g, D.notes])) {
      var open = (g.items || []).filter(function (i) { return !i.done; }), done = (g.items || []).filter(function (i) { return i.done; });
      fill('goals', [
        el('p', { cls: 'hint', text: g.exists ? g.file : 'no goals file at ' + g.file + ' - /agent/goals-add.sh creates it' }),
        open.length ? el('ul', { cls: 'goals' }, open.map(function (i) { return el('li', { text: i.text }); })) : null,
        done.length ? el('details', { cls: 'done', 'data-key': 'goals-done' }, [
          el('summary', { 'data-key': 'goals-done-summary', text: g.done + ' done' + (g.done > done.length ? ' (the first ' + done.length + ' listed)' : '') }),
          el('ul', { cls: 'goals' }, done.map(function (i) { return el('li', { cls: 'done', text: i.text }); }))]) : null
      ]);
      var notes = document.getElementById('notes');
      if (notes) notes.textContent = (D.notes || []).length ? D.notes.join('\n') : 'no progress notes yet';
    }
  }

  // ---------------------------------------------------------------- fires
  function renderStrip(D) {
    if (unchanged('strip', D.strip)) return;
    var slots = D.strip.slots, last = slots.length - 1, n = { ok: 0, failed: 0, idle: 0, none: 0 };
    var WORDS = { ok: 'fired, every fire ok', failed: 'a fire failed or timed out', idle: 'ran, nothing fired', none: 'no sign of the loop' };
    var cells = slots.map(function (c, i) {
      n[c.state] += 1;
      var label = utc(c.start) + ': ' + WORDS[c.state] + (c.fires ? ' (' + c.fires + ' fire(s), ' + c.failed + ' failed)' : '');
      return el('span', { cls: 'cell ' + c.state + (i === last ? ' now' : ''), title: label });
    });
    var summary = 'Last 24 h in half hours: ' + n.ok + ' fired ok, ' + n.failed + ' with a failed fire, ' + n.idle + ' ran without a fire, ' + n.none + ' with no sign of the loop';
    fill('strip', [
      el('div', { cls: 'strip', role: 'img', 'aria-label': summary }, cells),
      el('div', { cls: 'legend' }, [
        el('span', {}, [el('i', { cls: 'ok' }), 'fired ok']), el('span', {}, [el('i', { cls: 'failed' }), 'a fire failed']),
        el('span', {}, [el('i', { cls: 'idle' }), 'ran, nothing to fire']), el('span', {}, [el('i', { cls: 'none' }), 'no sign of the loop']),
        el('span', { text: '24 h, oldest left; the outlined cell is now' })
      ])
    ]);
  }
  // a fire's bus inbox (loop.sh "Bus intake"): what it was handed and, from its record, what came of each message
  function inboxIds(a) { return a.length ? a.length + ' (' + a.join(', ') + ')' : 'none'; }
  // the ids set aside after fires that did not end well; the intake's warnings (a failed poll, a refused receipt, a
  // count not written)
  function inboxMore(ib) {
    return (ib.set_aside.length ? '; set aside, handed to fires that did not end well: ' + inboxIds(ib.set_aside) : '')
      + (ib.warnings.length ? '; ' + ib.warnings.join('; ') : '');
  }
  function inboxText(ib, live) {
    if (!ib.note) return (ib.handed.length ? 'handed ' + inboxIds(ib.handed) + (live ? '; the record is written when the fire ends'
      : '; no record: the fire did not reach its end, so these stay open') : 'no message handed') + inboxMore(ib);
    return 'read ' + inboxIds(ib.read) + '; replies sent ' + inboxIds(ib.replies) + '; left without a receipt ' + inboxIds(ib.open) + ' - ' + ib.note + inboxMore(ib);
  }
  function inboxSum(ib, live) {
    var s = ib.note ? ib.read.length + ' read, ' + ib.replies.length + (ib.replies.length === 1 ? ' reply' : ' replies')
      : ib.handed.length ? ib.handed.length + ' handed' + (live ? '' : ', no record') : 'not read';
    if (ib.set_aside.length) s += ', ' + ib.set_aside.length + ' set aside';
    if (ib.warnings.length && (ib.note || ib.handed.length)) s += ', ' + ib.warnings.length + (ib.warnings.length === 1 ? ' warning' : ' warnings');
    return 'bus inbox: ' + s;
  }
  function renderFires(D) {
    var rows = D.fires.map(function (f) {
      var dur = f.duration_s !== null && f.duration_s !== undefined ? human(f.duration_s) : f.live ? human(now() - epoch(f.begin)) + ' so far' : '-';
      var tx = f.transcript ? el('a', { href: 'fire.html?n=' + Number(f.n), 'data-key': 'tx:' + Number(f.n), text: 'fire ' + Number(f.n) + ' transcript' })
        : el('span', { cls: 'sum', text: f.transcript_note || (f.live ? 'written when the fire ends' : 'no transcript') });
      var goals = f.goals_mode === 'default' ? 'default goals (Slack inbox)' : (f.goals || '-');
      return el('tr', { cls: f.live ? 'live' : '' }, [
        el('td', { cls: 'nowrap' }, [el('strong', { text: String(f.n) }), f.once ? ' (once)' : null, f.live ? ' - live' : null]),
        el('td', { cls: 'nowrap', text: utc(f.begin) }),
        el('td', { cls: 'nowrap', text: dur }),
        el('td', {}, [firePill(f), f.why ? el('span', { cls: 'sum', text: f.why }) : null]),
        el('td', {}, [document.createTextNode(goals), f.summary ? el('span', { cls: 'sum', text: f.summary }) : null,
          f.inbox ? el('span', { cls: 'sum', text: inboxSum(f.inbox, f.live) }) : null]),
        el('td', {}, [tx])
      ]);
    });
    if (!rows.length) rows = [el('tr', {}, [el('td', { colspan: 6, text: 'No fire yet: the loop fires once it runs and has goals to fire against.' })])];
    replace(document.querySelector('#fire-table tbody'), rows);
    var wrap = document.querySelector('#fires .tablewrap'), cue = document.getElementById('fires-scroll');
    if (wrap && cue) cue.hidden = !(wrap.scrollWidth > wrap.clientWidth + 1);
  }

  // ---------------------------------------------------------------- fleet
  var KIND = { operator: 'operator', terminal: 'terminal session', loop: 'autonomy loop - the hub', fire: 'fire', subagent: 'sub-agent' };
  function node(n) {
    var head = [el('span', { cls: 'kind', text: KIND[n.kind] || n.kind }), el('span', { cls: 't', text: n.label })];
    if (n.kind === 'loop') head.push(hubPill(n.state), ' ', pill(n.health));
    else if (n.kind === 'fire') head.push(firePill({ status: n.state }), n.live ? ' ' : null, n.live ? el('span', { cls: 'pill run', text: 'live' }) : null);
    else if (n.state) head.push(pill(n.state));
    var bits = [n.detail, n.task ? 'task: ' + n.task : null, n.tmux ? 'in the tmux-agent tree as ' + n.tmux : null].filter(Boolean);
    var box = el('div', { cls: 'node ' + n.kind + (n.live ? ' live' : ''), 'aria-current': n.live ? 'true' : null }, head.concat([
      bits.length ? el('span', { cls: 'd', text: bits.join(' - ') }) : null,
      n.kind === 'fire' && n.fire !== undefined ? el('a', { href: 'fire.html?n=' + Number(n.fire), 'data-key': 'tree-tx:' + Number(n.fire), text: 'transcript' }) : null
    ]));
    var kids = (n.children || []).map(function (c) { return el('li', { role: 'treeitem' }, [node(c)]); });
    var li = el('div', {}, [box]);
    if (kids.length) li.appendChild(el('ul', { role: 'group' }, kids));
    return li;
  }
  function renderFleet(D) {
    var F = D.fleet;
    if (!unchanged('tree', [F.root, F.tmux])) {
      fill('tree', [
        el('ul', { cls: 'tree', role: 'tree', 'aria-label': 'Fleet: operator, terminal sessions, the loop and its fires' }, [el('li', { role: 'treeitem' }, [node(F.root)])]),
        F.tmux.reachable ? null : el('p', { cls: 'hint', text: 'tmux: ' + (F.tmux.error || 'not reachable') + ' - no terminal session to show' })
      ]);
    }
    if (unchanged('services', [F.services, F.services_error])) return;
    // a service's process details (pid, port, HTTP answer) sit behind a disclosure: the label and the state come first
    var rows = (F.services || []).map(function (s) {
      return el('li', {}, [el('span', { cls: 't', text: s.label }), pill(s.state), s.detail ? el('details', { 'data-key': 'svc:' + s.name }, [
        el('summary', { 'data-key': 'svc:' + s.name + ':summary', 'aria-label': 'details: ' + s.label, text: 'details' }),
        el('span', { cls: 'd', text: s.detail })]) : null]);
    });
    fill('services', rows.length ? rows : [el('li', { text: F.services_error || 'probing the services...' })]);
  }

  // ---------------------------------------------------------------- control: Run next fire, Pause loop
  // The two actions POST to the renderer (control/run, control/pause) with the X-Loop-Control header, and the page
  // shows the renderer's answer as it comes: its result word and the loop's state as read back after the action -
  // never what the button meant to do.
  var ACT = { run: 'Run next fire', pause: 'Pause loop' };
  function renderControl(D) {
    var on = !!(D.control && D.control.enabled);
    document.getElementById('controls').hidden = !on;
    document.getElementById('control-off').hidden = on;
  }
  function showAnswer(action, res) {
    var a = res.after, state = a ? 'Read back: the loop is ' + a.state + (a.phase ? ' (' + String(a.phase).toLowerCase() + ')' : '') +
      (a.pid ? ', pid ' + a.pid : '') + '; the STOP flag is ' + (a.stop_flag ? 'set' : 'not set') + '.' : '';
    fill('act-result', [pill(res.result || 'failed'), ' ', el('span', { text: ACT[action] + ': ' + (res.message || 'no answer') }),
      state ? el('span', { cls: 'd', text: state }) : null,
      res.output ? el('details', { 'data-key': 'act-output' }, [el('summary', { 'data-key': 'act-output-summary', text: 'what ' + res.script + ' printed' }),
        el('pre', { cls: 'notes', text: res.output })]) : null]);
  }
  function act(action) {
    var buttons = document.querySelectorAll('button.act');
    Array.prototype.forEach.call(buttons, function (b) { b.disabled = true; });
    fill('act-result', [el('span', { text: ACT[action] + ': running ' + (action === 'run' ? '/agent/loop-start.sh' : '/agent/loop-stop.sh') + '...' })]);
    fetch('control/' + action, { method: 'POST', cache: 'no-store', redirect: 'manual', headers: { 'X-Loop-Control': '1' } })
      .then(function (r) {
        return r.json().then(function (res) { return res; },
          function () { return { result: 'failed', message: 'HTTP ' + r.status + ', an answer the page cannot read' }; });
      })
      .then(function (res) { showAnswer(action, res); },
        function (e) { showAnswer(action, { result: 'failed', message: 'the request did not complete: ' + (e.message || String(e)) }); })
      .then(function () {
        Array.prototype.forEach.call(buttons, function (b) { b.disabled = false; });
        overview();
      });
  }

  // ---------------------------------------------------------------- commands, footer
  function copyButton(text, code) {
    var b = el('button', { cls: 'copy', type: 'button', 'data-key': 'cmd:' + text, text: 'copy', 'aria-label': 'copy: ' + text });
    b.addEventListener('click', function () {
      var done = function () { b.textContent = 'copied'; setTimeout(function () { b.textContent = 'copy'; }, 1500); };
      var select = function () { var r = document.createRange(); r.selectNodeContents(code); var s = window.getSelection(); s.removeAllRanges(); s.addRange(r); b.textContent = 'selected - press Ctrl+C'; };
      if (navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(text).then(done, select);
      else select();
    });
    return b;
  }
  function renderCommands(D) {
    if (unchanged('cmds', D.commands)) return;
    fill('cmds', D.commands.map(function (c) {
      var code = el('code', { text: c.cmd });
      return el('li', {}, [el('span', { cls: 'l', text: c.label }), code, copyButton(c.cmd, code)]);
    }));
  }
  function renderFooter(D) {
    if (unchanged('footer', [D.renderer.version, D.hub.loop_dir, D.renderer.interval_s])) return;
    fill('footer', [document.createTextNode(D.renderer.version + ' - rendered by /agent/loop-view.py from ' + D.hub.loop_dir +
      ' every ' + D.renderer.interval_s + ' s - the same data: '), el('a', { href: 'data.json', text: 'data.json' })]);
  }
  function caption(cls, text) {
    var p = document.getElementById('freshness');
    if (p) { p.className = 'freshness' + (cls ? ' ' + cls : ''); p.textContent = text; }
  }
  // the overview polls: its caption says when the data it shows was written, and that it refreshes
  var lastRead = null;
  function freshness(D, err) {
    if (err) {
      caption('bad', 'cannot read the loop state: ' + err + (lastRead ? ' - showing what was read ' + human(now() - lastRead) + ' ago' : ''));
      return false;
    }
    lastRead = now();
    var age = now() - D.generated_epoch, stale = age > D.renderer.stale_after_s;
    caption(stale ? 'bad' : '', stale ? 'stale: this data is ' + human(age) + ' old - the renderer (loop-view in /agent/ui-status.sh) is not updating it'
      : 'updated ' + human(age) + ' ago - refreshes every ' + REFRESH_MS / 1000 + ' s');
    return !stale;
  }

  // ---------------------------------------------------------------- data, the two views
  function get(url, json) {
    return fetch(url, { cache: 'no-store', redirect: 'manual' }).then(function (r) {
      var d = Date.parse(r.headers.get('Date') || '');
      if (!isNaN(d)) skew = d - Date.now();
      if (r.status !== 200) throw new Error(url + ' answered HTTP ' + r.status);
      return json ? r.json() : r.text();
    });
  }
  function overview() {
    get('data.json', true).then(function (D) {
      if (D.schema !== 'agent-loop-view/v1') throw new Error('data.json is not an agent-loop-view/v1 document');
      freshness(D);
      renderOverview(D); renderControl(D); renderStrip(D); renderFires(D); renderFleet(D); renderCommands(D); renderFooter(D);
      renderLoopDeck(D.loop_deck);
    }).catch(function (e) { freshness(null, e.message || String(e)); });
  }
  function fireMeta(f) {
    var meta = f ? [['result', firePill(f)], ['began (UTC)', utc(f.begin)], ['ended (UTC)', f.live ? 'still running' : utc(f.end)],
      ['duration', f.duration_s !== null && f.duration_s !== undefined ? human(f.duration_s) : f.live ? human(now() - epoch(f.begin)) + ' so far' : '-'],
      ['goals', f.goals_mode === 'default' ? 'default goals (Slack inbox)' : (f.goals || '-')],
      ['bus inbox', f.inbox ? inboxText(f.inbox, f.live) : null],
      ['Claude Code session', f.session || 'not found under the agent\'s sessions'], ['note', f.why || f.transcript_note || null]]
      : [['fire', 'not among the latest fires on the page']];
    fill('fire-meta', [].concat.apply([], meta.filter(function (m) { return m[1]; }).map(function (m) {
      return [el('dt', { text: m[0] }), el('dd', {}, [typeof m[1] === 'string' ? document.createTextNode(m[1]) : m[1]])];
    })));
    var subs = f ? f.subagents.map(function (a) {
      return el('li', {}, [el('strong', { text: a.name || a.type }), ' ', pill(a.done ? 'done' : f.live ? 'running' : 'no result'),
        document.createTextNode(' ' + (a.name ? a.type : '') + (a.description ? (a.name ? ' - ' : '') + a.description : ''))]);
    }) : [];
    fill('fire-subagents', subs.length ? subs : [el('li', { text: 'none recorded in its session' })]);
  }
  // the fire view: a live fire is polled until it ends; an ended fire is a snapshot, and its caption says so
  function fireView() {
    var n = new URLSearchParams(location.search).get('n');
    if (!/^[0-9]{1,9}$/.test(n || '')) { caption('bad', 'no fire number in the address (fire.html?n=<fire>)'); return; }
    n = Number(n);
    document.getElementById('fire-title').textContent = 'Fire ' + n + ' transcript';
    document.title = 'Fire ' + n + ' - Agent loop';
    var raw = 'transcripts/fire-' + n + '.out', live = false, readAt = null, tx = document.getElementById('transcript');
    document.getElementById('raw-link').setAttribute('href', raw);
    function transcript() {
      get(raw, false).then(function (t) { tx.textContent = t.length ? t : '(the transcript is empty)'; })
        .catch(function (e) { tx.textContent = 'no transcript: ' + (e.message || String(e)); });
    }
    function load() {
      get('data.json', true).then(function (D) {
        if (D.schema !== 'agent-loop-view/v1') throw new Error('data.json is not an agent-loop-view/v1 document');
        renderFooter(D);
        var f = D.fires.filter(function (x) { return x.n === n; })[0];
        fireMeta(f);
        readAt = nowUtc();
        live = !!(f && f.live);
        var age = now() - D.generated_epoch;
        if (live) {
          caption(age > D.renderer.stale_after_s ? 'bad' : '', 'live: fire ' + n + ' is running - read at ' + readAt +
            ', refreshes every ' + REFRESH_MS / 1000 + ' s until it ends' + (age > D.renderer.stale_after_s ? '; the loop data is ' + human(age) + ' old' : ''));
          tx.textContent = 'the transcript is written when the fire ends; this page shows it then';
          setTimeout(load, REFRESH_MS);
          return;
        }
        caption('', 'snapshot: ' + (f ? 'fire ' + n + ' ended ' + utc(f.end) : 'fire ' + n) + ' - read at ' + readAt +
          '; this page does not refresh (reload it for newer data)');
        transcript();
      }).catch(function (e) {
        caption('bad', 'cannot read the loop state: ' + (e.message || String(e)) + (readAt ? ' - showing what was read at ' + readAt : ''));
        if (live) setTimeout(load, REFRESH_MS);
        else if (!readAt) transcript();
      });
    }
    load();
  }
  // Loop Deck, every loop of this harness, as the renderer reads it (D.loop_deck): the fleet Deck LOOP_DECK_URL names,
  // or the Deck this harness serves while the home proxy reaches it, on its own host route beside this one - found
  // the way the home badge finds the home page: this host's first label replaced, the port kept (loop.localhost:<port>
  // -> loop-deck.localhost:<port>). Off a *.localhost host the served one has no route here; with neither, no link
  function loopDeckHref(host, deck) {
    if (deck && deck.href) return deck.href;
    if (!deck || !deck.route) return null;
    var m = /^[^.:]+\.((?:[^.:]+\.)*localhost(?::\d+)?)$/.exec(host || '');
    return m ? '//loop-deck.' + m[1] + '/#/loops' : null;
  }
  function renderLoopDeck(deck) {
    var href = loopDeckHref(location.host, deck), a = document.getElementById('loop-deck'),
      line = document.getElementById('loop-deck-line');
    if (!a || !line) return;
    if (href) a.setAttribute('href', href); else a.removeAttribute('href');
    line.hidden = !href;
  }
  // a loop other than the autonomy loop (its registry slug in the address): what its own files say, every 5 s
  function statusView() {
    function load() {
      get('data.json', true).then(function (D) {
        if (D.schema !== 'agent-loop-status/v1') throw new Error('data.json is not an agent-loop-status/v1 document');
        document.getElementById('status-title').textContent = D.slug;
        document.title = D.slug + ' - Agent loop';
        document.getElementById('status-about').textContent = D.about;
        var now = [], p = D.process, r = D.record;
        if (p) {
          var who = p.missing ? 'no ' + p.file : p.pid ? 'pid ' + p.pid + (p.cmd ? ' - ' + p.cmd : '') :
            (p.holders || []).map(function (h) { return 'pid ' + h.pid + ' - ' + h.cmd; }).join('; ') || (p.note || p.file);
          now.push(el('li', {}, [el('div', { cls: 'k', text: 'process' }),
            el('div', { cls: 'v' }, [pill(p.alive ? 'running' : 'stopped', p.alive ? 'running' : 'not running')]),
            el('div', { cls: 'd', text: who })]));
        }
        if (r) {
          var what = r.missing ? 'no ' + r.file + ' yet' : (r.fields && r.fields.length ?
            r.fields.map(function (kv) { return kv[0] + '=' + kv[1]; }).join(', ') : (r.lines || []).join(' / ') || 'empty') + ' - ' + r.file;
          now.push(el('li', {}, [el('div', { cls: 'k', text: 'last record' }),
            el('div', { cls: 'v', text: r.missing ? 'none yet' : utc(r.at) + ' (' + human(r.age_s) + ' ago)' }),
            el('div', { cls: 'd', text: what })]));
        }
        fill('status-now', now);
        document.getElementById('status-fires-section').hidden = !D.fires;
        if (D.fires) {
          var rows = D.fires.map(function (f) {
            var word = f.status === 'ok' ? 'ok' + (f.rc !== null ? ' (rc ' + f.rc + ')' : '') : f.status === 'unknown' ? (f.outcome || 'unknown') : f.status;
            return el('tr', f.status === 'answering' ? { cls: 'live' } : {}, [el('td', { text: String(f.n) }), el('td', { text: utc(f.begin) }),
              el('td', { text: f.duration_s === null ? '-' : f.duration_s + ' s' }), el('td', {}, [pill(f.status, word)]),
              el('td', { text: (f.kind ? f.kind + ': ' : '') + f.text })]);
          });
          if (!rows.length) rows = [el('tr', {}, [el('td', { colspan: 5, text: 'No message answered yet.' })])];
          replace(document.querySelector('#status-fires tbody'), rows);
        }
        document.getElementById('status-log-section').hidden = !(D.log_tail && D.log_tail.length);
        document.getElementById('status-log').textContent = (D.log_tail || []).join('\n');
        freshness(D);
        renderLoopDeck(D.loop_deck);
      }).catch(function (e) { freshness(null, e.message || String(e)); });
    }
    load();
    setInterval(load, REFRESH_MS);
  }
  if (document.body.dataset.view === 'fire') fireView();
  else if (document.body.dataset.view === 'status') statusView();
  else {
    Array.prototype.forEach.call(document.querySelectorAll('button.act'), function (b) {
      b.addEventListener('click', function () { act(b.getAttribute('data-action')); });
    });
    overview(); setInterval(overview, REFRESH_MS);
  }
})();
