'use strict';

// Only operation IDs and sanitized results survive after a run. Passwords remain
// in the active call and are never stored in browser storage or result records.
const bulkBoardControlState = { busy: false, checking: false, label: '', targets: [] };
function isBulkBoardControlBusy() { return bulkBoardControlState.busy || bulkBoardControlState.checking; }
function bulkBoardControlStatusButton() {
  return bulkBoardControlState.targets.length ? `<button type="button" class="btn btn-secondary compact" data-bulk-controls-status>${isBulkBoardControlBusy() ? 'Control progress' : 'Last control changes'}</button>` : '';
}
function bulkBoardControlTargets(players) {
  if (!Array.isArray(players) || !players.length || players.length > 64) throw new Error('Select between 1 and 64 boards.');
  const seen = new Set();
  return players.map((player) => {
    const connection = relayPlayerConnection(player);
    if (!connection) throw new Error(`Connect ${player.name || player.sn || 'every selected board'} before applying controls.`);
    if (seen.has(player.sn)) throw new Error('Each board can be selected only once.');
    seen.add(player.sn);
    return { id: player.id, sn: player.sn, name: player.name || player.sn, ip: player.ip,
      connectionId: connection.id, width: Number(player.width), status: 'queued', message: 'Waiting to apply.' };
  });
}
function bulkBoardControlValues(change, target) {
  const number = (value, low, high, integer = false) => {
    if (typeof value !== 'number' || !Number.isFinite(value) || value < low || value > high || (integer && !Number.isInteger(value))) throw new Error('Enter a value in the supported range.');
    return value;
  };
  if (change.kind === 'brightness') return { section: 'brightness', values: { ratio: number(change.ratio, 0, 100) } };
  if (change.kind === 'colorTemperature') {
    if (![4700, 6500, 9300].includes(change.colorTemperature)) throw new Error('Choose a color temperature preset.');
    return { section: 'colorTemperature', values: { colorTemperature: change.colorTemperature } };
  }
  if (change.kind === 'mosaic') {
    if (typeof change.enable !== 'boolean') throw new Error('Choose whether to enable multi-mosaic.');
    if (!change.enable) return { section: 'mosaic', values: { enable: false } };
    const mode = number(change.mode, 0, 1, true), direction = number(change.direction, 0, 1, true);
    const length = number(change.length, 1, mode ? 4096 : 64, true);
    const totalLength = mode ? length : length * number(target.width, 1, 4096, true);
    number(totalLength, 1, 4096, true);
    return { section: 'mosaic', values: { enable: true, mode, direction, totalLength } };
  }
  if (change.kind === 'time' || change.kind === 'timezone' || change.kind === 'manualTime') {
    const timeZone = change.timeZone;
    if (typeof timeZone !== 'string' || !timeZone) throw new Error('Enter a time zone.');
    try { new Intl.DateTimeFormat('en-US', { timeZone }); }
    catch { throw new Error('Enter a valid time zone, such as America/Los_Angeles.'); }
    // Generate a fresh UTC timestamp when each queued board starts, so queue
    // delays do not set later boards to an earlier time.
    return { section: 'time', values: { ...(change.kind === 'time' ? { utcTimeMillis: Date.now() } : change.kind === 'manualTime' ? { utcTimeMillis: number(change.utcTimeMillis, 946684800000, 4133980799999, true) } : {}), timeZone } };
  }
  throw new Error('Choose a supported control.');
}
async function bulkBoardControlRequest(path, options = {}) {
  const abort = new AbortController(), timeout = setTimeout(() => abort.abort(), 20000);
  try {
    const response = await fetch(path, { ...options, cache: 'no-store', signal: abort.signal });
    const body = await response.json().catch(() => ({}));
    if (!response.ok) { const error = new Error(body.error || 'The control request failed.'); error.httpStatus = response.status; throw error; }
    return body;
  } finally { clearTimeout(timeout); }
}
async function postBulkBoardControl(payload) {
  try {
    const session = await bulkBoardControlRequest('/api/session');
    return await bulkBoardControlRequest('/api/network/controls/apply', { method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Studio-Token': session.exportToken }, body: JSON.stringify(payload) });
  } finally { delete payload.playerPassword; }
}
function recordBulkBoardControlResult(target, job) {
  if (job.device?.sn && job.device.sn !== target.sn) throw new Error('The board identity did not match. Reconnect before making another change.');
  target.status = job.verified === true ? 'complete' : 'unconfirmed';
  target.message = job.message || (target.status === 'complete' ? 'Settings saved and verified.' : 'The board accepted the change, but its readback did not confirm it. Refresh its controls before retrying.');
  target.terminal = true;
}
function paintBulkBoardControls() {
  const result = document.querySelector('[data-bulk-control-results]');
  if (result) result.innerHTML = bulkBoardControlResultsHtml();
  const check = document.querySelector('[data-bulk-control-check]');
  if (check) {
    check.hidden = !bulkBoardControlState.targets.some((target) => target.jobId && !target.terminal);
    check.disabled = isBulkBoardControlBusy();
  }
  const label = document.querySelector('[data-bulk-control-result-title]');
  if (label) label.textContent = bulkBoardControlState.label;
  if (typeof paintPlayerManagement === 'function') paintPlayerManagement();
}
function bulkBoardControlResultsHtml() {
  const state = bulkBoardControlState, done = state.targets.filter((target) => target.status === 'complete').length;
  const status = { queued: 'Queued', running: 'Applying', complete: 'Verified', failed: 'Failed', unconfirmed: 'Check board' };
  return `<p class="bulk-control-summary" role="status">${isBulkBoardControlBusy() ? 'Applying settings…' : 'Control changes finished.'} ${done} of ${state.targets.length} boards verified.</p><div class="bulk-control-targets">${state.targets.map((target) => `<article class="bulk-control-target bulk-control-${target.status}"><div><strong>${esc(target.name)}</strong><small>${esc(target.ip)} · ${esc(target.sn)}</small></div><span>${status[target.status] || 'Unknown'}</span><p>${esc(target.message)}</p></article>`).join('')}</div>`;
}
async function runBulkBoardControls(players, change, password) {
  if (isBulkBoardControlBusy()) throw new Error('Wait for the current control changes to finish.');
  if (typeof isNetworkBatchBusy === 'function' && isNetworkBatchBusy()) throw new Error('Wait for the multi-board upload to finish before changing controls.');
  if (typeof password !== 'string' || password.length < 1 || password.length > 256) throw new Error('Enter the shared player password.');
  const targets = bulkBoardControlTargets(players);
  // Validate every target before starting any writes, including mosaic geometry.
  for (const target of targets) bulkBoardControlValues(change, target);
  const snapshot = { ...change };
  bulkBoardControlState.targets = targets; bulkBoardControlState.label = change.label || 'Control changes'; bulkBoardControlState.busy = true;
  paintBulkBoardControls();
  try {
    await runPlayerQueue(targets, 2, async (target) => {
      target.status = 'running'; target.message = 'Applying the selected setting…'; paintBulkBoardControls();
      try {
        const command = bulkBoardControlValues(snapshot, target);
        const started = await postBulkBoardControl({ connectionId: target.connectionId, playerPassword: password, ...command });
        if (!/^[a-f0-9]{32}$/.test(started.jobId || '')) throw new Error('The request was sent without an operation ID. Check this board before retrying.');
        target.jobId = started.jobId;
        const job = await waitPlayerJob(target.jobId, (progress) => { target.message = progress.message || 'Applying…'; paintBulkBoardControls(); });
        recordBulkBoardControlResult(target, job);
      } catch (error) {
        target.terminal = Boolean(error.jobFailed || error.httpStatus);
        target.status = target.terminal ? 'failed' : 'unconfirmed';
        target.message = error.name === 'AbortError' ? 'The response timed out. Check this board before retrying; the change may have reached it.' : error.message;
      }
      paintBulkBoardControls();
    });
    return targets;
  } finally {
    password = ''; bulkBoardControlState.busy = false; paintBulkBoardControls();
  }
}
async function checkBulkBoardControlStatus() {
  if (isBulkBoardControlBusy()) return;
  bulkBoardControlState.checking = true; paintBulkBoardControls();
  try {
    await runPlayerQueue(bulkBoardControlState.targets.filter((target) => target.jobId && !target.terminal), 2, async (target) => {
      try { recordBulkBoardControlResult(target, await waitPlayerJob(target.jobId)); }
      catch (error) {
        target.terminal = Boolean(error.jobFailed); target.status = target.terminal ? 'failed' : 'unconfirmed'; target.message = error.message;
      }
      paintBulkBoardControls();
    });
  } finally { bulkBoardControlState.checking = false; paintBulkBoardControls(); }
}
function openBulkBoardControlStatus() {
  openDialog({ title: bulkBoardControlState.label || 'Control changes', wide: true,
    subtitle: isBulkBoardControlBusy() ? 'Keep this Relay tab open until every board finishes. You can close this dialog and follow Control progress on the Players page.' : 'Each board is checked independently. Failed or unconfirmed changes are never retried automatically.',
    body: '<div data-bulk-control-results></div>',
    extra: '<button type="button" class="btn btn-secondary" data-bulk-control-check>Check pending results</button>' });
  paintBulkBoardControls();
}
function openBulkBoardControls(initialPlayers = []) {
  if (isBulkBoardControlBusy()) { openBulkBoardControlStatus(); return; }
  if (typeof isNetworkBatchBusy === 'function' && isNetworkBatchBusy()) { notice('Wait for the multi-board upload to finish before changing controls.'); return; }
  const selected = initialPlayers.map((player) => ({ ...player }));
  const zone = Intl.DateTimeFormat().resolvedOptions().timeZone || '';
  const apply = (kind, label) => `<button type="button" class="btn btn-primary" data-bulk-control-apply="${kind}">${label} on ${selected.length} ${selected.length === 1 ? 'board' : 'boards'}</button>`;
  const form = openDialog({ title: 'Control selected boards', wide: true,
    subtitle: 'All shared controls in one view. Each Apply button changes only its own setting on the selected boards.',
    body: `<div class="bulk-control-recipient-list">${selected.map((player) => `<div><strong>${esc(player.name || player.sn)}</strong><span>${esc(player.ip || 'No saved IP')}</span></div>`).join('')}</div>
      <label class="field">Shared player password<input name="playerPassword" type="text" maxlength="256" autocomplete="off" spellcheck="false" required></label>
      <p class="field-help" data-bulk-control-help>Changes take effect on every selected board. Keep this Relay tab open until every board finishes.</p>
      <section class="bulk-control-fields" aria-label="Brightness" data-bulk-control-group="brightness"><h3>Brightness</h3><label class="field">Brightness (%)<input name="ratio" type="number" min="0" max="100" step="0.1" placeholder="0–100" required></label><p class="field-help">This switches every selected board to manual brightness.</p>${apply('brightness', 'Apply manual brightness')}</section>
      <section class="bulk-control-fields" aria-label="Color temperature" data-bulk-control-group="colorTemperature"><h3>Color temperature</h3><label class="field">Color temperature<select name="colorTemperature"><option value="4700">Neutral · 4700 K</option><option value="6500" selected>Standard · 6500 K</option><option value="9300">Cool · 9300 K</option></select></label><div class="board-apply-row">${apply('colorTemperature', 'Apply color temperature')}</div></section>
      <section class="bulk-control-fields" aria-label="Multi-mosaic" data-bulk-control-group="mosaic"><h3>Multi-mosaic</h3><label class="board-checkbox"><input type="checkbox" name="mosaicEnable" checked> Enable multi-mosaic</label><div class="form-grid"><label class="field">Arrangement<select name="mosaicDirection"><option value="0">Left to right</option><option value="1">Right to left</option></select></label><label class="field">Canvas size<select name="mosaicMode"><option value="0">Number of boards</option><option value="1">Total width in pixels</option></select></label><label class="field"><span data-bulk-mosaic-length>Number of boards</span><input name="mosaicLength" type="number" min="1" max="64" step="1" value="${Math.min(64, Math.max(1, selected.length))}" required></label></div><p class="field-help">Board-count mode uses each board’s output width, up to 4096 px and its reported board limit. Existing mosaic positions and firmware settings are preserved.</p>${apply('mosaic', 'Apply multi-mosaic')}</section>
      <section class="bulk-control-fields" aria-label="Date and time" data-bulk-control-group="time"><h3>Date &amp; time</h3><div class="form-grid"><label class="field">Player date and time<input name="playerClock" type="datetime-local" step="1"></label><label class="field">Time zone<input name="timeZone" value="${esc(zone)}" placeholder="America/Los_Angeles" spellcheck="false" required></label></div><p class="field-help">Manual time uses the zone above. Browser sync copies the current time and ${esc(zone)} time zone. Automatic time sources remain enabled; boards using one will report that a manual clock change is unavailable.</p><div class="board-apply-row">${apply('manualTime', 'Apply date and time')}${apply('timezone', 'Apply time zone')}${apply('time', 'Sync from browser')}</div></section>
      <section class="bulk-control-fields" aria-label="Network"><h3>Network</h3><p class="field-help">Network addresses and interface details belong to individual boards. Use each player’s Controls to edit Ethernet settings or view Wi-Fi status.</p></section>
      <section class="bulk-control-results-section" data-bulk-control-results-section hidden><h3 data-bulk-control-result-title></h3><div data-bulk-control-results></div><button type="button" class="btn btn-secondary" data-bulk-control-check hidden>Check pending results</button></section>` });
  const dialog = $('#dialog'), error = form.querySelector(':scope > .form-error');
  let submitting = false;
  const active = () => dialog.open && dialog.contains(form);
  function update() {
    let message = '';
    try { bulkBoardControlTargets(selected); } catch (failure) { message = failure.message; }
    const locked = submitting || isBulkBoardControlBusy();
    for (const field of form.querySelectorAll('input,select')) field.disabled = locked;
    for (const button of form.querySelectorAll('[data-bulk-control-apply]')) button.disabled = locked || !form.elements.playerPassword.value || Boolean(message);
    if (!locked && !form.elements.mosaicEnable.checked) for (const field of form.querySelectorAll('[data-bulk-control-group="mosaic"] .form-grid input,[data-bulk-control-group="mosaic"] .form-grid select')) field.disabled = true;
    if (message) { error.textContent = message; error.hidden = false; }
  }
  function changeFromForm(kind) {
    if (kind === 'brightness') return { kind, ratio: Number(form.elements.ratio.value), label: `Brightness · ${form.elements.ratio.value}%` };
    if (kind === 'colorTemperature') return { kind, colorTemperature: Number(form.elements.colorTemperature.value), label: `Color temperature · ${form.elements.colorTemperature.value} K` };
    if (kind === 'mosaic') return { kind, enable: form.elements.mosaicEnable.checked, mode: Number(form.elements.mosaicMode.value), direction: Number(form.elements.mosaicDirection.value), length: Number(form.elements.mosaicLength.value), label: 'Multi-mosaic changes' };
    if (kind === 'time') return { kind, timeZone: browserBoardClockValues().timeZone, label: 'Browser date, time & time zone' };
    if (kind === 'manualTime') return { kind, utcTimeMillis: boardClockMillis(form.elements.playerClock.value, form.elements.timeZone.value.trim()), timeZone: form.elements.timeZone.value.trim(), label: 'Date, time & time zone' };
    return { kind, timeZone: form.elements.timeZone.value.trim(), label: 'Time zone changes' };
  }
  form.elements.playerPassword.oninput = update;
  form.addEventListener('change', (event) => {
    if (event.target.name === 'mosaicMode') {
      const pixels = event.target.value === '1'; form.elements.mosaicLength.max = pixels ? '4096' : '64';
      form.elements.mosaicLength.value = pixels ? String(Math.min(4096, Number(form.elements.mosaicLength.value) * (selected[0]?.width || 320))) : String(Math.min(64, Math.max(1, Math.round(Number(form.elements.mosaicLength.value) / (selected[0]?.width || 320)))));
      form.querySelector('[data-bulk-mosaic-length]').textContent = pixels ? 'Total width (px)' : 'Number of boards';
    }
    if (event.target.name === 'mosaicEnable') update();
  });
  form.onsubmit = (event) => event.preventDefault();
  form.addEventListener('click', async (event) => {
    const button = event.target.closest('[data-bulk-control-apply]');
    if (!button || button.disabled || submitting || isBulkBoardControlBusy()) return;
    if (!form.elements.playerPassword.reportValidity()) return;
    const kind = button.dataset.bulkControlApply;
    const group = button.closest('[data-bulk-control-group]');
    // Validate only the setting being applied: an empty brightness draft must
    // not block a color change or browser sync.
    if (kind === 'timezone') { if (!form.elements.timeZone.reportValidity()) return; }
    else if (kind !== 'time') for (const field of group.querySelectorAll('input,select')) if (!field.disabled && !field.reportValidity()) return;
    error.hidden = true;
    let password = form.elements.playerPassword.value;
    try {
      const change = changeFromForm(kind);
      submitting = true; update();
      const current = await bulkBoardControlRequest('/api/network/players');
      if (!active()) return;
      const players = selected.map((old) => (current.players || []).find((player) => player.id === old.id && player.sn === old.sn));
      if (players.some((player) => !player)) throw new Error('The selected player list changed. Reopen controls and select the boards again.');
      bulkBoardControlTargets(players).forEach((target) => bulkBoardControlValues(change, target));
      form.querySelector('[data-bulk-control-results-section]').hidden = false;
      const running = runBulkBoardControls(players, change, password);
      password = '';
      await running;
    } catch (failure) { if (active()) { error.textContent = failure.message; error.hidden = false; } }
    finally { password = ''; submitting = false; if (active()) update(); }
  });
  const cleanup = () => { if (!active()) { form.elements.playerPassword.value = ''; dialog.removeEventListener('close', cleanup); } };
  dialog.addEventListener('close', cleanup);
  update();
  void applyDefaultPlayerPassword(form.elements.playerPassword).then(() => { if (active()) update(); }).catch(() => { if (active()) { error.textContent = 'Enter the shared player password to apply controls.'; error.hidden = false; } });
}
document.addEventListener('click', (event) => {
  if (event.target.closest('[data-bulk-controls-status]')) openBulkBoardControlStatus();
  else if (event.target.closest('[data-bulk-control-check]')) void checkBulkBoardControlStatus();
});
window.addEventListener('beforeunload', (event) => {
  if (!bulkBoardControlState.busy) return;
  event.preventDefault(); event.returnValue = '';
});
