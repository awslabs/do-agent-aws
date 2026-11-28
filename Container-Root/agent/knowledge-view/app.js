// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0
// The Knowledge transfer page (/agent/knowledge-transfer.py serve, behind the home proxy at /knowledge/): what the two
// knowledge stores hold, a finder for records by id or title, the export of a selection as one pack file, and the check
// and import of one. Every address is relative to the page, so it works under the proxy's prefix; the three actions send
// the page's own X-Knowledge-Transfer header, which the server requires together with this page's origin. Every piece of
// text from the server goes into the page through textContent or a text node - never as markup.
'use strict';
(function () {
  var checked = null; // the pack file the last successful check was for: Import stays off until it is the chosen one
  var lastUrl = null; // the last export's download link (an object URL), released when the next export replaces it

  function el(tag, attrs, kids) {
    var n = document.createElement(tag);
    Object.keys(attrs || {}).forEach(function (k) {
      var v = attrs[k];
      if (v === null || v === undefined || v === false) return;
      if (k === 'text') n.textContent = String(v);
      else if (k === 'cls') n.className = v;
      else if (k === 'checked') n.checked = !!v;
      else n.setAttribute(k, String(v));
    });
    (kids || []).forEach(function (c) {
      if (c !== null && c !== undefined) n.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
    });
    return n;
  }
  function $(id) { return document.getElementById(id); }
  function store(s) { return s === 'loglearner' ? 'LogLearner' : s === 'hindsight' ? 'Hindsight' : String(s); }
  function n(count, one, many) { return count + ' ' + (count === 1 ? one : many); }
  function fill(node, kids) {
    while (node.firstChild) node.removeChild(node.firstChild);
    kids.forEach(function (c) { node.appendChild(c); });
  }
  // a callout: the state in words first (Refused:, Imported:), the step's colour only on the rule beside it
  function callout(kind, head, text, extra) {
    return el('div', { cls: 'hs-error' + (kind ? ' ' + kind : '') }, [el('strong', { text: head }), ' ' + text].concat(extra || []));
  }
  function row(pick, st, bank, records) {
    return el('tr', {}, [el('td', { 'data-label': 'Export' }, [pick]), el('td', { 'data-label': 'Store', text: st }),
      el('td', { 'data-label': 'Bank', text: bank }), el('td', { 'data-label': 'Records', text: records })]);
  }
  function post(path, body, type) {
    return fetch(path, { method: 'POST', cache: 'no-store', redirect: 'manual', body: body,
      headers: { 'Content-Type': type, 'X-Knowledge-Transfer': '1' } });
  }
  // the answer of an action that is JSON: refused (400, 403, 409, 413), or failed (5xx: a store that failed, 502, or an
  // unexpected error, 500)
  function problem(r) {
    return r.json().catch(function () { return {}; }).then(function (j) {
      return callout('', r.status >= 500 ? 'Failed:' : 'Refused:', j.refused || j.error || ('HTTP ' + r.status));
    });
  }
  function ticked() {
    var banks = Array.prototype.map.call(document.querySelectorAll('input[data-bank]:checked'), function (c) { return c.getAttribute('data-bank'); });
    var stores = [];
    if ($('pick-loglearner') && $('pick-loglearner').checked) stores.push('loglearner');
    if (banks.length) stores.push('hindsight');
    return { stores: stores, banks: banks };
  }

  function draw(s) {
    var ll = s.loglearner || {}, hs = s.hindsight || {}, rows = [], hsLine, seed = s.seed_banks || [];
    rows.push(row(el('input', { type: 'checkbox', id: 'pick-loglearner', checked: true, 'aria-label': 'Export the LogLearner bank' }),
      'LogLearner', 'the rules bank, ' + ll.bank, String(ll.records) + (ll.from_image ? ' (' + ll.from_image + " from this image's own packs)" : '') +
      (ll.unreadable_lines ? ' (and ' + ll.unreadable_lines + ' lines that are not records)' : '')));
    if (!hs.on) {
      rows.push(row(el('span', { text: '-' }), 'Hindsight', 'the memory API is off on this harness (UI_HINDSIGHT=false)', '-'));
      hsLine = 'off';
    } else if (hs.state !== 'up') {
      rows.push(row(el('span', { text: '-' }), 'Hindsight', 'the memory API does not answer: ' + (hs.error || 'no reason given'), '-'));
      hsLine = 'not answering';
    } else if (!(hs.banks || []).length) {
      rows.push(row(el('span', { text: '-' }), 'Hindsight', 'no bank yet', '0'));
      hsLine = 'no bank yet';
    } else {
      var docs = 0;
      hs.banks.forEach(function (b) {
        docs += b.documents || 0;
        rows.push(row(el('input', { type: 'checkbox', 'data-bank': b.id, checked: true, 'aria-label': 'Export the Hindsight bank ' + b.id }),
          'Hindsight', b.id + (b.name && b.name !== b.id ? ' - ' + b.name : '') + (seed.indexOf(b.id) >= 0 ? " (this image's seed bank)" : ''),
          String(b.documents)));
      });
      hsLine = n(docs, 'document', 'documents') + ' in ' + n(hs.banks.length, 'bank', 'banks');
    }
    fill($('stores-rows'), rows);
    $('stores').hidden = false;
    $('stores-state').textContent = 'LogLearner: ' + n(ll.records, 'record', 'records') + '. Hindsight: ' + hsLine + '.';
    $('kept-dir').textContent = s.imported_dir;
    var kept = (s.kept || []).map(function (k) {
      return el('li', { text: k.error ? k.name + ': ' + k.error : k.name + ', version ' + k.version + ', ' + n(k.records, 'record', 'records') + ' (' +
        (k.files || []).map(function (f) { return store(f.store) + ' ' + f.records; }).join(', ') + ')' });
    });
    fill($('kept'), kept.length ? kept : [el('li', { cls: 'hs-muted', text: 'none yet' })]);
  }

  function refresh() {
    return fetch('stores.json', { cache: 'no-store', redirect: 'manual' }).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.json();
    }).then(draw).catch(function (e) { $('stores-state').textContent = 'The stores could not be read: ' + e.message; });
  }

  // the finder: the records of the ticked stores and banks the search matches, each with a box to tick
  function findRecords() {
    var t = ticked(), p = new URLSearchParams(), state = $('found-state');
    if (!t.stores.length) {
      state.hidden = false;
      state.textContent = 'Tick the LogLearner bank, a Hindsight bank or both first.';
      return;
    }
    t.stores.forEach(function (s) { p.append('store', s); });
    t.banks.forEach(function (b) { p.append('bank', b); });
    if ($('q').value.trim()) p.append('q', $('q').value.trim());
    state.hidden = false;
    state.textContent = 'Finding records...';
    fetch('records.json?' + p.toString(), { cache: 'no-store', redirect: 'manual' }).then(function (r) {
      return r.json().then(function (j) {
        if (!r.ok) throw new Error(j.refused || j.error || ('HTTP ' + r.status));
        return j;
      });
    }).then(function (j) {
      var rows = [], counts = [];
      function add(rec, bank, label) {
        var box = el('input', { type: 'checkbox', 'data-record': rec.id, 'data-store': rec.store, 'data-in-bank': bank || '',
          'aria-label': 'Export ' + store(rec.store) + ' record ' + rec.id });
        rows.push(el('tr', {}, [el('td', { 'data-label': 'Export' }, [box]), el('td', { 'data-label': 'Store', text: store(rec.store) }),
          el('td', { 'data-label': 'Bank', text: bank || 'the rules bank' }), el('td', { 'data-label': 'Id', text: rec.id }),
          el('td', { 'data-label': 'Title or day', text: label })]));
      }
      if (j.loglearner) {
        j.loglearner.shown.forEach(function (rec) { add(rec, null, (rec.title || '') + (rec.day ? ' (' + rec.day + ')' : '')); });
        counts.push('LogLearner ' + j.loglearner.shown.length + ' shown of ' + j.loglearner.total);
      }
      if (j.hindsight && j.hindsight.error) counts.push('Hindsight: ' + j.hindsight.error);
      Object.keys((j.hindsight && j.hindsight.banks) || {}).forEach(function (b) {
        var hb = j.hindsight.banks[b];
        hb.shown.forEach(function (rec) { add(rec, b, (rec.day || '') + ((rec.tags || []).length ? ' - ' + rec.tags.join(', ') : '')); });
        counts.push(b + ' ' + hb.shown.length + ' shown of ' + hb.total);
      });
      fill($('found-rows'), rows);
      $('found').hidden = !rows.length;
      $('found-all').checked = false;
      state.textContent = (rows.length ? 'Tick the records the pack should hold. ' : 'No record matches. ') + counts.join('; ') + '.';
    }).catch(function (e) { state.textContent = 'The records could not be found: ' + e.message; });
  }

  function exportPack() {
    var box = $('export-result'), t = ticked(), sel;
    var picked = Array.prototype.map.call(document.querySelectorAll('input[data-record]:checked'), function (c) {
      return { store: c.getAttribute('data-store'), bank: c.getAttribute('data-in-bank') || null, id: c.getAttribute('data-record') };
    });
    if (picked.length) {
      sel = { name: $('name').value.trim(), records: picked };
    } else {
      if (!t.stores.length) return fill(box, [callout('warn', 'Nothing ticked:', 'tick the LogLearner bank, a Hindsight bank or both.')]);
      sel = { name: $('name').value.trim(), stores: t.stores, banks: t.banks, tag: $('tag').value.trim() || null,
        since: $('since').value || null, until: $('until').value || null, search: $('q').value.trim() || null,
        defaults: $('defaults').checked };
    }
    $('export').disabled = true;
    fill(box, [el('p', { text: (picked.length ? 'Exporting ' + n(picked.length, 'ticked record', 'ticked records') : 'Exporting') +
      ' - a Hindsight bank is read through the memory API, which takes a few seconds per bank.' })]);
    post('export', JSON.stringify(sel), 'application/json').then(function (r) {
      if (!r.ok) return problem(r).then(function (c) { fill(box, [c]); });
      var pack = {};
      try { pack = JSON.parse(r.headers.get('X-Knowledge-Pack') || '{}'); } catch (e) { pack = {}; }
      return r.blob().then(function (blob) {
        var file = pack.name + '-' + pack.version + '.tar.gz';
        if (lastUrl) URL.revokeObjectURL(lastUrl);
        lastUrl = URL.createObjectURL(blob);
        var a = el('a', { href: lastUrl, download: file, text: file });
        var lines = (pack.files || []).map(function (f) {
          return el('li', { text: f.path + ': ' + store(f.store) + ', ' + n(f.records, 'record', 'records') + ', sha256 ' + f.sha256 });
        });
        var sc = pack.scrub || {}, rep = Object.keys(sc.replacements || {});
        lines.push(el('li', { text: 'the scrub gate found no possible secret (' + (sc.gate === 'config' ? 'the scrub config' :
          'the runtime secret detectors, ' + sc.classes + ' classes') + '); ' + (rep.length ? 'it replaced ' +
          rep.map(function (c) { return c + ' x' + sc.replacements[c]; }).join(', ') : 'it replaced nothing') }));
        var left = pack.left_out_defaults || {}, lk = Object.keys(left);
        if (lk.length) {
          lines.push(el('li', { text: "left out this image's own default knowledge, which every harness of the image already has: " +
            lk.map(function (k) { return store(k) + ' ' + left[k]; }).join(', ') + " (tick Include this image's default knowledge to put it in)" }));
        }
        fill(box, [callout('ok', 'Exported:', n(pack.records, 'record', 'records') + ' in ', [a, '.']), el('ul', {}, lines)]);
        a.click();
      });
    }).catch(function (e) { fill(box, [callout('', 'Failed:', e.message)]); }).then(function () { $('export').disabled = false; });
  }

  function previewPack() {
    var box = $('import-result'), file = $('pack').files[0];
    checked = null;
    $('import').disabled = true;
    if (!file) return fill(box, [callout('warn', 'No file:', 'choose a pack file first.')]);
    $('preview').disabled = true;
    fill(box, [el('p', { text: 'Checking ' + file.name + '...' })]);
    post('preview', file, 'application/gzip').then(function (r) {
      if (!r.ok) return problem(r).then(function (c) { fill(box, [c]); });
      return r.json().then(function (j) {
        var lines = [], src = j.source || {};
        if (src.image_build || src.memory_api) {
          lines.push(el('li', { text: 'exported from ' + (src.harness || 'a harness') + (src.image_build ? ', image build ' + src.image_build : '') +
            (src.memory_api ? ', memory API ' + src.memory_api : '') }));
        }
        if (j.loglearner) {
          var l = j.loglearner;
          lines.push(el('li', { text: 'LogLearner: ' + (l.noop ? 'already loaded (the same pack bytes), nothing would change' :
            'would add ' + l.added + ', replace ' + l.updated + ' (' + (l.replaces.length ? l.replaces.join(', ') : 'none here') +
            '), skip ' + l.skipped + ' already there; the bank would hold ' + n(l.total, 'record', 'records')) }));
          var li = l.replaces_image || {};
          if (li.count) {
            lines.push(el('li', { cls: 'warn', text: 'LogLearner: ' + n(li.count, "of this image's own default records", "of this image's own default records") +
              ' would be replaced by the version the pack carries (' + li.ids.join(', ') + (li.count > li.ids.length ? ', ...' : '') +
              '): the pack was exported from another image with these records in it' }));
          }
        }
        var hs = j.hindsight || {};
        if (hs.error) lines.push(el('li', { text: 'Hindsight: ' + hs.error }));
        Object.keys(hs).filter(function (b) { return b !== 'error'; }).forEach(function (b) {
          var h = hs[b];
          lines.push(el('li', { text: 'Hindsight bank ' + b + (h.bank === 'new' ? ' (new here)' : '') + ': ' + n(h.documents, 'document', 'documents') +
            ', ' + h['new'] + ' new, ' + h.conflicts + ' already in the bank' + (h.conflicts ? ' (' + h.conflict_ids.join(', ') +
            (h.conflicts > h.conflict_ids.length ? ', ...' : '') + '): the choice above decides them' : '') +
            (h.conflicts_image ? '; ' + n(h.conflicts_image, "of them is this image's own seed document", "of them are this image's own seed documents") +
              ', which replace would overwrite' : '') }));
        });
        if (j.replaces_kept) lines.push(el('li', { text: 'replaces the kept pack ' + j.pack + ' of the same name' }));
        fill(box, [callout('ok', 'Checked:', j.pack + ' version ' + j.version + ', ' + n(j.records, 'record', 'records') +
          ', every file matched its sha256. Nothing is written until you press Import.'), el('ul', {}, lines)]);
        checked = file;
        $('import').disabled = false;
      });
    }).catch(function (e) { fill(box, [callout('', 'Failed:', e.message)]); }).then(function () { $('preview').disabled = false; });
  }

  function importPack() {
    var box = $('import-result'), file = $('pack').files[0], choice = $('on-conflict').value;
    if (!file || file !== checked) return fill(box, [callout('warn', 'Not checked:', 'press Check for this file first.')]);
    $('import').disabled = true;
    fill(box, [el('p', { text: 'Importing ' + file.name + '...' })]);
    post('import?on_conflict=' + encodeURIComponent(choice), file, 'application/gzip').then(function (r) {
      if (!r.ok) return problem(r).then(function (c) { fill(box, [c]); });
      return r.json().then(function (j) {
        var lines = [], failed = false;
        if (j.loglearner) {
          var l = j.loglearner;
          lines.push(el('li', { text: 'LogLearner: ' + (l.noop ? 'already loaded (the same pack bytes), nothing changed' :
            l.added + ' added, ' + l.updated + ' updated, ' + l.skipped + ' already there') + '; the bank holds ' + n(l.total, 'record', 'records') }));
        }
        Object.keys(j.hindsight || {}).forEach(function (b) {
          var h = j.hindsight[b];
          if (b === 'error' || h.error) failed = true;
          var more = Object.keys(h).filter(function (k) { return ['imported', 'skipped', 'facts', 'error'].indexOf(k) < 0; })
            .map(function (k) { return ', ' + k + ' ' + h[k]; }).join('');
          lines.push(el('li', { text: b === 'error' ? 'Hindsight: ' + h : 'Hindsight bank ' + b + ': ' + (h.error ? 'not loaded - ' + h.error :
            'documents imported ' + h.imported + ' (facts ' + h.facts + '), already there ' + h.skipped + more) }));
        });
        lines.push(el('li', { text: 'documents a bank already had: ' + (j.on_conflict === 'skip' ? 'kept as they were' :
          j.on_conflict === 'replace' ? 'replaced with the pack version' : 'the pack version added beside them') }));
        lines.push(el('li', { text: 'kept as ' + j.kept + ', loaded again at every start' }));
        fill(box, [callout(failed ? 'warn' : 'ok', failed ? 'Imported in part:' : 'Imported:',
          j.pack + ' version ' + j.version + ', ' + n(j.records, 'record', 'records') + ', every file matched its sha256.'), el('ul', {}, lines)]);
        checked = null;
        return refresh();
      });
    }).catch(function (e) { fill(box, [callout('', 'Failed:', e.message)]); $('import').disabled = false; });
  }

  document.addEventListener('DOMContentLoaded', function () {
    $('export').addEventListener('click', exportPack);
    $('find').addEventListener('click', findRecords);
    $('found-all').addEventListener('change', function () {
      var on = $('found-all').checked;
      Array.prototype.forEach.call(document.querySelectorAll('input[data-record]'), function (c) { c.checked = on; });
    });
    $('preview').addEventListener('click', previewPack);
    $('import').addEventListener('click', importPack);
    $('pack').addEventListener('change', function () { checked = null; $('import').disabled = true; fill($('import-result'), []); });
    refresh();
  });
})();
