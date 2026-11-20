'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { webcrypto } = require('node:crypto');
const source = fs.readFileSync(require('node:path').join(__dirname, 'network-batch.js'), 'utf8');
const htmlEscape = (value) => String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const checked = (id) => ({ id, sn: id, name: id, ip: '192.168.8.106', connected: true, connectionId: id.padStart(32, 'a') });
const snapshot = () => ({ requestId: 'a'.repeat(32), programType: 'solution', programId: 'solution1', targets: [{ connectionId: 'b'.repeat(32) }], project: { version: 1, screens: [], solutions: [], cues: [] } });
function sandbox(extra = {}) {
  const storage = new Map(), timeouts = [];
  const c = vm.createContext({ console, Date, Set, crypto: webcrypto, AbortController,
    setTimeout(fn, delay) { timeouts.push({ fn, delay }); return timeouts.length; }, clearTimeout() {},
    sessionStorage: { getItem: (key) => storage.get(key), setItem: (key, value) => storage.set(key, value) },
    document: { addEventListener() {}, querySelector() { return null; } }, esc: htmlEscape, paintPlayerManagement() {},
    relayPlayerConnection: (p) => p?.connected && p?.connectionId ? { id: p.connectionId } : null,
    project: { solutions: [{ id: 'solution1', name: 'Lobby', width: 1920, height: 1080, source: { kind: 'localImage' } }, { id: 'missing', name: 'Gone', missing: true }],
      screens: [{ id: 'lane1', name: 'Doors', width: 320, height: 1080 }, { id: 'empty', name: 'Empty lane' }], cues: [{ screenId: 'lane1', enabled: true }] },
    M: { cueHasOccurrences: (cue) => cue.enabled !== false }, canUsbPlaybackSolution: (item) => !item.missing,
    ...extra });
  vm.runInContext(source, c);
  return { c, storage, timeouts, state: () => vm.runInContext('networkBatchState', c) };
}
async function settle() { for (let n = 0; n < 12; n++) await new Promise((resolve) => setImmediate(resolve)); }

test('batch selection requires every checked board and never silently skips an offline recipient', () => {
  const { c } = sandbox(), players = [checked('SN1'), checked('SN2'), { ...checked('SN3'), connected: false }];
  assert.equal(c.networkBatchTargets(players, new Set(['SN1', 'SN2'])).length, 2);
  assert.throws(() => c.networkBatchTargets(players, new Set(['SN1', 'SN3'])), /Connect every selected board/);
  assert.throws(() => c.networkBatchTargets(players, new Set(['SN1', 'missing'])), /Connect every selected board/);
  assert.throws(() => c.networkBatchTargets(players, new Set()), /Select at least one/);
});

test('single and multiple upload entry points wait while bulk board controls are running', () => {
  const notices = [];
  const { c } = sandbox({ isBulkBoardControlBusy: () => true, notice: message => notices.push(message),
    openDialog() { assert.fail('An upload dialog opened during bulk controls.'); } });
  vm.runInContext(fs.readFileSync(require('node:path').join(__dirname, 'network-playback.js'), 'utf8'), c);
  c.openNetworkBatch([checked('SN1')]);
  c.openNetworkPlayback('solution1');
  assert.equal(notices.length, 2);
  assert.ok(notices.every(message => /Wait for the board controls/.test(message)));
});

test('content picker contains playable solutions and only schedules with blocks', () => {
  const { c } = sandbox();
  assert.deepEqual(Array.from(c.networkBatchPrograms('solution'), (p) => p.id), ['solution1']);
  assert.deepEqual(Array.from(c.networkBatchPrograms('schedule'), (p) => p.id), ['lane1']);
  assert.equal(c.networkBatchPrograms('solution', 'lob').length, 1);
  assert.equal(c.networkBatchPrograms('solution', 'nomatch').length, 0);
});

