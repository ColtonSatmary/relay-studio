'use strict';

const playerManager = { players: [], selected: new Set(), found: new Set(), states: new Map(), loaded: false, loading: null,
  error: '', message: '', discovering: false, discoveryJobId: '', batch: false, previews: new Map(), previewing: false };
const playerAutoReconnect = { started: false, pending: false, running: null, timer: null, revision: 0, attempted: new Set() };
let playerConnectionChannel = null;
try {
  if (typeof BroadcastChannel !== 'undefined') {
    playerConnectionChannel = new BroadcastChannel('relay-player-connection-status');
    playerConnectionChannel.onmessage = (event) => {
      if (event.data?.type === 'connections-updated') void refreshPlayerManagement().catch(() => {});
    };
  }
} catch { /* Directory refresh still works when cross-tab messaging is unavailable. */ }

function isAutomaticPlayerReconnectBusy() { return Boolean(playerAutoReconnect.running); }

function playerNetworkBusy() {
  return playerManager.batch || playerManager.discovering || playerManager.previewing ||
    (typeof isNetworkBatchBusy === 'function' && isNetworkBatchBusy()) ||
    (typeof isBulkBoardControlBusy === 'function' && isBulkBoardControlBusy());
}

function automaticPlayerConnectionsBlocked(ignoreConnectionBatch = false) {
  return (!ignoreConnectionBatch && playerManager.batch) || playerManager.discovering || playerManager.previewing ||
    Boolean(document.querySelector('#dialog[open]')) ||
    (typeof isNetworkBatchBusy === 'function' && isNetworkBatchBusy()) ||
    (typeof isBulkBoardControlBusy === 'function' && isBulkBoardControlBusy());
}
function automaticPlayerConnectionKey(player) { return `${player.sn}\n${player.ip}`; }
function queueAutomaticPlayerConnections(resetAttempts = false) {
  if (resetAttempts) { playerAutoReconnect.revision++; playerAutoReconnect.attempted.clear(); }
  playerAutoReconnect.pending = true;
  if (playerAutoReconnect.running || playerAutoReconnect.timer) return;
  playerAutoReconnect.timer = setTimeout(() => {
    playerAutoReconnect.timer = null;
    void reconnectSavedPlayersAutomatically();
  }, 500);
}
async function reconnectSavedPlayersAutomatically() {
  if (playerAutoReconnect.running) return playerAutoReconnect.running;
  if (!playerAutoReconnect.pending) return;
  if (automaticPlayerConnectionsBlocked()) { queueAutomaticPlayerConnections(); return; }
  const revision = playerAutoReconnect.revision;
  playerAutoReconnect.pending = false;
  const connect = async () => {
    let password = '';
    try {
      if (typeof window !== 'undefined' && window.studioRuntimeReady && !await window.studioRuntimeReady) return;
      // Coordinate other tabs' startup passes without duplicate logins.
      // Only this request owns the password; no reconnect state stores it.
      password = await loadStudioDefaultPlayerPassword(true);
      if (revision !== playerAutoReconnect.revision) return;
      if (!password) {
        if (playerManager.message.includes('waiting')) {
          playerManager.message = 'Save a player password to resume automatic connections.';
          paintPlayerManagement();
        }
        return;
      }
      await refreshPlayerManagement();
      if (automaticPlayerConnectionsBlocked()) { playerAutoReconnect.pending = true; return; }
      const players = playerManager.players.filter((player) => player.ip && !relayPlayerConnection(player) &&
        !playerAutoReconnect.attempted.has(automaticPlayerConnectionKey(player)));
      if (!players.length) return;
      const results = await connectManagedPlayers(players, password, {
        automatic: true,
        canStart: () => revision === playerAutoReconnect.revision && !automaticPlayerConnectionsBlocked(true),
        onAttempt: (player) => playerAutoReconnect.attempted.add(automaticPlayerConnectionKey(player)),
      });
      if (results?.some((result) => result.status === 'fulfilled' && result.value?.skipped)) playerAutoReconnect.pending = true;
    } catch (error) {
      playerManager.error = `Automatic reconnect could not finish. ${error.message}`;
      paintPlayerManagement();
    } finally { password = ''; }
  };
  playerAutoReconnect.running = (async () => {
    try {
      if (typeof navigator !== 'undefined' && navigator.locks?.request) {
        await navigator.locks.request('relay-saved-player-reconnect', { mode: 'exclusive', ifAvailable: true }, async (lock) => {
          if (lock) await connect();
          // Another tab owns the checks. Its verified results are shared by the
          // service, and opening Players refreshes them without another login.
        });
      } else await connect();
    } catch (error) {
      playerManager.error = `Automatic reconnect could not finish. ${error.message}`;
      paintPlayerManagement();
    }
  })();
  try { await playerAutoReconnect.running; }
  finally {
    playerAutoReconnect.running = null;
    if (playerAutoReconnect.pending) queueAutomaticPlayerConnections();
  }
}

