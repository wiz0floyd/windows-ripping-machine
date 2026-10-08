// Ripping Machine dashboard: re-renders from /api/jobs + /api/log every 5 s.
// Every piece of job data goes through textContent (never innerHTML), so titles
// from TMDb or disc labels can never inject markup.
'use strict';

(function () {
  const POLL_MS = 5000;
  const ACTIVE_RIP_STATES = ['Detected', 'Ripping', 'Moving'];
  const ACTION_LABELS = { approve: 'Approve', retry: 'Retry', cancel: 'Cancel' };

  function el(tag, attrs, children) {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(attrs || {})) {
      if (value === null || value === undefined) continue;
      if (key === 'text') node.textContent = String(value);
      else node.setAttribute(key, String(value));
    }
    for (const child of children || []) node.appendChild(child);
    return node;
  }

  function displayTitle(job) {
    return job.Title || job.DiscLabel || '(unidentified disc)';
  }

  function badge(state) {
    return el('span', { class: 'badge state-' + String(state || '').replace(/[^A-Za-z]/g, ''), 'data-testid': 'job-state', text: state || '' });
  }

  function formatTime(iso) {
    if (!iso) return '';
    const d = new Date(iso);
    return isNaN(d.getTime()) ? String(iso) : d.toLocaleString();
  }

  function emptyRow(colspan, text) {
    return el('tr', { class: 'empty' }, [el('td', { colspan: colspan, text: text })]);
  }

  function activeHead(job) {
    return el('div', { class: 'card-head' }, [el('h3', { 'data-testid': 'job-title', text: displayTitle(job) }), badge(job.State)]);
  }

  function activeDetails(job) {
    const dl = el('dl');
    for (const [label, value] of [['Drive', job.Drive], ['Disc type', job.DiscType], ['Disc label', job.DiscLabel], ['Staging dir', job.StagingDir], ['Updated', formatTime(job.Updated)]]) {
      if (!value) continue;
      dl.appendChild(el('dt', { text: label }));
      dl.appendChild(el('dd', { text: value }));
    }
    return dl;
  }

  // The active card is updated in place (not rebuilt) so the metadata form
  // keeps its focus and half-typed text across the 5 s poll.
  function renderActive(rips) {
    const container = document.getElementById('active-rip');
    const active = rips.filter((j) => ACTIVE_RIP_STATES.includes(j.State));
    const wanted = new Set(active.map((j) => j.Id));
    for (const child of Array.from(container.children)) {
      const id = child.getAttribute('data-job-id');
      if (!id || !wanted.has(id)) child.remove();
    }
    if (active.length === 0) {
      container.appendChild(el('p', { class: 'empty', 'data-testid': 'empty-rips', text: rips.length === 0 ? 'No rips yet' : 'No rip in progress' }));
      return;
    }
    for (const job of active) {
      let card = Array.from(container.children).find((c) => c.getAttribute('data-job-id') === job.Id);
      if (!card) {
        card = el('article', { class: 'card', 'data-testid': 'job', 'data-job-id': job.Id }, [activeHead(job), activeDetails(job)]);
        container.appendChild(card);
      } else {
        const head = card.querySelector('.card-head');
        if (head) head.replaceWith(activeHead(job)); else card.prepend(activeHead(job));
        const dl = card.querySelector('dl');
        if (dl) dl.replaceWith(activeDetails(job)); else card.appendChild(activeDetails(job));
      }
      updateMetaForm(card, job);
    }
  }

  // --- Manual metadata edit (video rips) -------------------------------------

  function buildMetaForm() {
    const field = (name, label, extra) => el('label', { class: 'meta-field' }, [
      el('span', { text: label }),
      el('input', Object.assign({ type: 'text', name: name, autocomplete: 'off', 'data-testid': 'meta-' + name }, extra)),
      el('span', { class: 'field-error', 'data-testid': 'meta-error-' + name, role: 'alert' }),
    ]);
    return el('form', { class: 'meta-form', 'data-testid': 'meta-form', novalidate: 'novalidate' }, [
      el('h4', { text: 'Edit title / year' }),
      el('div', { class: 'meta-fields' }, [
        field('title', 'Title', { maxlength: '200' }),
        field('year', 'Year', { maxlength: '4', inputmode: 'numeric' }),
      ]),
      el('p', { class: 'meta-folder' }, [document.createTextNode('NAS folder: '), el('strong', { 'data-testid': 'meta-folder', text: '' })]),
      el('div', { class: 'meta-actions' }, [
        el('button', { type: 'submit', class: 'action action-approve', 'data-testid': 'meta-save', text: 'Save' }),
        el('span', { class: 'meta-message', 'data-testid': 'meta-message', role: 'status' }),
      ]),
    ]);
  }

  function metaFormState(form) {
    return {
      title: form.querySelector('input[name="title"]'),
      year: form.querySelector('input[name="year"]'),
      save: form.querySelector('[data-testid="meta-save"]'),
      folder: form.querySelector('[data-testid="meta-folder"]'),
      message: form.querySelector('[data-testid="meta-message"]'),
      errTitle: form.querySelector('[data-testid="meta-error-title"]'),
      errYear: form.querySelector('[data-testid="meta-error-year"]'),
    };
  }

  function setMetaMessage(form, text, isError) {
    const f = metaFormState(form);
    f.message.textContent = text || '';
    f.message.classList.toggle('error', Boolean(isError));
  }

  function showMetaErrors(form, errors) {
    const f = metaFormState(form);
    f.errTitle.textContent = (errors && errors.Title) || '';
    f.errYear.textContent = (errors && errors.Year) || '';
  }

  function applyMetaEditable(form, editable, reason) {
    const f = metaFormState(form);
    form.setAttribute('data-editable', editable ? 'true' : 'false');
    f.title.readOnly = !editable;
    f.year.readOnly = !editable;
    if (!editable) {
      f.save.disabled = true;
      setMetaMessage(form, reason || 'Read-only: the rip is no longer being ripped', false);
    }
  }

  async function refreshMetaPreview(form) {
    const f = metaFormState(form);
    const seq = (Number(form.getAttribute('data-preview-seq')) || 0) + 1;
    form.setAttribute('data-preview-seq', String(seq));
    try {
      const url = '/api/metadata-preview?title=' + encodeURIComponent(f.title.value) + '&year=' + encodeURIComponent(f.year.value);
      const preview = await getJson(url);
      if (Number(form.getAttribute('data-preview-seq')) !== seq) return; // a newer keystroke superseded this one
      f.folder.textContent = preview.FolderName || '';
      showMetaErrors(form, preview.Errors);
      form.setAttribute('data-valid', preview.Valid ? 'true' : 'false');
      f.save.disabled = !preview.Valid || form.getAttribute('data-editable') !== 'true';
    } catch (err) {
      setMetaMessage(form, 'Could not preview the folder name: ' + err.message, true);
    }
  }

  async function loadMetaForm(form, jobId) {
    const f = metaFormState(form);
    try {
      const meta = await getJson('/api/jobs/' + encodeURIComponent(jobId) + '/metadata');
      if (form.getAttribute('data-dirty') !== 'true') {
        f.title.value = meta.Title || '';
        f.year.value = meta.Year || '';
      }
      form.setAttribute('data-loaded', 'true');
      applyMetaEditable(form, Boolean(meta.Editable), meta.Reason);
    } catch (err) {
      setMetaMessage(form, 'Could not load the current title: ' + err.message, true);
    }
    await refreshMetaPreview(form);
  }

  function updateMetaForm(card, job) {
    // Video rips only: audio CDs have no metadata.json path.
    if (job.DiscType === 'AudioCD') return;
    let form = card.querySelector('form.meta-form');
    const editable = (job.Actions || []).includes('metadata');
    if (!form) {
      form = buildMetaForm();
      card.appendChild(form);
      form.setAttribute('data-editable', editable ? 'true' : 'false');
      loadMetaForm(form, job.Id);
      return;
    }
    if (form.getAttribute('data-loaded') !== 'true') return;
    const was = form.getAttribute('data-editable') === 'true';
    if (editable !== was) {
      applyMetaEditable(form, editable, null);
      if (editable) refreshMetaPreview(form);
    }
  }

  async function saveMeta(form, jobId) {
    const f = metaFormState(form);
    f.save.disabled = true;
    setMetaMessage(form, 'Saving...', false);
    try {
      // The X-WRM-Action header is the server's CSRF guard for POSTs.
      const response = await fetch('/api/jobs/' + encodeURIComponent(jobId) + '/metadata', {
        method: 'POST',
        headers: { 'X-WRM-Action': '1', 'Content-Type': 'application/json' },
        body: JSON.stringify({ Title: f.title.value, Year: f.year.value }),
        cache: 'no-store',
      });
      let body = {};
      try { body = await response.json(); } catch (_) { body = {}; }
      if (response.ok) {
        form.setAttribute('data-dirty', 'false');
        setMetaMessage(form, 'Saved. Folder will be: ' + (body.FolderName || ''), false);
      } else {
        showMetaErrors(form, body.Errors);
        setMetaMessage(form, 'Could not save: ' + (body.Error || 'HTTP ' + response.status), true);
      }
    } catch (err) {
      setMetaMessage(form, 'Could not save: ' + err.message, true);
    }
    await refresh();
    await refreshMetaPreview(form);
  }

  document.addEventListener('input', (event) => {
    const form = event.target.closest && event.target.closest('form.meta-form');
    if (!form) return;
    form.setAttribute('data-dirty', 'true');
    setMetaMessage(form, '', false);
    clearTimeout(form._previewTimer);
    form._previewTimer = setTimeout(() => refreshMetaPreview(form), 150);
  });

  document.addEventListener('submit', (event) => {
    const form = event.target.closest && event.target.closest('form.meta-form');
    if (!form) return;
    event.preventDefault();
    const card = form.closest('[data-job-id]');
    if (!card || form.getAttribute('data-editable') !== 'true') return;
    saveMeta(form, card.getAttribute('data-job-id'));
  });

  function renderHistory(rips) {
    const body = document.getElementById('rip-history-body');
    const done = rips.filter((j) => !ACTIVE_RIP_STATES.includes(j.State));
    const rows = done.map((job) => el('tr', { 'data-testid': 'job', 'data-job-id': job.Id }, [
      el('td', { 'data-testid': 'job-title', text: displayTitle(job) }),
      el('td', { text: job.DiscType || '' }),
      el('td', {}, [badge(job.State)]),
      el('td', { class: 'path', text: (job.State === 'Failed' ? job.Error : job.DestDir) || '' }),
      el('td', { text: formatTime(job.Updated) }),
    ]));
    body.replaceChildren(...(rows.length ? rows : [emptyRow(5, 'No finished rips')]));
  }

  function renderUpscales(upscales) {
    const body = document.getElementById('upscale-queue-body');
    const rows = upscales.map((job) => {
      const showSample = job.State === 'AwaitingReview' && job.SamplePath;
      let detail = job.DestDir;
      if (job.State === 'Failed') detail = job.Error;
      else if (showSample) detail = job.SamplePath;
      const detailCell = el('td', { class: 'path' }, [el('span', { class: 'path-text', text: detail || '' })]);
      if (showSample) {
        detailCell.appendChild(document.createTextNode(' '));
        detailCell.appendChild(el('button', { type: 'button', class: 'copy', 'data-action': 'copy', 'data-testid': 'copy-sample', text: 'Copy path' }));
      }
      // Buttons come from the server's Actions list (the one place the
      // state -> allowed-action rule lives).
      const buttons = (job.Actions || []).filter((a) => ACTION_LABELS[a]).map((a) =>
        el('button', { type: 'button', class: 'action action-' + a, 'data-action': a, 'data-testid': 'action-' + a, text: ACTION_LABELS[a] }));
      return el('tr', { 'data-testid': 'job', 'data-job-id': job.Id }, [
        el('td', { 'data-testid': 'job-title', text: displayTitle(job) }),
        el('td', {}, [badge(job.State)]),
        detailCell,
        el('td', { text: formatTime(job.Updated) }),
        el('td', { class: 'actions' }, buttons),
      ]);
    });
    body.replaceChildren(...(rows.length ? rows : [emptyRow(5, 'No upscale jobs')]));
  }

  function showActionMessage(text, isError) {
    const node = document.getElementById('action-message');
    if (!node) return;
    node.textContent = text;
    node.classList.toggle('error', Boolean(isError));
  }

  async function runAction(jobId, action, button) {
    button.disabled = true;
    try {
      // The X-WRM-Action header is the server's CSRF guard for POSTs.
      const response = await fetch('/api/jobs/' + encodeURIComponent(jobId) + '/' + action, {
        method: 'POST',
        headers: { 'X-WRM-Action': '1' },
        cache: 'no-store',
      });
      let body = {};
      try { body = await response.json(); } catch (_) { body = {}; }
      if (response.ok) showActionMessage(ACTION_LABELS[action] + ': done', false);
      else showActionMessage('Could not ' + action + ': ' + (body.Error || 'HTTP ' + response.status), true);
    } catch (err) {
      showActionMessage('Could not ' + action + ': ' + err.message, true);
    }
    await refresh();
  }

  function copyPath(row, button) {
    const text = (row.querySelector('.path-text') || {}).textContent || '';
    const done = (ok) => { button.textContent = ok ? 'Copied' : 'Copy failed - select the path'; };
    try {
      if (!navigator.clipboard || !navigator.clipboard.writeText) { done(false); return; }
      navigator.clipboard.writeText(text).then(() => done(true), () => done(false));
    } catch (_) {
      done(false);
    }
  }

  // One delegated listener (no inline handlers: the CSP forbids them) that
  // survives every re-render of the table.
  document.addEventListener('click', (event) => {
    const button = event.target.closest('button[data-action]');
    if (!button) return;
    const row = button.closest('[data-job-id]');
    if (!row) return;
    const action = button.getAttribute('data-action');
    if (action === 'copy') { copyPath(row, button); return; }
    if (!ACTION_LABELS[action]) return;
    if (action === 'cancel' && !window.confirm('Cancel this upscale job? Its queue file will be deleted.')) return;
    runAction(row.getAttribute('data-job-id'), action, button);
  });

  async function getJson(url) {
    const response = await fetch(url, { cache: 'no-store' });
    if (!response.ok) throw new Error(url + ' -> HTTP ' + response.status);
    return response.json();
  }

  async function refresh() {
    const status = document.getElementById('refreshed');
    try {
      const [jobs, log] = await Promise.all([getJson('/api/jobs'), getJson('/api/log?lines=200')]);
      const rips = jobs.filter((j) => j.Kind === 'Rip');
      renderActive(rips);
      renderHistory(rips);
      renderUpscales(jobs.filter((j) => j.Kind === 'Upscale'));
      document.getElementById('log-tail').textContent = (log.Lines || []).join('\n');
      status.textContent = 'Updated ' + new Date().toLocaleTimeString();
      status.classList.remove('stale');
    } catch (err) {
      status.textContent = 'Update failed (' + err.message + '); retrying';
      status.classList.add('stale');
    }
  }

  // Refresh immediately too: it replaces the server-rendered ISO timestamps
  // with localized ones.
  refresh();
  setInterval(refresh, POLL_MS);
})();
