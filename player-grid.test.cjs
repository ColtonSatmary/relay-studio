'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, 'player-management.js'), 'utf8');
const escape = (value) => String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
function sandbox(extra = {}) {
  const events = {};
  const c = vm.createContext({ document: { addEventListener(type, callback) { events[type] = callback; }, querySelector() { return null; }, querySelectorAll() { return []; } },
    setTimeout, clearTimeout, AbortController, Date, esc: escape, notice() {}, ...extra });
  vm.runInContext(source, c);
  c.events = events;
  return c;
}
const checked = (n) => ({ id: `BOARD-${n}`, sn: `BOARD-${n}`, name: `Board ${n}`, ip: `192.168.8.${n}`, connected: true,
  connectionId: n.toString(16).padStart(32, '0'), connectedUntil: new Date(Date.now() + 60000).toISOString() });
const preview = (extra = {}) => ({ imageDataUrl: 'data:image/jpeg;base64,/9j/AA==', kind: 'snapshot', capturedAt: new Date().toISOString(), width: 142, height: 480, ...extra });
function click(c, dataset) {
  const button = { dataset, disabled: false, closest() { return null; } };
  c.events.click({ target: { closest() { return button; } } });
}

test('grid selection includes explicit recipients and keeps boards without an address selectable', () => {
  let recipients;
  const c = sandbox({ fixtures: [checked(1), { ...checked(2), connected: false, ip: '' }], openNetworkBatch(players) { recipients = players; } });
  vm.runInContext('playerManager.players = fixtures', c);
  c.events.change({ target: { checked: true, matches(selector) { return selector === '[data-player-select-all]'; } } });
  click(c, { playerUpload: '' });
  assert.equal(recipients.length, 2);
  assert.equal(recipients[1].ip, '');
  const html = c.playerDirectoryHtml();
  assert.match(html, /role="list" aria-label="Players"/);
  assert.equal((html.match(/role="listitem"/g) || []).length, 2);
  assert.ok(!html.includes('<table'));
  assert.match(html, /Forget all players/);
  assert.ok(!html.includes('Clear IP'));
  assert.ok(!html.includes('Clear saved IPs'));
  assert.match(html, /2 selected/);
  assert.match(html, /aria-label="Select Board 2" checked>/);
});

test('forget all describes the affected count and only submits after the form action', async () => {
  let dialog, calls = [];
  const c = sandbox({ fixtures: [checked(1), checked(2)], openDialog(options) { dialog = options; } });
  vm.runInContext("playerManager.players = fixtures; playerManager.selected.add('BOARD-1'); playerManager.previews.set('BOARD-1', {status:'ready'}); playerManager.states.set('BOARD-1', {status:'failed'})", c);
  c.playerPost = async (url, payload) => { calls.push({ url, payload }); return {}; };
  c.playerJsonRequest = async () => ({ players: [] });
  click(c, { playerForgetAll: '' });
  assert.match(dialog.body, /2 saved players/);
  assert.equal(dialog.submitLabel, 'Forget all 2 players');
  assert.equal(calls.length, 0);
  await dialog.onSubmit();
  assert.equal(calls.length, 1);
  assert.equal(calls[0].payload.action, 'forget-all');
  assert.equal(vm.runInContext('playerManager.players.length + playerManager.selected.size + playerManager.previews.size + playerManager.states.size', c), 0);
});

test('bulk controls receive the selected recipients and lock conflicting player actions', () => {
  let recipients;
  const c = sandbox({ fixtures: [checked(1), checked(2)], openBulkBoardControls(players) { recipients = players; } });
  vm.runInContext("playerManager.players = fixtures; playerManager.selected.add('BOARD-2')", c);
  click(c, { playerBulkControls: '' });
  assert.deepEqual(Array.from(recipients, (p) => p.id), ['BOARD-2']);
  c.isBulkBoardControlBusy = () => true;
  assert.equal(c.playerNetworkBusy(), true);
  assert.match(c.playerDirectoryHtml(), /data-player-upload disabled/);
  assert.match(c.playerDirectoryHtml(), /data-player-bulk-controls disabled/);
  assert.match(c.playerDirectoryHtml(), /data-player-forget-all disabled/);
});