function validPlayerPreview(preview) {
  return Boolean(preview && ['snapshot', 'thumbnail'].includes(preview.kind) && typeof preview.imageDataUrl === 'string' &&
    preview.imageDataUrl.length <= 2 * 1024 * 1024 && /^data:image\/(?:jpeg|png);base64,[A-Za-z0-9+/]+={0,2}$/.test(preview.imageDataUrl) &&
    Number.isFinite(Date.parse(preview.capturedAt)));
}

function playerPreviewHtml(player, locked) {
  const entry = playerManager.previews.get(player.id), preview = entry?.preview;
  const hasImage = validPlayerPreview(preview), online = relayPlayerConnection(player);
  const busy = entry && ['queued', 'loading'].includes(entry.status);
  const label = hasImage ? (preview.kind === 'snapshot' ? 'Playback snapshot' : 'Program thumbnail') : '';
  const time = hasImage ? new Date(preview.capturedAt) : null;
  return `<div class="player-preview${hasImage ? ' has-image' : ''}">
    ${hasImage ? `<img src="${preview.imageDataUrl}" alt="${esc(label)} for ${esc(player.name || player.sn)}" loading="lazy">`
      : `<div class="player-preview-empty"><span class="player-preview-symbol" aria-hidden="true">▧</span><span>${busy ? 'Reading playback preview…' : online ? 'Playback preview' : 'Connect to view playback'}</span></div>`}
    ${busy && hasImage ? '<span class="player-preview-loading">Refreshing…</span>' : ''}
  </div><div class="player-preview-caption"><span>${hasImage ? `<strong>${label}</strong><time datetime="${esc(preview.capturedAt)}" title="${esc(time.toLocaleString())}">${esc(time.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' }))}</time>` : '<span>On-demand preview</span>'}</span>
    <button type="button" class="text-link" data-player-preview="${esc(player.id)}" aria-label="Refresh preview for ${esc(player.name || player.sn)}"${locked || !online ? ' disabled' : ''}>${busy ? 'Reading…' : hasImage ? 'Refresh' : 'Load preview'}</button></div>
    ${preview?.name && hasImage ? `<p class="player-now-playing" title="${esc(preview.name)}">${esc(preview.name)}</p>` : ''}
    ${entry?.error ? `<p class="player-preview-error" role="status">${esc(entry.error)}${hasImage ? ' Showing the previous capture.' : ''}</p>` : ''}`;
}

function relayPlayerConnection(player) {
  if (!player?.connected || !/^[a-f0-9]{32}$/.test(player.connectionId || '') || !player.sn || !player.ip) return null;
  if (player.connectedUntil && (!Number.isFinite(Date.parse(player.connectedUntil)) || Date.parse(player.connectedUntil) <= Date.now())) return null;
  return { id: player.connectionId, device: { sn: player.sn, ip: player.ip, name: player.name || player.sn,
    model: player.model, width: player.width, height: player.height } };
}

// A failed board must not prevent the rest of a multi-board connection batch.
async function runPlayerQueue(items, limit, operation) {
  const results = new Array(items.length);
  let cursor = 0;
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (cursor < items.length) {
      const index = cursor++;
      try { results[index] = { status: 'fulfilled', value: await operation(items[index]) }; }
      catch (reason) { results[index] = { status: 'rejected', reason }; }
    }
  }));
  return results;
}

async function playerJsonRequest(url, options = {}) {
  const controller = new AbortController(), timeout = setTimeout(() => controller.abort(), 20000);
  try {
    const response = await fetch(url, { ...options, cache: 'no-store', signal: controller.signal });
    const body = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(body.error || 'Relay could not complete this player request.');
    return body;
  } catch (error) {
    if (error.name === 'AbortError') throw new Error('The player request timed out. Refresh status before retrying.');
    throw error;
  } finally { clearTimeout(timeout); }
}
async function playerPost(url, payload) {
  try {
    const session = await playerJsonRequest('/api/session');
    return await playerJsonRequest(url, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Studio-Token': session.exportToken }, body: JSON.stringify(payload) });
  } finally { delete payload.playerPassword; }
}

function playerDirectoryHtml() {
  const state = playerManager, locked = playerNetworkBusy();
  const connected = state.players.filter(relayPlayerConnection).length;
  const selected = state.players.filter((p) => state.selected.has(p.id));
  const cards = state.players.map((p) => {
    const activity = state.states.get(p.id), online = relayPlayerConnection(p);
    const status = activity?.status || (online ? 'connected' : p.ip ? 'saved' : 'no-ip');
    const label = ({ connecting: 'Connecting…', queued: 'Queued', failed: 'Connection failed', connected: 'Connected', saved: 'Not connected', 'no-ip': 'No saved IP' })[status] || status;
    return `<article class="player-card${state.selected.has(p.id) ? ' is-selected' : ''}" role="listitem" aria-labelledby="player-card-${esc(p.id)}">
      <header class="player-card-head"><label class="player-card-select"><input type="checkbox" data-player-select="${esc(p.id)}" aria-label="Select ${esc(p.name || p.sn)}"${state.selected.has(p.id) ? ' checked' : ''}${locked ? ' disabled' : ''}><strong id="player-card-${esc(p.id)}">${esc(p.name || p.sn)}</strong></label>
      <span class="player-status player-status-${esc(status)}"><i></i>${esc(label)}</span></header>
      ${playerPreviewHtml(p, locked)}
      <div class="player-card-details"><div><span class="player-ip">${esc(p.ip || 'No saved address')}</span>${state.found.has(p.sn) ? '<span class="player-found">Found</span>' : ''}</div>
      <small>${esc(p.model || 'NovaStar player')}${p.width && p.height ? ` · ${esc(p.width)} × ${esc(p.height)}` : ''}</small>
      ${p.alias && p.deviceName && p.deviceName !== p.alias ? `<small>${esc(p.deviceName)}</small>` : ''}<small class="player-serial">${esc(p.sn)}</small>
      ${activity?.message ? `<p class="player-row-message">${esc(activity.message)}</p>` : ''}</div>
      <footer class="player-card-actions"><button class="btn btn-secondary compact" data-player-connect="${esc(p.id)}"${locked || !p.ip ? ' disabled' : ''}>${online ? 'Reconnect' : 'Connect'}</button>
      <button class="btn btn-secondary compact" data-player-controls="${esc(p.id)}"${locked || !p.ip ? ' disabled' : ''}>Controls</button>
      <button class="text-link" data-player-alias="${esc(p.id)}"${locked ? ' disabled' : ''}>Alias</button>
      <button class="text-link player-forget" data-player-forget="${esc(p.id)}"${locked ? ' disabled' : ''}>Forget</button></footer></article>`;
  }).join('');
  return `<div class="player-directory-head"><div><strong>${connected} connected</strong><span>${state.players.length} saved ${state.players.length === 1 ? 'board' : 'boards'}${selected.length ? ` · ${selected.length} selected` : ''}</span></div>
    <div class="player-bulk-actions"><button class="btn btn-primary compact" data-player-upload${locked || !selected.length ? ' disabled' : ''}>Upload selected</button><button class="btn btn-secondary compact" data-player-bulk-controls${locked || !selected.length ? ' disabled' : ''}>Control selected</button><button class="btn btn-secondary compact" data-player-batch="selected"${locked || !selected.some((p) => p.ip) ? ' disabled' : ''}>Connect selected</button><button class="btn btn-secondary compact" data-player-batch="all"${locked || !state.players.some((p) => p.ip) ? ' disabled' : ''}>Connect all</button>${typeof networkBatchStatusButton === 'function' ? networkBatchStatusButton() : ''}${typeof bulkBoardControlStatusButton === 'function' ? bulkBoardControlStatusButton() : ''}</div></div>
    ${state.error ? `<p class="player-error" role="alert">${esc(state.error)}</p>` : ''}
    <p class="player-message" role="status" aria-live="polite">${esc(state.message || (state.loading ? 'Loading players…' : 'Select boards to connect, change settings, or upload a solution or schedule together.'))}</p>
    <div class="player-grid-toolbar"><label><input type="checkbox" data-player-select-all aria-label="Select all players"${state.players.length && selected.length === state.players.length ? ' checked' : ''}${locked || !state.players.length ? ' disabled' : ''}>Select all</label>
      <div><button class="text-link" data-player-previews${locked || !connected ? ' disabled' : ''}>${state.previewing ? 'Reading previews…' : 'Refresh previews'}</button><button class="text-link player-forget" data-player-forget-all${locked || !state.players.length ? ' disabled' : ''}>Forget all players</button></div></div>
    ${cards ? `<div class="player-grid" role="list" aria-label="Players">${cards}</div>` : `<div class="empty"><p>${state.loaded ? 'No saved players yet.' : 'Loading saved players…'}</p><p>Use Discover players to find boards on your connected Wi-Fi or wired network.</p></div>`}
    <p class="player-footnote">Saved players reconnect automatically when Relay opens using the saved player password. Previews refresh on demand and show their capture time. Aliases stay saved in Relay. Connections are checked for 30 minutes; forgetting players removes them from this list until you discover or add them again.</p>`;
}

function playerManagementPage() {
  return titleArea('Players', 'Find, name and connect the boards you work with.',
    '<button class="btn btn-secondary" data-player-manual>Add by IP</button><button class="btn btn-secondary" data-player-refresh>Refresh status</button><button class="btn btn-primary" data-player-discover>Discover players</button>') +
    `<section class="panel player-directory" data-player-directory>${playerDirectoryHtml()}</section>`;
}
function paintPlayerManagement() {
  const directory = document.querySelector('[data-player-directory]');
  if (!directory) return;
  const focused = document.activeElement && directory.contains(document.activeElement) ? document.activeElement : null;
  const selectedId = focused?.dataset.playerSelect, selectAll = focused?.hasAttribute('data-player-select-all');
  directory.innerHTML = playerDirectoryHtml();
  if (selectedId) [...directory.querySelectorAll('[data-player-select]')].find((input) => input.dataset.playerSelect === selectedId)?.focus({ preventScroll: true });
  else if (selectAll) directory.querySelector('[data-player-select-all]')?.focus({ preventScroll: true });
  for (const button of document.querySelectorAll('[data-player-discover],[data-player-manual]')) button.disabled = playerNetworkBusy();
  const discover = document.querySelector('[data-player-discover]');
  if (discover) discover.textContent = playerManager.discovering ? 'Discovering…' : playerManager.discoveryJobId ? 'Check discovery status' : 'Discover players';
}
async function refreshPlayerManagement() {
  if (playerManager.loading) return playerManager.loading;
  playerManager.loading = (async () => {
    try {
      const result = await playerJsonRequest('/api/network/players');
      playerManager.players = Array.isArray(result.players) ? result.players.filter((p) => p.id && p.sn) : [];
      if (result.discovery?.status === 'complete' && Array.isArray(result.discovery.players)) playerManager.found = new Set(result.discovery.players.map((p) => p.sn));
      playerManager.players.sort((a, b) => Number(Boolean(relayPlayerConnection(b))) - Number(Boolean(relayPlayerConnection(a))) || Number(playerManager.found.has(b.sn)) - Number(playerManager.found.has(a.sn)) || (a.name || a.sn).localeCompare(b.name || b.sn));
      for (const p of playerManager.players) if (relayPlayerConnection(p) && playerManager.states.get(p.id)?.status === 'failed') playerManager.states.delete(p.id);
      if (result.discovery?.status === 'running' && result.discovery.id) playerManager.discoveryJobId = result.discovery.id;
      playerManager.loaded = true;
      playerManager.selected = new Set([...playerManager.selected].filter((id) => playerManager.players.some((p) => p.id === id)));
      for (const id of playerManager.previews.keys()) if (!playerManager.players.some((p) => p.id === id)) playerManager.previews.delete(id);
      return result;
    } finally { playerManager.loading = null; paintPlayerManagement(); }
  })();
  return playerManager.loading;
}
function mountPlayerManagement() {
  if (!document.querySelector('[data-player-directory]')) return;
  paintPlayerManagement();
  void refreshPlayerManagement().catch((error) => { playerManager.error = error.message; paintPlayerManagement(); });
}

async function waitPlayerJob(id, onProgress, timeout = 150000) {
  if (!/^[a-f0-9]{32}$/.test(id || '')) throw new Error('Relay did not return an operation ID. Refresh status before retrying.');
  const deadline = Date.now() + timeout;
  let failures = 0;
  while (Date.now() < deadline) {
    let job;
    try { job = await playerJsonRequest(`/api/network/jobs/${encodeURIComponent(id)}`); failures = 0; }
    catch (error) { if (++failures >= 3) throw error; }
    if (job) {
      onProgress?.(job);
      if (job.status === 'complete') return job;
      if (job.status === 'failed') { const failure = new Error(job.error || job.message || 'The player operation failed.'); failure.jobFailed = true; throw failure; }
    }
    await new Promise((resolve) => setTimeout(resolve, 800));
  }
  throw new Error('The operation is still running. Refresh status before retrying.');
}
async function discoverManagedPlayers() {
  if (playerNetworkBusy()) return;
  playerManager.discovering = true; playerManager.error = ''; playerManager.message = 'Searching the connected local networks…'; paintPlayerManagement();
  try {
    if (!playerManager.discoveryJobId) {
      const started = await playerPost('/api/network/discover', {});
      playerManager.discoveryJobId = started.jobId;
    }
    const result = await waitPlayerJob(playerManager.discoveryJobId, (job) => { playerManager.message = job.message || 'Searching…'; paintPlayerManagement(); });
    playerManager.discoveryJobId = '';
    await refreshPlayerManagement();
    if (Array.isArray(result.players)) {
      playerManager.found = new Set(result.players.map((p) => p.sn));
      playerManager.selected = new Set(playerManager.players.filter((p) => p.ip && playerManager.found.has(p.sn)).map((p) => p.id));
    }
    playerManager.message = (result.message || 'Discovery complete.') + (playerManager.selected.size ? ` ${playerManager.selected.size} found boards selected.` : '');
  } catch (error) { if (error.jobFailed) playerManager.discoveryJobId = ''; playerManager.error = error.message; }
  finally {
    playerManager.discovering = false; paintPlayerManagement();
    if (playerAutoReconnect.started && !playerManager.discoveryJobId) queueAutomaticPlayerConnections();
  }
}

async function connectManagedPlayers(players, password, options = {}) {
  if (playerNetworkBusy() || !players.length) return;
  playerManager.batch = true; playerManager.error = '';
  for (const p of players) playerManager.states.set(p.id, { status: 'queued' });
  playerManager.message = `${options.automatic ? 'Automatically connecting' : 'Connecting'} ${players.length} ${players.length === 1 ? 'board' : 'boards'}…`; paintPlayerManagement();
  try {
    const results = await runPlayerQueue(players, 3, async (p) => {
      if (options.canStart && !options.canStart()) {
        if (playerManager.states.get(p.id)?.status === 'queued') playerManager.states.delete(p.id);
        return { skipped: true };
      }
      options.onAttempt?.(p);
      playerManager.states.set(p.id, { status: 'connecting' }); paintPlayerManagement();
      try {
        const started = await playerPost('/api/network/check', { ip: p.ip, ...(p.sn ? { expectedSn: p.sn } : {}), playerPassword: password });
        const result = await waitPlayerJob(started.jobId, (job) => { playerManager.states.set(p.id, { status: 'connecting', message: job.message }); paintPlayerManagement(); });
        if (!result.connectionId || !result.device?.sn || result.device.ip !== p.ip || (p.sn && result.device.sn !== p.sn)) throw new Error('The player identity did not match. Check its address.');
        playerManager.states.delete(p.id);
        await refreshPlayerManagement();
        return result;
      } catch (error) { playerManager.states.set(p.id, { status: 'failed', message: error.message }); if (!p.sn) playerManager.error = `${p.ip}: ${error.message}`; paintPlayerManagement(); throw error; }
    });
    const succeeded = results.filter((r) => r.status === 'fulfilled' && !r.value?.skipped).length;
    const failed = results.filter((r) => r.status === 'rejected').length;
    const skipped = results.length - succeeded - failed;
    playerManager.message = `${options.automatic ? 'Automatic reconnect: ' : ''}${succeeded} connected${failed ? ` · ${failed} failed; see each board for details` : ''}${skipped ? ` · ${skipped} waiting` : ''}.`;
    await refreshPlayerManagement();
    playerConnectionChannel?.postMessage({ type: 'connections-updated' });
    if (options.automatic && !skipped && typeof notice === 'function') notice(playerManager.message);
    return results;
  } catch (error) { playerManager.error = error.message; }
  finally { password = ''; playerManager.batch = false; paintPlayerManagement(); }
}
async function requestManagedConnections(players) {
  try {
    const password = await loadStudioDefaultPlayerPassword();
    if (password) { await connectManagedPlayers(players, password); return; }
    openDialog({ title: 'Connect players', subtitle: `Enter the shared password for ${players.length} ${players.length === 1 ? 'board' : 'boards'}.`,
      body: '<label class="field">Player password<input name="playerPassword" type="text" spellcheck="false" autocapitalize="none" autocomplete="off" maxlength="256" required autofocus></label>', submitLabel: 'Connect',
      onSubmit(form) { const value = form.elements.playerPassword.value; form.elements.playerPassword.value = ''; void connectManagedPlayers(players, value); } });
  } catch (error) { playerManager.error = error.message; paintPlayerManagement(); }
}
function addManagedPlayer() {
  const form = openDialog({ title: 'Add player by IP', subtitle: 'Connect to verify the board and save its address in Relay.',
    body: '<div class="form-grid"><label class="field">IP address<input name="ip" placeholder="192.168.1.24" inputmode="decimal" autocomplete="off" required autofocus></label><label class="field">Player password<input name="playerPassword" type="text" spellcheck="false" autocapitalize="none" autocomplete="off" maxlength="256" required></label></div>', submitLabel: 'Connect',
    onSubmit(form) {
      const ip = form.elements.ip.value.trim(), password = form.elements.playerPassword.value;
      if (!/^(?:\d{1,3}\.){3}\d{1,3}$/.test(ip) || ip.split('.').some((v) => +v > 255)) throw new Error('Enter a valid IPv4 address.');
      form.elements.playerPassword.value = '';
      void connectManagedPlayers([{ id: `manual-${ip}`, ip }], password);
    } });
  void applyDefaultPlayerPassword(form.elements.playerPassword).catch(() => {});
}
function aliasManagedPlayer(player) {
  openDialog({ title: 'Name this board', subtitle: `${player.ip || 'No saved IP'} · ${player.sn}`,
    body: `<label class="field">Alias<input name="alias" value="${esc(player.alias || '')}" placeholder="e.g. Lobby left" maxlength="100" autofocus></label><p class="field-help">This name appears throughout Relay. Leave it blank to use the board's own name.</p>`, submitLabel: 'Save alias',
    async onSubmit(form) { await playerPost('/api/network/player', { action: 'alias', sn: player.sn, alias: form.elements.alias.value.trim() }); await refreshPlayerManagement(); notice('Board alias saved'); } });
}
async function refreshManagedPreviews(players, password) {
  if (playerNetworkBusy()) return;
  const eligible = players.filter(relayPlayerConnection);
  if (!eligible.length) { playerManager.error = 'Connect the boards before loading playback previews.'; paintPlayerManagement(); return; }
  if (!password) { playerManager.error = 'Enter the player password to load previews.'; paintPlayerManagement(); return; }
  playerManager.previewing = true; playerManager.error = '';
  const requests = eligible.map((player) => {
    const entry = { status: 'queued', preview: playerManager.previews.get(player.id)?.preview };
    playerManager.previews.set(player.id, entry);
    return { player, entry, connection: relayPlayerConnection(player) };
  });
  playerManager.message = `Reading ${requests.length} playback ${requests.length === 1 ? 'preview' : 'previews'}…`; paintPlayerManagement();
  try {
    const results = await runPlayerQueue(requests, 2, async ({ player, entry, connection }) => {
      const current = () => playerManager.previews.get(player.id) === entry && playerManager.players.some((p) => p.sn === player.sn && p.ip === player.ip);
      if (!current()) return;
      try {
        if (typeof isNetworkBatchBusy === 'function' && isNetworkBatchBusy()) throw new Error('An upload is running. Refresh this preview when it finishes.');
        entry.status = 'loading'; paintPlayerManagement();
        const started = await playerPost('/api/network/preview', { connectionId: connection.id, playerPassword: password });
        const result = await waitPlayerJob(started.jobId, undefined, 90000);
        if (!validPlayerPreview(result.preview)) throw new Error(result.preview?.message || 'The board did not return a readable playback preview.');
        if (!current()) return;
        entry.preview = result.preview; entry.status = 'ready'; entry.error = ''; paintPlayerManagement();
        return result.preview;
      } catch (error) {
        if (current()) { entry.status = 'failed'; entry.error = error.message; paintPlayerManagement(); }
        throw error;
      }
    });
    const count = results.filter((result) => result.status === 'fulfilled' && result.value).length;
    playerManager.message = `${count} of ${requests.length} playback previews refreshed.`;
  } finally { password = ''; playerManager.previewing = false; paintPlayerManagement(); }
}