test('single and multiple upload entry points wait for automatic connection checks', () => {
  const notices = [];
  const { c } = sandbox({ isAutomaticPlayerReconnectBusy: () => true, notice: message => notices.push(message),
    openDialog() { assert.fail('An upload dialog opened during automatic reconnection.'); } });
  vm.runInContext(fs.readFileSync(require('node:path').join(__dirname, 'network-playback.js'), 'utf8'), c);
  c.openNetworkBatch([checked('SN1')]);
  c.openNetworkPlayback('solution1');
  assert.equal(notices.length, 2);
  assert.ok(notices.every(message => /reconnecting saved players/.test(message)));
});

test('a multi-board request posts one immutable snapshot and stores only tracking IDs', async () => {
  const f = sandbox(), sent = [], batchId = 'c'.repeat(32), request = snapshot();
  f.c.networkBatchRequest = async (url, options = {}) => {
    if (url === '/api/session') return { exportToken: 'fixture-token' };
    if (options.method === 'POST') { sent.push(JSON.parse(options.body)); return { batchId }; }
    return { id: batchId, requestId: request.requestId, status: 'complete', targets: [], progress: 100, name: 'Lobby' };
  };
  assert.equal(await f.c.sendNetworkBatchSnapshot(request, 'fixture-password'), true);
  await settle();
  assert.equal(sent.length, 1);
  assert.equal(sent[0].playerPassword, 'fixture-password');
  assert.equal(sent[0].requestId, request.requestId);
  assert.deepEqual(sent[0].targets, request.targets);
  assert.equal('playerPassword' in request, false);
  const stored = f.storage.get('relay-network-batch');
  assert.deepEqual(Object.keys(JSON.parse(stored)).sort(), ['id', 'requestId']);
  assert.ok(!stored.includes('fixture-password'));
  assert.equal(f.state().pending, null);
  assert.equal(f.state().snapshot.status, 'complete');
});

test('a lost POST reply is recovered by request ID without submitting again', async () => {
  const f = sandbox(), request = snapshot(), batchId = 'd'.repeat(32); let posts = 0;
  f.c.networkBatchRequest = async (url, options = {}) => {
    if (url === '/api/session') return { exportToken: 'fixture' };
    if (options.method === 'POST') { posts++; throw new Error('Connection lost'); }
    if (url === '/api/network/batches') return { batches: [{ id: batchId, requestId: request.requestId, status: 'running' }] };
    return { id: batchId, requestId: request.requestId, status: 'complete', targets: [], progress: 100 };
  };
  assert.equal(await f.c.sendNetworkBatchSnapshot(request, 'fixture-password'), false);
  await settle();
  assert.equal(posts, 1);
  assert.equal(f.state().id, batchId);
  assert.equal(f.state().pending, null);
  assert.equal(f.state().error, '');
});

test('an uncertain unaccepted request retains its original content for an idempotent retry', async () => {
  const f = sandbox(), request = snapshot();
  f.c.networkBatchRequest = async (url, options = {}) => {
    if (url === '/api/session') return { exportToken: 'fixture' };
    if (options.method === 'POST') throw new Error('No response');
    return { batches: [] };
  };
  await f.c.sendNetworkBatchSnapshot(request, 'fixture-password'); await settle();
  assert.equal(f.state().pending, request);
  assert.equal(f.state().requestId, request.requestId);
  assert.equal(f.c.isNetworkBatchBusy(), true);
  assert.match(f.state().error, /not confirmed/);
  assert.ok(!JSON.stringify(f.state()).includes('fixture-password'));
});

test('definitive validation failure clears the pending request and retains no password', async () => {
  const f = sandbox(), request = snapshot();
  f.c.networkBatchRequest = async (url) => {
    if (url === '/api/session') return { exportToken: 'fixture' };
    const failure = new Error('Connect selected boards first'); failure.httpStatus = 422; throw failure;
  };
  await assert.rejects(f.c.sendNetworkBatchSnapshot(request, 'fixture-password'), /Connect selected boards/);
  assert.equal(f.state().pending, null);
  assert.equal(f.state().requestId, '');
  assert.equal(f.c.isNetworkBatchBusy(), false);
  assert.ok(!JSON.stringify(f.state()).includes('fixture-password'));
});

