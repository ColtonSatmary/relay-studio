'use strict';

const networkBatchState = { id: '', requestId: '', snapshot: null, pending: null, posting: false, polling: false, timer: null, error: '', generation: 0 };
try {
  const savedBatch = JSON.parse(sessionStorage.getItem('relay-network-batch') || '{}');
  if (/^[a-f0-9]{32}$/.test(savedBatch.id || '')) networkBatchState.id = savedBatch.id;
  if (/^[a-f0-9-]{32,36}$/.test(savedBatch.requestId || '')) networkBatchState.requestId = savedBatch.requestId;
} catch { /* Progress can still be followed without browser storage. */ }

function rememberNetworkBatch() {
  try { sessionStorage.setItem('relay-network-batch', JSON.stringify({ id: networkBatchState.id, requestId: networkBatchState.requestId })); }
  catch { /* The server continues uploads independently of this window. */ }
}
function isNetworkBatchBusy() {
  return Boolean(networkBatchState.posting || networkBatchState.pending ||
    networkBatchState.snapshot?.status === 'running' || (!networkBatchState.snapshot && (networkBatchState.id || networkBatchState.requestId)));
}
function networkBatchStatusButton() {
  if (!networkBatchState.id && !networkBatchState.requestId && !networkBatchState.error) return '';
  return `<button type="button" class="btn btn-secondary compact" data-network-batch-status>${isNetworkBatchBusy() ? 'Upload progress' : 'Last upload'}</button>`;
}
function networkBatchPrograms(type, query = '') {
  const search = query.trim().toLocaleLowerCase();
  const scheduled = new Set(project.cues.filter(M.cueHasOccurrences).map((cue) => cue.screenId));
  return (type === 'schedule' ? project.screens.filter((screen) => scheduled.has(screen.id)) : project.solutions.filter(canUsbPlaybackSolution))
    .filter((item) => item.name.toLocaleLowerCase().includes(search)).sort((a, b) => a.name.localeCompare(b.name));
}
function networkBatchTargets(players, selected) {
  if (!selected.size) throw new Error('Select at least one board.');
  const chosen = [...selected].map((id) => players.find((player) => player.id === id));
  if (chosen.some((player) => !player || !relayPlayerConnection(player))) throw new Error('Connect every selected board on the Players page before uploading.');
  if (new Set(chosen.map((player) => player.sn)).size !== chosen.length) throw new Error('Each board can be selected only once.');
  return chosen.map((player) => ({ connectionId: player.connectionId }));
}
async function networkBatchRequest(url, options = {}) {
  const controller = new AbortController(), timeout = setTimeout(() => controller.abort(), 20000);
  try {
    const response = await fetch(url, { ...options, cache: 'no-store', signal: controller.signal });
    const body = await response.json().catch(() => ({}));
    if (!response.ok) { const error = new Error(body.error || 'The upload request could not be completed.'); error.httpStatus = response.status; throw error; }
    return body;
  } catch (error) {
    if (error.name === 'AbortError') throw new Error('The upload request timed out. Check its status before starting another upload.');
    throw error;
  } finally { clearTimeout(timeout); }
}
async function networkBatchPost(payload) {
  try {
    const session = await networkBatchRequest('/api/session');
    return await networkBatchRequest('/api/network/batches', { method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Studio-Token': session.exportToken }, body: JSON.stringify(payload) });
  } finally { delete payload.playerPassword; }
}
function notifyNetworkBatchChanged() {
  paintNetworkBatchStatus();
  if (typeof paintPlayerManagement === 'function') paintPlayerManagement();
}
function networkBatchReceiptHtml(snapshot) {
  if (!snapshot) return '<p class="field-help">Checking the server for this upload…</p>';
  const targets = Array.isArray(snapshot.targets) ? snapshot.targets : [];
  const amount = Math.max(0, Math.min(100, Number(snapshot.progress) || 0));
  return `<div class="batch-overview"><strong>${esc(snapshot.name || 'Network upload')}</strong><span>${esc(snapshot.message || (snapshot.status === 'running' ? 'Uploads are in progress.' : 'Upload finished.'))}</span>
    <progress max="100" value="${amount}" aria-label="Overall upload progress"></progress></div>
    <div class="batch-target-results">${targets.map((target) => {
      const labels = { queued: 'Queued', running: 'Uploading', complete: 'Complete', failed: 'Failed' };
      const status = labels[target.status] || 'Checking status';
      const progress = Math.max(0, Math.min(100, Number(target.progress) || 0));
      return `<article class="batch-target-result batch-target-${['complete', 'failed'].includes(target.status) ? target.status : 'active'}"><div><strong>${esc(target.name || target.sn)}</strong><small>${esc(target.ip)} · ${esc(target.sn)}</small></div><span>${status}</span>
        ${target.status === 'running' ? `<progress max="100" value="${progress}" aria-label="Upload progress for ${esc(target.name || target.sn)}"></progress>` : ''}
        <p>${esc(target.error || target.message || '')}</p></article>`;
    }).join('')}</div>`;
}
function paintNetworkBatchStatus() {
  const panel = document.querySelector('[data-network-batch-results]');
  if (!panel) return;
  panel.innerHTML = networkBatchReceiptHtml(networkBatchState.snapshot);
  const error = document.querySelector('[data-network-batch-error]');
  if (error) { error.hidden = !networkBatchState.error; error.textContent = networkBatchState.error; }
  const retry = document.querySelector('[data-network-batch-retry]');
  if (retry) retry.hidden = !networkBatchState.pending || Boolean(networkBatchState.id) || networkBatchState.posting;
  const dismiss = document.querySelector('[data-network-batch-dismiss]');
  if (dismiss) dismiss.hidden = !networkBatchState.requestId || Boolean(networkBatchState.id || networkBatchState.pending || networkBatchState.posting) || !networkBatchState.error;
}
async function refreshNetworkBatchStatus() {
  if (networkBatchState.polling) return;
  networkBatchState.polling = true;
  const generation = networkBatchState.generation;
  try {
    if (!networkBatchState.id) {
      const listing = await networkBatchRequest('/api/network/batches');
      if (generation !== networkBatchState.generation) return;
      const batches = Array.isArray(listing.batches) ? listing.batches : [];
      const found = networkBatchState.requestId ? batches.find((batch) => batch.requestId === networkBatchState.requestId)
        : batches.find((batch) => batch.status === 'running');
      if (found) { networkBatchState.id = found.id; networkBatchState.requestId = found.requestId || ''; networkBatchState.pending = null; }
      else if (networkBatchState.requestId) {
        networkBatchState.error = networkBatchState.pending
          ? 'The server has not confirmed this request. Check status again, or retry the same request; Relay will not upload it twice.'
          : 'This upload request could not be found. If Relay restarted, check the boards before starting another upload.';
        return;
      } else return;
    }
    const result = await networkBatchRequest(`/api/network/batches/${encodeURIComponent(networkBatchState.id)}`);
    if (generation !== networkBatchState.generation) return;
    if (result.id !== networkBatchState.id || !['running', 'complete', 'partial', 'failed'].includes(result.status)) throw new Error('The upload status was not recognized.');
    networkBatchState.snapshot = result; networkBatchState.pending = null; networkBatchState.error = '';
    rememberNetworkBatch();
  } catch (error) {
    if (generation !== networkBatchState.generation) return;
    networkBatchState.error = error.httpStatus === 404
      ? 'This upload session is no longer available. Check the boards before starting another upload.' : error.message;
    if (error.httpStatus === 404) { networkBatchState.id = ''; networkBatchState.requestId = ''; networkBatchState.pending = null; networkBatchState.snapshot = null; rememberNetworkBatch(); }
  } finally {
    networkBatchState.polling = false; notifyNetworkBatchChanged();
    clearTimeout(networkBatchState.timer);
    if (networkBatchState.id && (!networkBatchState.snapshot || networkBatchState.snapshot.status === 'running')) {
      networkBatchState.timer = setTimeout(() => void refreshNetworkBatchStatus(), 1200);
    }
  }
}
function openNetworkBatchStatus() {
  const form = openDialog({ title: 'Upload progress', wide: true,
    subtitle: 'Each board uploads independently. You can close this window; Relay keeps the queue running while the local service is open.',
    body: '<p class="form-error" data-network-batch-error role="alert" hidden></p><section data-network-batch-results aria-live="polite"></section>',
    extra: '<button type="button" class="btn btn-secondary" data-network-batch-refresh>Check status</button><button type="button" class="btn btn-secondary" data-network-batch-retry hidden>Retry same request</button><button type="button" class="text-link" data-network-batch-dismiss hidden>Dismiss missing request</button>' });
  form.querySelector('[data-network-batch-refresh]').onclick = () => void refreshNetworkBatchStatus();
  form.querySelector('[data-network-batch-retry]').onclick = () => retryNetworkBatch();
  form.querySelector('[data-network-batch-dismiss]').onclick = () => {
    if (networkBatchState.id || networkBatchState.pending || networkBatchState.posting) return;
    networkBatchState.generation++; networkBatchState.requestId = ''; networkBatchState.error = ''; rememberNetworkBatch();
    $('#dialog').close(); notifyNetworkBatchChanged();
  };
  paintNetworkBatchStatus(); void refreshNetworkBatchStatus();
}
async function sendNetworkBatchSnapshot(snapshot, password) {
  networkBatchState.generation++;
  networkBatchState.pending = snapshot; networkBatchState.requestId = snapshot.requestId; networkBatchState.id = '';
  networkBatchState.snapshot = null; networkBatchState.posting = true; networkBatchState.error = ''; rememberNetworkBatch(); notifyNetworkBatchChanged();
  try {
    const result = await networkBatchPost({ ...snapshot, playerPassword: password });
    if (!/^[a-f0-9]{32}$/.test(result.batchId || '')) throw new Error('Relay did not return an upload ID. Check status before retrying.');
    networkBatchState.id = result.batchId; networkBatchState.pending = null; rememberNetworkBatch();
    void refreshNetworkBatchStatus(); return true;
  } catch (error) {
    networkBatchState.error = error.message;
    if (error.httpStatus >= 400 && error.httpStatus < 500) {
      networkBatchState.pending = null; networkBatchState.requestId = ''; rememberNetworkBatch(); throw error;
    }
    // An accepted request may lose its HTTP reply. Preserve its exact request
    // ID and content snapshot; status recovery never starts a second upload.
    void refreshNetworkBatchStatus(); return false;
  } finally { password = ''; networkBatchState.posting = false; notifyNetworkBatchChanged(); }
}
function retryNetworkBatch() {
  const snapshot = networkBatchState.pending;
  if (!snapshot || networkBatchState.posting) return;
  const form = openDialog({ title: 'Retry upload request',
    subtitle: 'This retries the exact same content and selected boards with its original request ID.',
    body: '<label class="field">Player password<input name="playerPassword" type="text" spellcheck="false" autocapitalize="none" autocomplete="off" maxlength="256" required></label>', submitLabel: 'Retry same request',
    async onSubmit(form) { const password = form.elements.playerPassword.value; form.elements.playerPassword.value = ''; await sendNetworkBatchSnapshot(snapshot, password); openNetworkBatchStatus(); } });
  void applyDefaultPlayerPassword(form.elements.playerPassword).catch(() => {});
}

function openNetworkBatch(initialPlayers = [], seed = {}) {
  if (typeof isAutomaticPlayerReconnectBusy === 'function' && isAutomaticPlayerReconnectBusy()) {
    notice('Relay is reconnecting saved players. Wait for the connection checks to finish before uploading.'); return;
  }
  if (typeof isBulkBoardControlBusy === 'function' && isBulkBoardControlBusy()) {
    notice('Wait for the board controls to finish before uploading.'); return;
  }
  if (isNetworkBatchBusy()) { openNetworkBatchStatus(); return; }
  let players = [], selected = new Set(initialPlayers.map((player) => player.id || player.sn));
  let loading = true, submitting = false;
  const form = openDialog({ title: 'Upload to boards', wide: true,
    subtitle: 'Choose one solution or schedule and the boards that should play it.',
    body: `<div class="form-grid"><label class="field">Content type<select name="programType"><option value="solution">Solution</option><option value="schedule">Schedule</option></select></label>
      <label class="field">Find content<input type="search" name="programSearch" placeholder="Search by name" autocomplete="off"></label>
      <label class="field span-2">Content<select name="programId" required></select></label></div>
      <div class="batch-pick-head"><strong data-batch-count>Loading boards…</strong><button type="button" class="text-link" data-batch-select-connected>Select connected boards</button></div>
      <div class="batch-player-picks" data-batch-player-picks></div><p class="field-help" data-batch-player-help>Loading verified connections…</p>
      <label class="field batch-password">Shared player password<input name="playerPassword" type="text" spellcheck="false" autocapitalize="none" autocomplete="off" maxlength="256" required></label>
      <p class="batch-effect">Upload and play starts this content on every selected board, replacing its active playback. Boards finish independently; this is not a synchronized start.</p>`,
    submitLabel: 'Upload and play',
  });
  const dialog = $('#dialog'), submit = form.querySelector('[type=submit]'), error = form.querySelector(':scope > .form-error');
  const type = form.elements.programType, query = form.elements.programSearch, program = form.elements.programId, password = form.elements.playerPassword;
  const active = () => dialog.open && dialog.contains(form);
  function update() {
    if (!active()) return;
    let ready = false;
    try { networkBatchTargets(players, selected); ready = true; } catch { }
    submit.disabled = loading || submitting || !program.value || !password.value || !ready;
    submit.textContent = submitting ? 'Starting uploads…' : `Upload and play on ${selected.size} ${selected.size === 1 ? 'board' : 'boards'}`;
    form.querySelector('[data-batch-count]').textContent = `${selected.size} ${selected.size === 1 ? 'board' : 'boards'} selected`;
    form.querySelector('[data-batch-player-help]').textContent = loading ? 'Loading verified connections…'
      : selected.size && !ready ? 'Some selected boards are not connected. Connect them on the Players page, or remove them from this selection.'
        : 'Only selected boards receive this content. The same password is used for each board.';
    for (const control of form.querySelectorAll('input,select,[data-batch-select-connected]')) control.disabled = submitting;
    for (const close of form.querySelectorAll('[data-close]')) close.disabled = submitting;
  }
  function renderPrograms(preferred = program.value) {
    const options = networkBatchPrograms(type.value, query.value);
    program.innerHTML = '<option value="">Choose content…</option>' + options.map((item) => `<option value="${esc(item.id)}">${esc(item.name)} · ${item.width} × ${item.height}</option>`).join('');
    program.value = options.some((item) => item.id === preferred) ? preferred : '';
    update();
  }
  function renderPlayers() {
    form.querySelector('[data-batch-player-picks]').innerHTML = players.length ? players.map((player) =>
      `<label class="batch-player-pick"><input type="checkbox" data-batch-player="${esc(player.id)}" ${selected.has(player.id) ? 'checked' : ''}><span><strong>${esc(player.name || player.sn)}</strong><small>${esc(player.ip || 'No saved IP')} · ${esc(player.sn)}</small></span><em>${relayPlayerConnection(player) ? 'Connected' : 'Connect first'}</em></label>`).join('') : '<p class="field-help">No saved players. Discover and connect boards on the Players page.</p>';
    update();
  }
  type.value = seed.programType === 'schedule' ? 'schedule' : 'solution';
  renderPrograms(seed.programId || '');
  type.onchange = () => { query.value = ''; renderPrograms(''); };
  query.oninput = () => renderPrograms(); program.onchange = update; password.oninput = update;
  form.querySelector('[data-batch-select-connected]').onclick = () => { selected = new Set(players.filter(relayPlayerConnection).map((player) => player.id)); renderPlayers(); };
  form.addEventListener('change', (event) => {
    if (!event.target.matches('[data-batch-player]')) return;
    if (event.target.checked) selected.add(event.target.dataset.batchPlayer); else selected.delete(event.target.dataset.batchPlayer);
    update();
  });
  const preventClose = (event) => { if (submitting) event.preventDefault(); };
  const cleanup = () => { if (active()) return; password.value = ''; dialog.removeEventListener('cancel', preventClose); dialog.removeEventListener('close', cleanup); };
  dialog.addEventListener('cancel', preventClose); dialog.addEventListener('close', cleanup);
  form.onsubmit = async (event) => {
    event.preventDefault(); if (submitting || loading) return;
    error.hidden = true;
    try {
      const targets = networkBatchTargets(players, selected), content = networkBatchPrograms(type.value).find((item) => item.id === program.value);
      if (!content || !password.value) throw new Error('Choose content and enter the player password.');
      const snapshot = JSON.parse(JSON.stringify({ requestId: crypto.randomUUID().replace(/-/g, ''),
        project: { ...project, cues: project.cues.filter(M.cueHasOccurrences) }, programType: type.value, programId: content.id, targets }));
      submitting = true; update();
      await sendNetworkBatchSnapshot(snapshot, password.value); password.value = '';
      submitting = false; if (active()) openNetworkBatchStatus();
    } catch (failure) { if (active()) { error.textContent = failure.message; error.hidden = false; } }
    finally { submitting = false; update(); }
  };
  void applyDefaultPlayerPassword(password).then(update).catch(() => { if (active()) { error.textContent = 'Enter the shared player password to upload.'; error.hidden = false; } });
  void networkBatchRequest('/api/network/players').then((result) => {
    if (!active()) return;
    players = Array.isArray(result.players) ? result.players.filter((player) => player.id && player.sn) : [];
    for (const wanted of initialPlayers) if (!players.some((player) => player.sn === wanted.sn)) players.push({ ...wanted, connected: false, connectionId: '' });
    players.sort((a, b) => Number(selected.has(b.id)) - Number(selected.has(a.id)) || Number(Boolean(relayPlayerConnection(b))) - Number(Boolean(relayPlayerConnection(a))) || (a.name || a.sn).localeCompare(b.name || b.sn));
    loading = false; renderPlayers();
  }).catch((failure) => { if (active()) { loading = false; error.textContent = failure.message; error.hidden = false; update(); } });
}

document.addEventListener('click', (event) => {
  if (event.target.closest('[data-network-batch-status]')) openNetworkBatchStatus();
});
document.addEventListener('DOMContentLoaded', () => { void refreshNetworkBatchStatus(); });