async function requestManagedPreviews(players) {
  if (playerNetworkBusy()) return;
  const eligible = players.filter(relayPlayerConnection);
  if (!eligible.length) return;
  try {
    const password = await loadStudioDefaultPlayerPassword();
    if (password) { await refreshManagedPreviews(eligible, password); return; }
    openDialog({ title: 'Load playback previews', subtitle: `Read the current playback from ${eligible.length} ${eligible.length === 1 ? 'board' : 'boards'}.`,
      body: '<label class="field">Player password<input name="playerPassword" type="text" spellcheck="false" autocapitalize="none" autocomplete="off" maxlength="256" required autofocus></label>', submitLabel: 'Load previews',
      onSubmit(form) { const value = form.elements.playerPassword.value; form.elements.playerPassword.value = ''; void refreshManagedPreviews(eligible, value); } });
  } catch (error) { playerManager.error = error.message; paintPlayerManagement(); }
}

function forgetManagedPlayers(player = null) {
  const count = player ? 1 : playerManager.players.length;
  openDialog({ title: player ? 'Forget this board?' : 'Forget all players?',
    body: `<p class="dialog-copy">${player ? `Remove <strong>${esc(player.name || player.sn)}</strong> from Relay's player list?` : `Remove all <strong>${count} saved players</strong> from Relay's player list?`} Discovery can add them again, with their saved aliases.</p>`,
    submitLabel: player ? 'Forget board' : `Forget all ${count} players`,
    async onSubmit() {
      await playerPost('/api/network/player', { action: player ? 'forget' : 'forget-all', ...(player ? { sn: player.sn } : {}) });
      if (player) { playerManager.states.delete(player.id); playerManager.selected.delete(player.id); playerManager.previews.delete(player.id); playerManager.found.delete(player.sn); }
      else { playerManager.states.clear(); playerManager.selected.clear(); playerManager.previews.clear(); playerManager.found.clear(); }
      await refreshPlayerManagement(); notice(player ? 'Board forgotten' : 'All players forgotten');
    } });
}

