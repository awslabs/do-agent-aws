// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0
// The Board page: renders /api/board (the one snapshot the server keeps) into the columns, with textContent only -
// no HTML string ever reaches the document, whatever a card or an attempt is named. Same-origin fetch, no credentials.
(function () {
  'use strict';
  var REFRESH_MS = 30000;
  var state = document.getElementById('state');
  var notice = document.getElementById('notice');
  var columnsEl = document.getElementById('columns');
  var unlinked = document.getElementById('unlinked');
  var subtitle = document.getElementById('subtitle');

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined && text !== null) n.textContent = String(text);
    return n;
  }
  function clear(n) { while (n.firstChild) n.removeChild(n.firstChild); }
  function setState(kind, label) {
    state.className = 'hs-dot ' + kind;
    state.setAttribute('data-state', kind);
    state.textContent = label;
  }
  function when(iso) {
    if (!iso) return '';
    var d = new Date(iso.length === 19 ? iso + 'Z' : iso);
    if (isNaN(d.getTime())) return iso;
    var s = Math.round((Date.now() - d.getTime()) / 1000);
    if (s < 90) return 'just now';
    if (s < 5400) return Math.round(s / 60) + ' min ago';
    if (s < 172800) return Math.round(s / 3600) + ' h ago';
    return Math.round(s / 86400) + ' d ago';
  }

  function attemptNode(a, full) {
    var li = el('li', 'attempt' + (a.running ? ' running' : ''));
    var head = el('div', 'attempt-head');
    head.appendChild(el('span', 'chip ' + (a.running ? 'ok' : (a.worktree_deleted ? 'off' : 'idle')),
      a.running ? 'running' : (a.worktree_deleted ? 'worktree removed' : (a.setup_done ? 'idle' : 'setting up'))));
    if (full && a.name) head.appendChild(el('span', 'attempt-name', a.name));
    if (a.branch) head.appendChild(el('code', 'attempt-branch', a.branch));
    li.appendChild(head);
    var facts = [];
    if (a.sessions !== null && a.sessions !== undefined) facts.push(a.sessions + ' session' + (a.sessions === 1 ? '' : 's'));
    if (a.pinned) facts.push('pinned');
    if (a.updated_at) facts.push('changed ' + when(a.updated_at));
    Object.keys(a.git || {}).forEach(function (k) { facts.push(k + ': ' + a.git[k]); });
    if (facts.length) li.appendChild(el('div', 'attempt-facts hs-muted', facts.join(' | ')));
    return li;
  }

  function cardNode(c) {
    var li = el('li', 'card hs-card');
    var head = el('div', 'card-head');
    head.appendChild(el('span', 'card-key', c.key));
    if (c.priority && c.priority !== 'none') head.appendChild(el('span', 'chip pri-' + c.priority, c.priority));
    if (c.attempts && c.attempts.length) head.appendChild(el('span', 'chip ok', c.attempts.length + ' attempt' + (c.attempts.length === 1 ? '' : 's')));
    li.appendChild(head);
    li.appendChild(el('div', 'card-name', c.name));
    var meta = [];
    if (c.updated_at) meta.push('changed ' + when(c.updated_at));
    if (c.mirrored) meta.push('mirrored from the goals file');
    if (meta.length) li.appendChild(el('div', 'card-meta hs-muted', meta.join(' | ')));
    if (c.attempts && c.attempts.length) {
      var ul = el('ul', 'attempts');
      c.attempts.forEach(function (a) { ul.appendChild(attemptNode(a, false)); });
      li.appendChild(ul);
    }
    return li;
  }

  function render(d) {
    clear(columnsEl);
    if (d.project) subtitle.textContent = 'project ' + d.project.identifier + ' (' + d.project.name + ') of workspace ' + d.workspace + ' - ' + d.cards + ' card' + (d.cards === 1 ? '' : 's');
    (d.columns || []).forEach(function (col) {
      var sec = el('section', 'column' + (col.group ? ' group-' + col.group : ''));
      sec.setAttribute('data-column', col.name);
      var h = el('h2', 'column-title');
      h.appendChild(el('span', 'column-name', col.name));
      h.appendChild(el('span', 'column-count chip', col.cards.length));
      sec.appendChild(h);
      var ul = el('ul', 'cards');
      if (!col.cards.length) ul.appendChild(el('li', 'hs-empty', 'no cards'));
      col.cards.forEach(function (c) { ul.appendChild(cardNode(c)); });
      sec.appendChild(ul);
      columnsEl.appendChild(sec);
    });
    var list = unlinked.querySelector('ul');
    clear(list);
    var extra = d.unlinked_attempts || [];
    unlinked.hidden = !extra.length;
    extra.forEach(function (a) { list.appendChild(attemptNode(a, true)); });
    var r = d.runner || {};
    var parts = [];
    if (d.stale) parts.push('Plane is not answering: ' + (d.error || 'no reason given') + '. This is the last good view, from ' + when(d.generated_at) + '.');
    if (r.error) parts.push('The agent runner is not answering (' + r.error + '); the cards show no attempts.');
    notice.textContent = parts.join(' ');
    notice.hidden = !parts.length;
    setState(d.stale ? 'bad' : (r.error ? 'stale' : 'ok'), d.stale ? 'stale' : (r.error ? 'runner down' : 'live'));
  }

  function load() {
    fetch('/api/board', { cache: 'no-store', credentials: 'omit', redirect: 'manual' }).then(function (res) {
      if (res.status !== 200) {
        return res.json().then(function (d) {
          notice.textContent = 'No board yet: ' + (d && d.error ? d.error : 'HTTP ' + res.status);
          notice.hidden = false;
          setState('bad', 'down');
        }, function () {
          notice.textContent = 'No board yet: HTTP ' + res.status;
          notice.hidden = false;
          setState('bad', 'down');
        });
      }
      return res.json().then(function (d) {
        if (d.refresh_s) {
          REFRESH_MS = Math.max(5, d.refresh_s) * 1000;
          document.getElementById('refresh').textContent = String(Math.round(REFRESH_MS / 1000));
        }
        render(d);
      });
    }).catch(function () {
      notice.textContent = 'The board server is not answering.';
      notice.hidden = false;
      setState('bad', 'down');
    }).then(function () { window.setTimeout(load, REFRESH_MS); });
  }
  load();
})();