test('progress distinguishes partial failures and escapes board-provided text', () => {
  const { c } = sandbox();
  const html = c.networkBatchReceiptHtml({ name: '<img src=x>', status: 'partial', progress: 110, targets: [
    { name: 'Left', sn: 'SN1', ip: '192.168.8.106', status: 'complete', message: 'Done' },
    { name: 'Right', sn: 'SN2', ip: '192.168.8.118', status: 'failed', error: '<script>bad</script>' }] });
  assert.match(html, /Complete/); assert.match(html, /Failed/); assert.match(html, /value="100"/);
  assert.ok(html.includes('&lt;img src=x&gt;')); assert.ok(html.includes('&lt;script&gt;bad&lt;/script&gt;'));
  assert.ok(!html.includes('<script>'));
});

test('an old status response cannot overwrite a newer upload', async () => {
  const f = sandbox(); let release;
  vm.runInContext("networkBatchState.id = 'a'.repeat(32)", f.c);
  f.c.networkBatchRequest = () => new Promise((resolve) => { release = resolve; });
  const polling = f.c.refreshNetworkBatchStatus();
  vm.runInContext("networkBatchState.generation++; networkBatchState.id = 'b'.repeat(32); networkBatchState.snapshot = null", f.c);
  release({ id: 'a'.repeat(32), status: 'complete', targets: [] }); await polling;
  assert.equal(f.state().id, 'b'.repeat(32));
  assert.equal(f.state().snapshot, null);
  assert.ok(f.timeouts.some((item) => item.delay === 1200));
});

test('the upload dialog preserves actual saved-password autofill through a single multi-board submit', async () => {
  const nodes = new Map();
  const node = () => ({ value: '', innerHTML: '', textContent: '', disabled: false, hidden: false, isConnected: true,
    dispatchEvent(event) { this[`on${event.type}`]?.(event); } });
  const get = (selector) => { if (!nodes.has(selector)) nodes.set(selector, node()); return nodes.get(selector); };
  const elements = { programType: node(), programSearch: node(), programId: node(), playerPassword: node() };
  const form = { elements, querySelector: get, querySelectorAll() { return []; }, addEventListener() {} };
  const dialog = { open: true, contains(item) { return item === form; }, addEventListener() {}, removeEventListener() {} };
  let definition, posted, openedStatus = 0;
  const f = sandbox({ Event, $: () => dialog, openDialog(value) { definition = value; return form; } });
  vm.runInContext(fs.readFileSync(require('node:path').join(__dirname, 'settings.js'), 'utf8'), f.c);
  f.c.studioSettingsPost = async (url) => {
    assert.equal(url, '/api/settings/player-password/read');
    return { password: 'fixture-password' };
  };
  f.c.networkBatchRequest = async () => ({ players: [checked('SN1'), checked('SN2')] });
  f.c.sendNetworkBatchSnapshot = async (payload, password) => { posted = { payload, password }; return true; };
  f.c.openNetworkBatchStatus = () => { openedStatus++; };
  f.c.openNetworkBatch([checked('SN1'), checked('SN2')], { programType: 'solution', programId: 'solution1' });
  await settle();
  assert.match(definition.body, /Find content/);
  assert.match(nodes.get('[data-batch-player-picks]').innerHTML, /SN1/);
  assert.equal(nodes.get('[type=submit]').disabled, false);
  assert.equal(nodes.get('[type=submit]').textContent, 'Upload and play on 2 boards');
  await form.onsubmit({ preventDefault() {} });
  assert.equal(posted.payload.programId, 'solution1');
  assert.equal(posted.payload.targets.length, 2);
  assert.match(posted.payload.requestId, /^[a-f0-9]{32}$/);
  assert.equal(posted.password, 'fixture-password');
  assert.equal(elements.playerPassword.value, '');
  assert.equal(openedStatus, 1);
});