document.addEventListener('change', (event) => {
  const target = event.target;
  if (target.matches('[data-player-select]')) {
    if (target.checked) playerManager.selected.add(target.dataset.playerSelect); else playerManager.selected.delete(target.dataset.playerSelect);
    paintPlayerManagement();
  } else if (target.matches('[data-player-select-all]')) {
    playerManager.selected = new Set(target.checked ? playerManager.players.map((p) => p.id) : []); paintPlayerManagement();
  }
});
document.addEventListener('click', (event) => {
  const button = event.target.closest('button');
  if (!button || button.disabled || button.closest('dialog')) return;
  const d = button.dataset, find = (id) => playerManager.players.find((p) => p.id === id);
  if ('playerDiscover' in d) void discoverManagedPlayers();
  else if ('playerRefresh' in d) { playerManager.error = ''; void refreshPlayerManagement().catch((error) => { playerManager.error = error.message; paintPlayerManagement(); }); }
  else if ('playerManual' in d) addManagedPlayer();
  else if ('playerUpload' in d) openNetworkBatch(playerManager.players.filter((p) => playerManager.selected.has(p.id)));
  else if ('playerBulkControls' in d) openBulkBoardControls(playerManager.players.filter((p) => playerManager.selected.has(p.id)));
  else if ('playerConnect' in d) { const p = find(d.playerConnect); if (p) void requestManagedConnections([p]); }
  else if ('playerBatch' in d) void requestManagedConnections(playerManager.players.filter((p) => p.ip && (d.playerBatch === 'all' || playerManager.selected.has(p.id))));
  else if ('playerControls' in d) { const p = find(d.playerControls); if (p) openBoardControls(p); }
  else if ('playerAlias' in d) { const p = find(d.playerAlias); if (p) aliasManagedPlayer(p); }
  else if ('playerPreview' in d) { const p = find(d.playerPreview); if (p) void requestManagedPreviews([p]); }
  else if ('playerPreviews' in d) void requestManagedPreviews(playerManager.players);
  else if ('playerForget' in d) { const p = find(d.playerForget); if (p) forgetManagedPlayers(p); }
  else if ('playerForgetAll' in d) forgetManagedPlayers();
});

document.addEventListener('DOMContentLoaded', () => {
  if (playerAutoReconnect.started) return;
  playerAutoReconnect.started = true;
  queueAutomaticPlayerConnections();
});
document.addEventListener('studio-player-password-saved', () => {
  if (playerAutoReconnect.started) queueAutomaticPlayerConnections(true);
});
