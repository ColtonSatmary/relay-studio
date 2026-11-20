'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function fixture(kind) {
  const nodes = new Map(), calls = [];
  function element() {
    return { value: '', disabled: false, hidden: false, isConnected: true, innerHTML: '', textContent: '',
      addEventListener() {}, removeEventListener() {}, setAttribute() {}, removeAttribute() {}, hasAttribute() { return false; },
      dispatchEvent(event) { this[`on${event.type}`]?.(event); },
      querySelector(selector) { return selector.includes('mosaicEnable') ? null : get(selector); }, querySelectorAll() { return []; },
      classList: { add() {}, remove() {}, toggle() {} } };
  }
  function get(selector) { if (!nodes.has(selector)) nodes.set(selector, element()); return nodes.get(selector); }
  const inputs = { player: element(), ip: element(), playerPassword: element() };
  const form = { ...element(), elements: inputs, querySelector: get, querySelectorAll(selector) {
    return selector === 'input,select' || selector.startsWith('.board-connection') ? Object.values(inputs) : [];
  } };
  const dialog = { ...element(), open: true, contains(value) { return value === form; } };
  const player = { id: 'SN7', sn: 'SN7', ip: '192.168.8.106', name: 'Left board', width: 320, height: 1080, connected: true,
    connectionId: 'a'.repeat(32), connectedUntil: new Date(Date.now() + 60000).toISOString() };
  const c = vm.createContext({ document: { addEventListener() {}, querySelector() { return null; }, querySelectorAll() { return []; } },
    setTimeout, clearTimeout, AbortController, Date, Event, esc: String, icon() { return ''; }, $() { return dialog; }, openDialog() { return form; },
    getSolution() { return { id: 'solution', name: 'Test', width: 1920, height: 1080 }; }, canUsbPlaybackSolution() { return true; },
    fetch: async (url, options = {}) => {
      calls.push({ url, payload: options.body ? JSON.parse(options.body) : null });
      const body = url === '/api/network/players' ? { players: [player], supported: true }
        : url === '/api/session' ? { exportToken: 'fixture' }
        : url === '/api/network/controls/read' ? { jobId: 'b'.repeat(32) }
        : url.startsWith('/api/network/jobs/') ? { status: 'complete', controls: {} }
        : (() => { throw new Error(`Unexpected request ${url}`); })();
      return { ok: true, async json() { return body; } };
    }, notice() {} });
  for (const file of ['settings.js', 'player-management.js', kind === 'controls' ? 'board-controls.js' : 'network-playback.js']) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, file), 'utf8'), c);
  }
  c.loadStudioDefaultPlayerPassword = async () => 'fixture-password';
  return { c, calls, form, inputs, nodes, player, dialog };
}
async function settle() { for (let n = 0; n < 20; n++) await new Promise((resolve) => setImmediate(resolve)); }

test('seeded controls reuse connection after default password emits input, then manual edits clear it', async () => {
  const f = fixture('controls');
  f.c.openBoardControls(f.player);
  await settle();
  assert.equal(f.inputs.playerPassword.value, 'fixture-password');
  assert.equal(f.calls.filter((c) => c.url === '/api/network/check').length, 0);
  const reads = f.calls.filter((c) => c.url === '/api/network/controls/read');
  assert.equal(reads.length, 1);
  assert.equal(reads[0].payload.connectionId, f.player.connectionId);
  f.inputs.playerPassword.value = 'changed-by-operator';
  f.inputs.playerPassword.dispatchEvent(new Event('input'));
  assert.equal(f.nodes.get('[data-board-refresh]').disabled, true);
});

test('Send reuses selected connection after autofill and clears it on manual password input', async () => {
  const f = fixture('send');
  f.c.openNetworkPlayback('solution');
  await settle();
  f.inputs.player.value = f.player.id;
  await f.inputs.player.onchange();
  assert.equal(f.inputs.playerPassword.value, 'fixture-password');
  assert.equal(f.nodes.get('[type=submit]').disabled, false);
  assert.equal(f.calls.filter((c) => c.url === '/api/network/check').length, 0);
  f.inputs.playerPassword.value = 'changed-by-operator';
  f.inputs.playerPassword.dispatchEvent(new Event('input'));
  assert.equal(f.nodes.get('[type=submit]').disabled, true);
});

test('an IP edited while autofill is pending cannot restore the previous selected connection', async () => {
  const f = fixture('send');
  f.c.openNetworkPlayback('solution');
  await settle();
  let release;
  f.c.loadStudioDefaultPlayerPassword = () => new Promise((resolve) => { release = resolve; });
  f.inputs.player.value = f.player.id;
  const changing = f.inputs.player.onchange();
  f.inputs.ip.value = '192.168.8.200'; f.inputs.ip.oninput();
  release('fixture-password'); await changing;
  assert.equal(f.nodes.get('[type=submit]').disabled, true);
});

test('a password typed during autofill is preserved and does not restore the cached connection', async () => {
  const f = fixture('send');
  f.c.openNetworkPlayback('solution');
  await settle();
  let release;
  f.c.loadStudioDefaultPlayerPassword = () => new Promise((resolve) => { release = resolve; });
  f.inputs.player.value = f.player.id;
  const changing = f.inputs.player.onchange();
  f.inputs.playerPassword.value = 'operator-password'; f.inputs.playerPassword.dispatchEvent(new Event('input'));
  release('fixture-password'); await changing;
  assert.equal(f.inputs.playerPassword.value, 'operator-password');
  assert.equal(f.nodes.get('[type=submit]').disabled, true);
});