test('preview reads have two workers, keep successful boards, and preserve an older capture on failure', async () => {
  const fixtures = [checked(1), checked(2), checked(3), checked(4), { ...checked(5), connected: false }];
  const old = preview({ capturedAt: '2026-11-18T10:00:00Z' });
  const c = sandbox({ fixtures, old });
  vm.runInContext("playerManager.players = fixtures; playerManager.previews.set('BOARD-2', {status:'ready',preview:old})", c);
  const posts = []; let active = 0, peak = 0;
  c.playerPost = async (url, payload) => {
    assert.equal(url, '/api/network/preview'); assert.equal(payload.playerPassword, 'fixture-password');
    posts.push(payload); return { jobId: payload.connectionId };
  };
  c.waitPlayerJob = async (id) => {
    active++; peak = Math.max(peak, active);
    await new Promise((resolve) => setTimeout(resolve, 5)); active--;
    if (id === checked(2).connectionId) throw new Error('Snapshot not supported');
    return { preview: preview() };
  };
  await c.refreshManagedPreviews(fixtures, 'fixture-password');
  assert.equal(posts.length, 4); assert.equal(peak, 2);
  assert.equal(vm.runInContext("playerManager.previews.get('BOARD-1').status", c), 'ready');
  assert.equal(vm.runInContext("playerManager.previews.get('BOARD-2').preview.capturedAt", c), old.capturedAt);
  assert.equal(vm.runInContext("playerManager.previews.get('BOARD-2').error", c), 'Snapshot not supported');
  assert.equal(vm.runInContext('playerManager.previewing', c), false);
  assert.match(vm.runInContext('playerManager.message', c), /3 of 4/);
  assert.match(c.playerDirectoryHtml(), /Showing the previous capture/);
});

test('late preview results cannot restore a forgotten player or its cached image', async () => {
  let release, started;
  const waiting = new Promise((resolve) => { release = resolve; });
  const posted = new Promise((resolve) => { started = resolve; });
  const c = sandbox({ fixtures: [checked(1)] });
  vm.runInContext('playerManager.players = fixtures', c);
  c.playerPost = async () => { started(); return { jobId: checked(1).connectionId }; };
  c.waitPlayerJob = async () => waiting;
  c.playerJsonRequest = async () => ({ players: [] });
  const work = c.refreshManagedPreviews([checked(1)], 'fixture');
  await posted;
  await c.refreshPlayerManagement();
  release({ preview: preview() });
  await work;
  assert.equal(vm.runInContext('playerManager.players.length', c), 0);
  assert.equal(vm.runInContext('playerManager.previews.size', c), 0);
});

test('preview image sources are bounded and captions distinguish captures from thumbnails', () => {
  const c = sandbox({ fixture: checked(1), snap: preview(), thumb: preview({ kind: 'thumbnail', name: '<img src=x>' }) });
  for (const invalid of [preview({ imageDataUrl: 'https://board/private?password=secret' }), preview({ imageDataUrl: 'data:image/svg+xml;base64,PHN2Zz4=' }),
    preview({ imageDataUrl: 'data:image/jpeg;base64,AA==" onerror="alert(1)' }), preview({ capturedAt: 'invalid' }),
    preview({ imageDataUrl: 'data:image/jpeg;base64,' + 'A'.repeat(2 * 1024 * 1024) })]) assert.equal(c.validPlayerPreview(invalid), false);
  vm.runInContext("playerManager.players=[fixture]; playerManager.previews.set(fixture.id,{status:'ready',preview:snap})", c);
  assert.match(c.playerDirectoryHtml(), /Playback snapshot/);
  assert.match(c.playerDirectoryHtml(), /<time datetime=/);
  vm.runInContext("playerManager.previews.set(fixture.id,{status:'ready',preview:thumb})", c);
  const html = c.playerDirectoryHtml();
  assert.match(html, /Program thumbnail/); assert.ok(!html.includes('Playback snapshot'));
  assert.match(html, /&lt;img src=x&gt;/); assert.ok(!html.includes('<img src=x>'));
});

test('an active upload blocks preview work without sending another operation', async () => {
  const c = sandbox({ fixtures: [checked(1)], isNetworkBatchBusy() { return true; } });
  vm.runInContext('playerManager.players = fixtures', c);
  c.playerPost = async () => { throw new Error('Preview request should not be sent'); };
  await c.refreshManagedPreviews([checked(1)], 'fixture');
  assert.equal(vm.runInContext('playerManager.previews.size', c), 0);
  assert.match(c.playerDirectoryHtml(), /data-player-previews disabled/);
});
