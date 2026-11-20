'use strict';

// Interpret an operator-entered clock in the player's IANA time zone, not the
// browser's zone. Reject nonexistent spring-forward times instead of shifting them.
function boardClockMillis(value, zone) {
  const parts = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?$/.exec(value);
  if (!parts) throw new Error('Enter a date and time for the player.');
  const numbers = parts.slice(1).map(Number), wanted = Date.UTC(numbers[0], numbers[1] - 1, numbers[2], numbers[3], numbers[4], numbers[5] || 0);
  let format;
  try { format = new Intl.DateTimeFormat('en-CA', { timeZone: zone, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' }); }
  catch { throw new Error('Enter a valid time zone, such as America/Los_Angeles.'); }
  const wall = (epoch) => {
    const p = Object.fromEntries(format.formatToParts(new Date(epoch)).map((part) => [part.type, part.value]));
    return Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute, +p.second);
  };
  let epoch = wanted;
  for (let attempt = 0; attempt < 4; attempt++) {
    const delta = wanted - wall(epoch);
    if (!delta) return epoch;
    epoch += delta;
  }
  throw new Error('That clock time does not exist in this time zone. Choose another time.');
}

function browserBoardClockValues() {
  const timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  if (!timeZone) throw new Error('The browser time zone could not be read. Enter a time zone manually.');
  return { utcTimeMillis: Date.now(), timeZone };
}

function openBoardControls(initialPlayer = null) {
  let players = [], connection = null, controls = {}, busy = '', pending = null;
  const lifetime = new AbortController();
  const tabs = [['brightness', 'Brightness'], ['colorTemperature', 'Color'], ['mosaic', 'Multi-mosaic'], ['time', 'Date & time'], ['ethernet', 'Ethernet'], ['wifi', 'Wi-Fi']];
  const form = openDialog({
    title: 'Player controls', wide: true,
    subtitle: 'Connect to a board to read its settings. Apply changes one section at a time.',
    body: `<div class="board-connection">
      <label class="field"><span>Player</span><select name="player"><option value="">Enter an IP address</option></select></label>
      <label class="field"><span>IP address</span><input name="ip" placeholder="192.168.1.24" autocomplete="off" spellcheck="false" inputmode="decimal"></label>
      <label class="field"><span>Player password</span><input name="playerPassword" type="text" autocomplete="off" placeholder="Player password" maxlength="256" spellcheck="false"></label>
      <button type="button" class="btn btn-primary" data-board-connect>Connect</button>
    </div>
    <p class="field-help" data-board-list-help>Remembered addresses may have changed. Enter the current IP if needed.</p>
    <div class="board-identity" data-board-identity hidden></div>
    <p class="board-status" data-board-status role="status" aria-live="polite">Connect to read the board’s current settings.</p>
    <div class="board-content" data-board-content hidden>
      ${tabs.map(([key, name]) => `<section class="board-panel" id="board-panel-${key}" aria-label="${name}" data-board-panel="${key}"></section>`).join('')}
    </div>`,
    extra: '<button type="button" class="btn btn-secondary" data-board-refresh disabled>Refresh settings</button><button type="button" class="btn btn-secondary" data-board-resume hidden>Check operation status</button>',
  });
  const dialog = $('#dialog');
  dialog.classList.add('board-controls-dialog');
  const ipInput = form.elements.ip, passwordInput = form.elements.playerPassword, playerSelect = form.elements.player;
  const connect = form.querySelector('[data-board-connect]'), refresh = form.querySelector('[data-board-refresh]'), resume = form.querySelector('[data-board-resume]');
  const status = form.querySelector('[data-board-status]'), identity = form.querySelector('[data-board-identity]'), content = form.querySelector('[data-board-content]');
  const errorBox = form.querySelector(':scope > .form-error');
  const active = () => !lifetime.signal.aborted && dialog.open && dialog.contains(form);
  const panel = (key) => form.querySelector(`[data-board-panel="${key}"]`);
  const field = (label, input, wide = false) => `<label class="field${wide ? ' span-2' : ''}"><span>${label}</span>${input}</label>`;
  const input = (name, value, extra = '') => `<input name="${name}" value="${esc(value ?? '')}" ${extra}>`;
  const apply = (key, text = 'Apply changes') => `<div class="board-apply-row"><button type="button" class="btn btn-primary" data-board-apply="${key}">${text}</button></div>`;
  function error(message = '') { errorBox.textContent = message; errorBox.hidden = !message; }
  function update() {
    const locked = Boolean(busy || pending);
    form.querySelectorAll('.board-connection input,.board-connection select,.board-panel input,.board-panel select,[data-board-apply],[data-board-sync]').forEach((element) => { element.disabled = locked || element.hasAttribute('data-unavailable'); });
    connect.disabled = locked || !ipInput.value.trim() || !passwordInput.value;
    connect.textContent = busy === 'check' ? 'Connecting…' : connection ? 'Reconnect' : 'Connect';
    refresh.disabled = locked || !connection || !passwordInput.value;
    resume.hidden = !pending;
    resume.disabled = Boolean(busy);
    for (const close of form.querySelectorAll('[data-close]')) close.disabled = busy === 'apply';
    if (!locked) updateDependentFields();
  }
  function updateDependentFields() {
    const mosaic = panel('mosaic'), enabled = mosaic.querySelector('[name=mosaicEnable]');
    if (enabled) for (const element of mosaic.querySelectorAll('input:not([name=mosaicEnable]),select')) element.disabled = !enabled.checked;
    for (const adapter of panel('ethernet').querySelectorAll('[data-ethernet-adapter]')) {
      const dhcp = adapter.querySelector('[type=checkbox]');
      for (const element of adapter.querySelectorAll('input:not([type=checkbox])')) element.disabled = dhcp.checked;
    }
  }
  function clearConnection() {
    connection = null; controls = {}; identity.hidden = true; content.hidden = true;
    error(); status.textContent = 'Connect to read the board’s current settings.'; update();
  }
  function renderIdentity() {
    identity.hidden = !connection;
    if (!connection) return;
    const d = connection.device;
    identity.innerHTML = `<strong>${esc(d.name || d.sn)}</strong><p>${esc(d.model)} · ${esc(d.ip)} · ${esc(d.width)} × ${esc(d.height)}</p><p>Serial ${esc(d.sn)}</p>`;
  }
  function renderSection(key) {
    const target = panel(key), item = controls[key], title = tabs.find(([id]) => id === key)[1];
    if (!item?.available || !item.value) {
      target.innerHTML = `<h3>${title}</h3><p class="board-section-error">${esc(item?.error || 'This setting is not available on this player.')}</p>`;
      return;
    }
    const v = item.value;
    let body = '';
    if (key === 'brightness') {
      const ratio = Number(v.ratio);
      body = `<div class="board-brightness"><input type="range" name="brightnessRange" aria-label="Brightness" min="0" max="100" step="0.1" value="${ratio}">${field('Brightness (%)', input('brightnessRatio', ratio, 'type="number" min="0" max="100" step="0.1" required'))}</div><p class="field-help">Applying sets the board to manual brightness and changes its output immediately.${v.mode ? ' Current mode: ' + esc(v.mode) + '.' : ''}</p>${apply(key, 'Apply manual brightness')}`;
    } else if (key === 'colorTemperature') {
      body = `<div class="form-grid">${field('Color temperature', `<select name="temperaturePreset" required><option value="">Choose a preset</option>${[[4700, 'Neutral · 4700 K'], [6500, 'Standard · 6500 K'], [9300, 'Cool · 9300 K']].map(([n, text]) => `<option value="${n}" ${Number(v.colorTemperature) === n ? 'selected' : ''}>${text}</option>`).join('')}</select>`)}<p class="field-help">Current setting: ${esc(v.colorTemperature)} K</p></div>${apply(key, 'Apply color temperature')}`;
    } else if (key === 'mosaic') {
      const info = v.info || {}, mode = Number(info.mode || 0), width = Number(connection.device.width);
      const max = Number(v.maxNum || info.spliceHdmiConfig?.autoSpliceHdmiConfig?.maxNum || info.spliceHdmiConfig?.autospliceHdmiConfig?.maxNum || 10);
      body = `<label class="board-checkbox"><input type="checkbox" name="mosaicEnable" ${v.enable ? 'checked' : ''}> Enable multi-mosaic</label><div class="form-grid" style="margin-top:14px">${field('Arrangement', `<select name="mosaicDirection"><option value="0" ${Number(info.direction) === 0 ? 'selected' : ''}>Left to right</option><option value="1" ${Number(info.direction) === 1 ? 'selected' : ''}>Right to left</option></select>`)}${field('Canvas size', `<select name="mosaicMode"><option value="0" ${mode === 0 ? 'selected' : ''}>Number of screens</option><option value="1" ${mode === 1 ? 'selected' : ''}>Total width in pixels</option></select>`)}${field('<span data-mosaic-length-label>' + (mode ? 'Total width (px)' : 'Screen count') + '</span>', input('mosaicLength', mode ? info.totalLength : Math.max(1, Math.round(Number(info.totalLength || width) / width)), `type="number" min="1" max="${mode ? 4096 : max}" step="1" required data-max-screens="${max}"`))}<p class="field-help">This player outputs ${esc(width)} × ${esc(connection.device.height)}. Mosaic settings define how it participates in the larger canvas.</p></div>${apply(key, 'Apply mosaic')}`;
    } else if (key === 'time') {
      const current = String(v.currentTime || '').replace(' ', 'T').slice(0, 19);
      const manual = item.automaticSync === false, unavailable = manual ? '' : ' data-unavailable disabled';
      const help = manual ? 'Manual time uses the zone above. Browser sync copies this computer’s current time and time zone.' : item.automaticSync ? 'Automatic time synchronization is enabled. You can change the time zone here; manage the synchronization source in ViPlex before setting the clock manually.' : 'The player’s automatic synchronization status could not be read. You can change the time zone; refresh settings before setting the clock manually.';
      body = `<div class="form-grid">${field('Player date and time', input('playerClock', current, 'type="datetime-local" step="1" required' + unavailable))}${field('Time zone', input('playerTimeZone', v.timeZone || Intl.DateTimeFormat().resolvedOptions().timeZone, 'placeholder="America/Los_Angeles" required spellcheck="false"'))}</div><p class="field-help">${help}</p><div class="board-apply-row"><button type="button" class="btn btn-primary" data-board-apply="time">${manual ? 'Apply date and time' : 'Apply time zone'}</button><button type="button" class="btn btn-secondary" data-board-sync${unavailable}>Sync from browser</button></div>`;
    } else if (key === 'ethernet') {
      const adapters = Array.isArray(v.ethernets) ? v.ethernets : [];
      if (!adapters.length) { target.innerHTML = '<h3>Ethernet</h3><p class="board-section-error">No Ethernet interface was reported by this player.</p>'; return; }
      body = adapters.map((eth, index) => `<div data-ethernet-adapter="${index}"><p class="field-help">Interface: ${esc(eth.name || eth.scopeId || 'Ethernet')}</p><label class="board-checkbox" style="margin:12px 0"><input type="checkbox" name="ethernetDhcp${index}" ${eth.dhcp ? 'checked' : ''}> Obtain an address automatically (DHCP)</label><div class="form-grid">${field('IP address', input('ethernetIp' + index, eth.ip, 'inputmode="decimal" autocomplete="off"'))}${field('Subnet mask', input('ethernetMask' + index, eth.mask, 'inputmode="decimal" autocomplete="off"'))}${field('Gateway', input('ethernetGateway' + index, eth.gateWay, 'inputmode="decimal" autocomplete="off"'))}${field('DNS servers', input('ethernetDns' + index, Array.isArray(eth.dns) ? eth.dns.join(', ') : '', 'placeholder="192.168.1.1, 1.1.1.1" autocomplete="off"'))}</div></div>`).join('') + `<p class="board-network-warning">Applying network changes may disconnect this board. Reconnect using its new IP address if the connection drops.</p>${apply(key, 'Apply Ethernet settings')}`;
    } else if (key === 'wifi') {
      // Only display known non-secret scalar properties. Firmware responses can
      // include saved credentials, so never stringify the complete object.
      const safe = [['Wi-Fi radio', v.state === 1 ? 'Enabled' : v.state === 0 ? 'Disabled' : 'Not reported'], ['IP address', v.ip || v.ipAddress]];
      const networks = Array.isArray(v.networks) ? v.networks : [];
      const networkStates = ['Idle', 'Configured', 'Connecting', 'Authenticating', 'Getting an IP address', 'Connected', 'Password error', 'Connection failed', 'Disconnected', 'Disconnecting'];
      body = `<dl class="board-readonly">${safe.filter(([, value]) => ['string', 'number', 'boolean'].includes(typeof value)).map(([label, value]) => `<dt>${label}</dt><dd>${esc(String(value))}</dd>`).join('')}</dl>${networks.length ? `<div class="board-wifi-list">${networks.map((network) => `<div><strong>${esc(network.ssid || '(Hidden network)')}</strong><span>${network.level != null ? 'Signal level: ' + esc(network.level) : ''}${networkStates[network.state] ? ' · ' + networkStates[network.state] : ''}</span></div>`).join('')}</div>` : '<p class="field-help">No nearby networks were reported.</p>'}<p class="field-help">Wi-Fi status is available here. Use ViPlex to change Wi-Fi connections.</p>`;
    }
    target.innerHTML = `<h3>${title}</h3>${body}`;
  }
  function renderControls(next, section) {
    // Keep the identity and values behind untouched drafts together. A readback
    // after applying brightness must not silently remap an Ethernet form.
    controls = section ? { ...controls, [section]: next[section] } : { ...controls, ...next };
    content.hidden = false;
    if (section) renderSection(section);
    else for (const [key] of tabs) renderSection(key);
    update();
  }
  async function request(path, options = {}) {
    const abort = new AbortController(), stop = () => abort.abort();
    const timer = setTimeout(stop, 20000);
    lifetime.signal.addEventListener('abort', stop, { once: true });
    try {
      const response = await fetch(path, { ...options, cache: 'no-store', signal: abort.signal });
      const body = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(body.error || 'Relay could not complete this request.');
      return body;
    } finally { clearTimeout(timer); lifetime.signal.removeEventListener('abort', stop); }
  }
  async function post(path, payload) {
    try {
      const session = await request('/api/session');
      return await request(path, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Studio-Token': session.exportToken }, body: JSON.stringify(payload) });
    } finally { delete payload.playerPassword; }
  }
  async function waitJob(id) {
    const deadline = Date.now() + 5 * 60 * 1000;
    let failures = 0;
    while (active() && Date.now() < deadline) {
      let job;
      try { job = await request(`/api/network/jobs/${encodeURIComponent(id)}`); failures = 0; }
      catch (e) { if (!active() || ++failures >= 3) throw e; }
      if (job) {
        status.textContent = job.message || 'Working…';
        if (job.status === 'complete') return job;
        if (job.status === 'failed') { const failure = new Error(job.error || job.message || 'The player could not complete this request.'); failure.jobFailed = true; throw failure; }
      }
      await new Promise((resolve) => setTimeout(resolve, 700));
    }
    throw new Error('The operation is still pending. Check operation status before making another change.');
  }
  async function finishPending() {
    const operation = pending;
    const job = await waitJob(operation.id);
    if (!active()) return;
    pending = null;
    if (operation.kind === 'check') {
      if (!job.connectionId || !job.device?.sn || job.device.ip !== operation.ip || (operation.expectedSn && job.device.sn !== operation.expectedSn)) throw new Error('The player identity could not be confirmed. Reconnect and try again.');
      connection = { id: job.connectionId, device: job.device };
      const remembered = players.find((p) => p.sn === job.device.sn);
      if (remembered?.name) connection.device.name = remembered.name;
      void refreshPlayerManagement().catch(() => {});
      renderIdentity();
      await startOperation('read');
    } else {
      const next = job.controls || job.result?.controls;
      if (job.reconnectRequired || job.result?.reconnectRequired) {
        clearConnection();
        status.textContent = job.message || 'Network changes were sent. Reconnect using the board’s current IP address to verify them.';
        return;
      }
      if (!next || typeof next !== 'object') throw new Error('The player did not return its settings. Refresh settings and try again.');
      renderControls(next, operation.kind === 'apply' ? operation.section : '');
      status.textContent = job.message || (operation.kind === 'apply' ? 'Changes applied. Settings refreshed from the player.' : 'Current settings loaded from the player.');
    }
  }
  async function startOperation(kind, section, values) {
    busy = kind; error(); update();
    try {
      let payload, path;
      if (kind === 'check') {
        const ip = ipInput.value.trim(), remembered = players.find((p) => p.id === playerSelect.value && p.ip === ip);
        payload = { ip, playerPassword: passwordInput.value, ...(remembered?.sn ? { expectedSn: remembered.sn } : {}) };
        path = '/api/network/check';
      } else {
        payload = { connectionId: connection.id, playerPassword: passwordInput.value, ...(kind === 'apply' ? { section, values } : {}) };
        path = `/api/network/controls/${kind}`;
      }
      const ip = payload.ip, expectedSn = payload.expectedSn;
      status.textContent = kind === 'check' ? 'Connecting to the player…' : kind === 'read' ? 'Reading player settings…' : 'Applying changes…';
      const started = await post(path, payload);
      if (!/^[a-f0-9]{32}$/.test(started.jobId || '')) throw new Error('Relay did not return an operation ID. Check the board before retrying.');
      pending = { id: started.jobId, kind, section, ip, expectedSn };
      await finishPending();
    } catch (e) {
      if (e.jobFailed) pending = null;
      if (active()) error(e.name === 'AbortError' ? 'The request timed out. Check operation status or reconnect before retrying.' : e.message);
    } finally { busy = ''; if (active()) update(); }
  }
  function valuesFor(key) {
    const p = panel(key), el = (name) => p.querySelector(`[name="${name}"]`);
    for (const field of p.querySelectorAll('input,select')) if (!field.disabled && !field.reportValidity()) return null;
    if (key === 'brightness') return { ratio: Number(el('brightnessRatio').value) };
    if (key === 'colorTemperature') return { colorTemperature: Number(el('temperaturePreset').value) };
    if (key === 'mosaic') {
      const mode = Number(el('mosaicMode').value), count = Number(el('mosaicLength').value);
      return { enable: el('mosaicEnable').checked, direction: Number(el('mosaicDirection').value), mode, totalLength: mode ? count : count * Number(connection.device.width) };
    }
    if (key === 'time') {
      const timeZone = el('playerTimeZone').value.trim();
      try { new Intl.DateTimeFormat('en-US', { timeZone }); }
      catch { throw new Error('Enter a valid time zone, such as America/Los_Angeles.'); }
      return controls.time.automaticSync === false ? { utcTimeMillis: boardClockMillis(el('playerClock').value, timeZone), timeZone } : { timeZone };
    }
    if (key === 'ethernet') return { ethernets: controls.ethernet.value.ethernets.map((adapter, index) => {
      const identity = { name: adapter.name, ...(Number.isInteger(adapter.scopeId) ? { scopeId: adapter.scopeId } : {}), dhcp: el('ethernetDhcp' + index).checked };
      if (identity.dhcp) return identity;
      return { ...identity, ip: el('ethernetIp' + index).value.trim(), mask: el('ethernetMask' + index).value.trim(), gateWay: el('ethernetGateway' + index).value.trim(), dns: el('ethernetDns' + index).value.split(',').map((s) => s.trim()).filter(Boolean) };
    }) };
    return null;
  }
  connect.onclick = () => { if (!busy && !pending) { clearConnection(); void startOperation('check'); } };
  refresh.onclick = () => { if (!busy && !pending && connection) void startOperation('read'); };
  resume.onclick = async () => {
    if (busy || !pending) return;
    busy = pending.kind; error(); update();
    try { await finishPending(); }
    catch (e) { if (e.jobFailed) pending = null; if (active()) error(e.message); }
    finally { busy = ''; if (active()) update(); }
  };
  form.onsubmit = (event) => event.preventDefault();
  form.addEventListener('click', (event) => {
    if (busy || pending || !connection) return;
    const applyButton = event.target.closest('[data-board-apply]');
    if (applyButton) {
      try { const key = applyButton.dataset.boardApply, values = valuesFor(key); if (values) void startOperation('apply', key, values); }
      catch (e) { error(e.message); }
    } else if (event.target.closest('[data-board-sync]')) {
      try {
        const values = browserBoardClockValues();
        form.elements.playerTimeZone.value = values.timeZone;
        void startOperation('apply', 'time', values);
      } catch (e) { error(e.message); }
    }
  });
  form.addEventListener('input', (event) => {
    const name = event.target.name;
    if (name === 'brightnessRange') form.elements.brightnessRatio.value = event.target.value;
    if (name === 'brightnessRatio') form.elements.brightnessRange.value = event.target.value;
  });
  form.addEventListener('change', (event) => {
    const name = event.target.name;
    if (name === 'mosaicMode') {
      const value = form.elements.mosaicLength, width = Number(connection.device.width), pixels = Number(event.target.value) === 1;
      value.value = pixels ? Math.min(4096, Number(value.value) * width) : Math.max(1, Math.round(Number(value.value) / width));
      value.max = pixels ? '4096' : value.dataset.maxScreens;
      panel('mosaic').querySelector('[data-mosaic-length-label]').textContent = pixels ? 'Total width (px)' : 'Screen count';
    }
    updateDependentFields();
  });
  function fillPassword() { return applyDefaultPlayerPassword(passwordInput).then((password) => { if (active()) update(); return password; }).catch(() => { if (active() && !passwordInput.value) error('The saved password could not be loaded. Enter the player password here.'); }); }
  playerSelect.onchange = async () => {
    const player = players.find((p) => p.id === playerSelect.value);
    ipInput.value = player?.ip || ''; passwordInput.value = ''; clearConnection();
    const selectedId = playerSelect.value, selectedIp = ipInput.value;
    const filledPassword = await fillPassword();
    if (!active() || playerSelect.value !== selectedId || ipInput.value.trim() !== selectedIp) return;
    if (passwordInput.value && passwordInput.value !== filledPassword) return;
    connection = relayPlayerConnection(player); renderIdentity();
    update();
    if (connection && passwordInput.value) void startOperation('read');
  };
  ipInput.oninput = () => { if (players.find((p) => p.id === playerSelect.value)?.ip !== ipInput.value.trim()) playerSelect.value = ''; clearConnection(); };
  passwordInput.oninput = clearConnection;
  const preventClose = (event) => { if (busy === 'apply') event.preventDefault(); };
  const cleanup = () => {
    if (dialog.open && dialog.contains(form)) return;
    lifetime.abort(); passwordInput.value = ''; controls = {}; connection = null;
    dialog.removeEventListener('close', cleanup); dialog.removeEventListener('cancel', preventClose);
  };
  dialog.addEventListener('close', cleanup); dialog.addEventListener('cancel', preventClose);
  update();
  void request('/api/network/players').then(async (result) => {
    if (!active()) return;
    players = Array.isArray(result.players) ? result.players.filter((p) => p.id && p.ip) : [];
    playerSelect.innerHTML = '<option value="">Enter an IP address</option>' + players.map((p) => `<option value="${esc(p.id)}">${esc(p.name || p.sn)} · ${esc(p.ip)}</option>`).join('');
    const selected = initialPlayer && players.find((p) => p.sn === initialPlayer.sn);
    if (selected) {
      playerSelect.value = selected.id; ipInput.value = selected.ip;
    } else if (initialPlayer?.ip) ipInput.value = initialPlayer.ip;
    const selectedId = playerSelect.value, selectedIp = ipInput.value;
    const filledPassword = await fillPassword();
    if (!active() || playerSelect.value !== selectedId || ipInput.value.trim() !== selectedIp) return;
    if (passwordInput.value && passwordInput.value !== filledPassword) return;
    connection = relayPlayerConnection(selected); renderIdentity(); update();
    if (initialPlayer && passwordInput.value && ipInput.value) void startOperation(connection ? 'read' : 'check');
  }).catch(() => { if (active()) { form.querySelector('[data-board-list-help]').textContent = 'Remembered players could not be loaded. Enter the current IP address.'; if (initialPlayer?.ip) ipInput.value = initialPlayer.ip; void fillPassword(); } });
}
