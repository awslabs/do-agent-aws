// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0
// The Files page: lists /api/list for the folder named in the location hash (#/sub/folder), downloads through
// /api/download (an attachment, never shown), uploads with PUT /api/upload (the File object is the body, one file at a
// time, progress from the upload's own events), makes folders with POST /api/mkdir, and renames, moves and deletes with
// POST /api/move and POST /api/delete - a delete after a confirm that names the entry, a non-empty folder after a second
// one that names how many entries it holds, a replace after a confirm too. A move is a drag of a row onto a folder row,
// the parent row or a breadcrumb, or the "Move to..." picker (a folder browser fed by /api/list) for a keyboard. Every
// node is built with createElement and textContent - no HTML string ever reaches the document, whatever a file is
// named. Same-origin requests only, no credentials.
(function () {
  'use strict';
  var state = document.getElementById('state');
  var notice = document.getElementById('notice');
  var crumbs = document.getElementById('crumbs');
  var tbody = document.querySelector('#list tbody');
  var caption = document.getElementById('caption');
  var queue = document.getElementById('queue');
  var count = document.getElementById('count');
  var drop = document.getElementById('drop');
  var picker = document.getElementById('picker');
  var mover = document.getElementById('mover');
  var moverWhat = document.getElementById('mover-what');
  var moverPath = document.getElementById('mover-path');
  var moverList = document.getElementById('mover-list');
  var moverUp = document.getElementById('mover-up');
  var moverOpen = document.getElementById('mover-open');
  var DRAG_TYPE = 'application/x-do-agent-aws-files';
  var capBytes = null;
  var current = '';
  var uploading = false;
  var pending = [];
  var moving = null;   // the entry the picker is open for: { path, name, type }
  var pendingNotice = null;   // a notice to show after the next render (a folder that is gone: the top level is loaded instead)
  var browsing = '';   // the folder the picker shows

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined && text !== null) n.textContent = String(text);
    return n;
  }
  function button(label, fn, cls) {
    var b = el('button', 'act' + (cls ? ' ' + cls : ''), label);
    b.type = 'button';
    b.addEventListener('click', fn);
    return b;
  }
  function clear(n) { while (n.firstChild) n.removeChild(n.firstChild); }
  function setState(kind, label) {
    state.className = 'hs-dot ' + kind;
    state.setAttribute('data-state', kind);
    state.textContent = label;
  }
  function say(text, kind) {
    notice.textContent = text || '';
    notice.className = 'hs-error' + (kind ? ' ' + kind : '');
    notice.hidden = !text;
  }
  function human(n) {
    if (n === null || n === undefined) return '';
    if (n < 1024) return n + ' B';
    var units = ['KiB', 'MiB', 'GiB', 'TiB'];
    var v = n, i = -1;
    while (v >= 1024 && i < units.length - 1) { v = v / 1024; i += 1; }
    return (v >= 100 ? Math.round(v) : v.toFixed(1)) + ' ' + units[i];
  }
  function when(iso) {
    if (!iso) return '';
    var d = new Date(iso);
    if (isNaN(d.getTime())) return iso;
    var s = Math.round((Date.now() - d.getTime()) / 1000);
    if (s < 90) return 'just now';
    if (s < 5400) return Math.round(s / 60) + ' min ago';
    if (s < 172800) return Math.round(s / 3600) + ' h ago';
    return d.toISOString().slice(0, 10);
  }
  function pathFromHash() {
    var h = decodeURIComponent((location.hash || '').replace(/^#\/?/, ''));
    return h.split('/').filter(function (p) { return p && p !== '.' && p !== '..'; }).join('/');
  }
  function hashFor(path) { return '#/' + path.split('/').filter(Boolean).map(encodeURIComponent).join('/'); }
  function join(path, name) { return path ? path + '/' + name : name; }
  function splitPath(full) {
    var i = full.lastIndexOf('/');
    return i < 0 ? { dir: '', name: full } : { dir: full.slice(0, i), name: full.slice(i + 1) };
  }
  function where(folder) { return folder ? folder + '/' : 'the top level'; }
  function qs(params) {
    return Object.keys(params).map(function (k) { return encodeURIComponent(k) + '=' + encodeURIComponent(params[k]); }).join('&');
  }
  // one POST to the server; done(status, the JSON body when there is one, the text) - status 0 = no answer at all
  function post(url, done) {
    fetch(url, { method: 'POST', cache: 'no-store', credentials: 'omit', redirect: 'manual' }).then(function (res) {
      return res.text().then(function (t) {
        var body = null;
        try { body = JSON.parse(t); } catch (e) { body = null; }
        done(res.status, body, (t || '').trim());
      });
    }).catch(function () { done(0, null, 'the files server is not answering'); });
  }
  function failed(verb, status, text) { say(verb + ': ' + (status ? 'HTTP ' + status + ' ' + text : text)); }

  // --- a dragged row: a folder row, the parent row and every breadcrumb take it and move the entry there ---
  function dragged(e) {
    var types = e.dataTransfer && e.dataTransfer.types;
    return !!types && Array.prototype.indexOf.call(types, DRAG_TYPE) >= 0;
  }
  function draggable(tr, full, entry) {
    tr.draggable = true;
    tr.addEventListener('dragstart', function (e) {
      e.dataTransfer.setData(DRAG_TYPE, JSON.stringify({ path: full, name: entry.name, type: entry.type }));
      e.dataTransfer.effectAllowed = 'move';
      tr.classList.add('dragging');
    });
    tr.addEventListener('dragend', function () { tr.classList.remove('dragging'); });
  }
  function dropTarget(node, dest) {
    node.addEventListener('dragover', function (e) {
      if (!dragged(e)) return;
      e.preventDefault();
      e.stopPropagation();
      e.dataTransfer.dropEffect = 'move';
      node.classList.add('target');
    });
    node.addEventListener('dragleave', function () { node.classList.remove('target'); });
    node.addEventListener('drop', function (e) {
      node.classList.remove('target');
      if (!dragged(e)) return;
      e.preventDefault();
      e.stopPropagation();
      var item = null;
      try { item = JSON.parse(e.dataTransfer.getData(DRAG_TYPE)); } catch (err) { item = null; }
      if (item && typeof item.path === 'string' && typeof item.name === 'string') moveTo(item.path, item.type, item.name, dest, null);
    });
  }

  function crumbNodes(path) {
    clear(crumbs);
    var home = el('a', 'crumb', 'files');
    home.href = '#/';
    dropTarget(home, '');
    crumbs.appendChild(home);
    var parts = path ? path.split('/') : [];
    var acc = '';
    parts.forEach(function (p) {
      acc = join(acc, p);
      crumbs.appendChild(el('span', 'sep', '/'));
      var a = el('a', 'crumb', p);
      a.href = hashFor(acc);
      dropTarget(a, acc);
      crumbs.appendChild(a);
    });
  }

  function cell(tr, label, node) {
    var td = el('td');
    td.setAttribute('data-label', label);
    if (typeof node === 'string') td.textContent = node; else if (node) td.appendChild(node);
    tr.appendChild(td);
    return td;
  }

  // --- the actions of one entry ---
  function rename(entry, path) {
    var name = window.prompt('New name for "' + entry.name + '"', entry.name);
    if (name === null) return;
    name = name.trim();
    if (!name || name === entry.name) return;
    post('/api/move?' + qs({ path: path, name: entry.name, newname: name }), function (status, body, text) {
      if (status === 200) { say(''); load(); return; }
      failed('Not renamed', status, text);
    });
  }
  function remove(entry, path) {
    var what = entry.link ? 'the link "' + entry.name + '" (what it points at stays)'
      : (entry.type === 'dir' ? 'the folder "' + entry.name + '"' : '"' + entry.name + '"');
    if (!window.confirm('Delete ' + what + '?')) return;
    post('/api/delete?' + qs({ path: path, name: entry.name }), function (status, body, text) {
      if (status === 200) { say(''); load(); return; }
      if (status === 409 && body && typeof body.entries === 'number') {
        var n = body.entries;
        if (!window.confirm('The folder "' + entry.name + '" holds ' + n + (n === 1 ? ' entry' : ' entries') + '. Delete the folder and everything in it?')) return;
        post('/api/delete?' + qs({ path: path, name: entry.name, recursive: '1' }), function (s2, b2, t2) {
          if (s2 === 200) { say(''); load(); return; }
          failed('Not deleted', s2, t2);
        });
        return;
      }
      failed('Not deleted', status, text);
    });
  }
  // full = the entry's path, dest = the destination folder; done runs after a move that went through
  function moveTo(full, type, name, dest, done) {
    var src = splitPath(full);
    if (src.dir === dest) { say('"' + name + '" is already in ' + where(dest) + '.'); return; }
    if (type === 'dir' && (dest === full || dest.indexOf(full + '/') === 0)) { say('A folder cannot move into itself.'); return; }
    post('/api/move?' + qs({ path: src.dir, name: name, to: dest }), function (status, body, text) {
      if (status === 200) { say(''); if (done) done(); load(); return; }
      if (status === 409 && type !== 'dir' && /replace=1/.test(text) && window.confirm('"' + name + '" is already in ' + where(dest) + '. Replace it?')) {
        post('/api/move?' + qs({ path: src.dir, name: name, to: dest, replace: '1' }), function (s2, b2, t2) {
          if (s2 === 200) { say(''); if (done) done(); load(); return; }
          failed('Not moved', s2, t2);
        });
        return;
      }
      failed('Not moved', status, text);
    });
  }

  // --- the "Move to..." picker: a folder browser over /api/list; Open goes into the selected folder, Up to the parent,
  //     Move here moves the entry into the folder shown ---
  function openMover(entry, path) {
    moving = { path: join(path, entry.name), name: entry.name, type: entry.type };
    moverWhat.textContent = 'Move ' + (entry.type === 'dir' ? 'the folder ' : '') + '"' + entry.name + '" to the folder shown, then Move here:';
    mover.hidden = false;
    browse(path);
  }
  function closeMover() { moving = null; mover.hidden = true; clear(moverList); }
  function browse(folder) {
    fetch('/api/list?path=' + encodeURIComponent(folder), { cache: 'no-store', credentials: 'omit', redirect: 'manual' }).then(function (res) {
      if (res.status !== 200) { say('The picker could not list ' + where(folder) + ': HTTP ' + res.status); return; }
      return res.json().then(function (d) {
        browsing = d.path || '';
        moverPath.textContent = browsing ? browsing + '/' : '/ (the top level)';
        clear(moverList);
        d.entries.forEach(function (e) {
          if (e.type !== 'dir') return;
          var full = join(browsing, e.name);
          if (moving && moving.type === 'dir' && (full === moving.path || full.indexOf(moving.path + '/') === 0)) return;
          var opt = document.createElement('option');
          opt.value = e.name;
          opt.textContent = e.name + '/';
          moverList.appendChild(opt);
        });
        moverUp.disabled = !browsing;
        moverOpen.disabled = !moverList.options.length;
        if (moverList.options.length) moverList.selectedIndex = 0;
      });
    }).catch(function () { say('The files server is not answering.'); });
  }
  moverUp.addEventListener('click', function () { browse(splitPath(browsing).dir); });
  moverOpen.addEventListener('click', function () { if (moverList.value) browse(join(browsing, moverList.value)); });
  moverList.addEventListener('dblclick', function () { if (moverList.value) browse(join(browsing, moverList.value)); });
  document.getElementById('mover-go').addEventListener('click', function () {
    if (!moving) return;
    var m = moving;
    moveTo(m.path, m.type, m.name, browsing, closeMover);
  });
  document.getElementById('mover-cancel').addEventListener('click', closeMover);

  function rowFor(entry, path) {
    var tr = el('tr', 'entry ' + entry.type);
    var full = join(path, entry.name);
    var name;
    if (entry.served === false) {
      // the server lists it under a name it can show but will not serve (a separator, a control character, bytes that
      // are not UTF-8): no link, no action, and no encodeURIComponent on it
      name = el('span', 'name', entry.name);
      name.appendChild(el('span', 'chip', 'not served: a name the shared folder cannot take (rename it in the container)'));
      cell(tr, 'Name', name);
      cell(tr, 'Size', entry.type === 'file' ? human(entry.size) : (entry.type === 'dir' ? 'folder' : ''));
      cell(tr, 'Modified', when(entry.mtime));
      cell(tr, 'Actions', '');
      return tr;
    }
    if (entry.type === 'dir') {
      name = el('a', 'name folder', entry.name + '/');
      name.href = hashFor(full);
    } else {
      name = el('span', 'name', entry.name);
    }
    if (entry.link) name.appendChild(el('span', 'chip', entry.type === 'outside' ? 'link outside the folder' : 'link'));
    cell(tr, 'Name', name);
    cell(tr, 'Size', entry.type === 'file' ? human(entry.size) : (entry.type === 'dir' ? 'folder' : ''));
    cell(tr, 'Modified', when(entry.mtime));
    var actions = el('span', 'actions');
    if (entry.type === 'file') {
      var a = el('a', 'download', 'Download');
      a.href = '/api/download?path=' + encodeURIComponent(full);
      a.setAttribute('download', entry.name);
      actions.appendChild(a);
    } else if (entry.type === 'outside') {
      actions.appendChild(el('span', 'hs-muted', 'not served: it points outside the shared folder'));
    }
    actions.appendChild(button('Rename', function () { rename(entry, path); }));
    actions.appendChild(button('Move to...', function () { openMover(entry, path); }));
    actions.appendChild(button('Delete', function () { remove(entry, path); }, 'danger'));
    cell(tr, 'Actions', actions);
    draggable(tr, full, entry);
    if (entry.type === 'dir') dropTarget(tr, full);
    return tr;
  }

  function render(d) {
    current = d.path || '';
    capBytes = d.max_upload_bytes || null;
    document.getElementById('root').textContent = d.root || '';
    document.getElementById('cap').textContent = d.max_upload_mb ? d.max_upload_mb + ' MiB' : '-';
    crumbNodes(current);
    caption.textContent = (current ? current + '/' : "the folder's top level") + ' - ' + d.entries.length + (d.entries.length === 1 ? ' entry' : ' entries');
    clear(tbody);
    if (current) {
      var up = el('tr', 'entry up');
      var upLink = el('a', 'name folder', '..');
      upLink.href = hashFor(d.parent || '');
      cell(up, 'Name', upLink);
      cell(up, 'Size', 'parent folder');
      cell(up, 'Modified', '');
      cell(up, 'Actions', el('span', 'hs-muted', 'drop a row here to move it up'));
      dropTarget(up, d.parent || '');
      tbody.appendChild(up);
    }
    if (!d.entries.length) {
      var empty = el('tr', 'entry empty');
      var td = el('td', 'hs-empty', 'nothing here yet - upload a file, or ask the agent to save its work under ' + (d.root || '/wd/files'));
      td.setAttribute('colspan', '4');
      empty.appendChild(td);
      tbody.appendChild(empty);
    }
    d.entries.forEach(function (e) {
      // one entry the page cannot render never takes the folder down with it
      try { tbody.appendChild(rowFor(e, current)); } catch (err) {
        var odd = el('tr', 'entry other');
        var oddTd = el('td', 'hs-muted', 'an entry this page cannot show (' + (err && err.name ? err.name : 'error') + ') - see it in the container');
        oddTd.setAttribute('colspan', '4');
        odd.appendChild(oddTd);
        tbody.appendChild(odd);
      }
    });
    setState('ok', 'live');
  }

  function load() {
    var path = pathFromHash();
    fetch('/api/list?path=' + encodeURIComponent(path), { cache: 'no-store', credentials: 'omit', redirect: 'manual' }).then(function (res) {
      if (res.status === 404 && path) {
        pendingNotice = 'No folder "' + path + '" - showing the top level.';
        location.hash = '#/';
        return;
      }
      if (res.status !== 200) {
        return res.text().then(function (t) {
          say('The shared folder did not answer the listing: HTTP ' + res.status + ' ' + (t || '').trim());
          setState('bad', 'down');
        });
      }
      return res.json().then(function (d) { render(d); say(pendingNotice || ''); pendingNotice = null; });
    }).catch(function () {
      say('The files server is not answering.');
      setState('bad', 'down');
    });
  }

  // --- uploads: a queue, one file at a time, each with its own progress line ---
  function queueLine(file) {
    var li = el('li', 'job');
    li.appendChild(el('span', 'job-name', file.name));
    li.appendChild(el('span', 'job-size hs-muted', human(file.size)));
    var bar = document.createElement('progress');
    bar.max = 100;
    bar.value = 0;
    li.appendChild(bar);
    li.appendChild(el('span', 'job-state', 'waiting'));
    queue.appendChild(li);
    return { li: li, bar: bar, state: li.lastChild };
  }
  function finish(job, cls, text) {
    job.li.className = 'job ' + cls;
    job.state.textContent = text;
    job.bar.value = cls === 'done' ? 100 : job.bar.value;
  }
  function send(file, folder, job, replace, done) {
    var xhr = new XMLHttpRequest();
    var url = '/api/upload?path=' + encodeURIComponent(folder) + '&name=' + encodeURIComponent(file.name) + (replace ? '&replace=1' : '');
    xhr.open('PUT', url, true);
    xhr.upload.onprogress = function (ev) {
      if (ev.lengthComputable) { job.bar.value = Math.round(ev.loaded * 100 / ev.total); job.state.textContent = job.bar.value + '%'; }
    };
    xhr.onload = function () {
      if (xhr.status === 200 || xhr.status === 201) {
        finish(job, 'done', xhr.status === 200 ? 'replaced' : 'uploaded');
        done(true);
      } else if (xhr.status === 409 && !replace && /replace=1/.test(xhr.responseText || '')) {
        if (window.confirm('"' + file.name + '" is already in this folder. Replace it?')) {
          job.state.textContent = 'replacing';
          send(file, folder, job, true, done);
        } else {
          finish(job, 'skipped', 'kept the existing file');
          done(false);
        }
      } else {
        finish(job, 'failed', 'HTTP ' + xhr.status + ' ' + (xhr.responseText || '').trim());
        done(false);
      }
    };
    xhr.onerror = function () { finish(job, 'failed', 'the upload did not reach the server (network error)'); done(false); };
    xhr.onabort = function () { finish(job, 'failed', 'aborted'); done(false); };
    job.state.textContent = '0%';
    xhr.send(file);
  }
  function next() {
    if (uploading) return;
    var item = pending.shift();
    if (!item) { count.textContent = ''; load(); return; }
    count.textContent = pending.length ? pending.length + ' more waiting' : '';
    uploading = true;
    send(item.file, item.folder, item.job, false, function () { uploading = false; next(); });
  }
  function enqueue(files) {
    var folder = current;
    Array.prototype.forEach.call(files, function (file) {
      var job = queueLine(file);
      if (capBytes !== null && file.size > capBytes) {
        finish(job, 'failed', 'too large: the cap is ' + human(capBytes) + ' (FILES_MAX_UPLOAD_MB)');
        return;
      }
      pending.push({ file: file, folder: folder, job: job });
    });
    next();
  }

  document.getElementById('refresh').addEventListener('click', load);
  document.getElementById('pick').addEventListener('click', function () { picker.click(); });
  picker.addEventListener('change', function () { enqueue(picker.files); picker.value = ''; });
  document.getElementById('newfolder').addEventListener('click', function () {
    var name = window.prompt('Name of the new folder (inside ' + where(current) + ')');
    if (name === null) return;
    name = name.trim();
    if (!name) return;
    post('/api/mkdir?' + qs({ path: current, name: name }), function (status, body, text) {
      if (status === 201) { say(''); load(); return; }
      failed('The folder was not made', status, text);
    });
  });
  // files from the desktop: the upload zone highlights while they hover it, and a drop ANYWHERE on the page uploads them
  // into this folder - the window takes every file drag, so a drop on the table or a row never makes the browser leave the
  // page (a dragged row is not a file: it is left to the folder rows and breadcrumbs above)
  ['dragenter', 'dragover'].forEach(function (ev) {
    drop.addEventListener(ev, function (e) { if (dragged(e)) return; e.preventDefault(); drop.classList.add('over'); });
  });
  drop.addEventListener('dragleave', function (e) { if (dragged(e)) return; e.preventDefault(); drop.classList.remove('over'); });
  window.addEventListener('dragover', function (e) { if (dragged(e)) return; e.preventDefault(); });
  window.addEventListener('drop', function (e) {
    if (dragged(e)) return;
    e.preventDefault();
    drop.classList.remove('over');
    if (e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files.length) enqueue(e.dataTransfer.files);
  });
  window.addEventListener('hashchange', load);
  load();
})();
