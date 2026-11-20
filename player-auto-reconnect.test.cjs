'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, 'player-management.js'), 'utf8');
const player = (n, connected = false) => ({ id: `SN${n}`, sn: `SN${n}`, name: `Board ${n}`, ip: `192.168.8.${n}`,
  connected, connectionId: n.toString(16).padStart(32, '0'), connectedUntil: new Date(Date.now() + 60000).toISOString() });
function fixture(players, extra = {}) {
  const timers = [], listeners = new Map(), posted = [], jobs = new Map();
  let password = 'saved-fixture-password', dialogOpen = false, active = 0, peak = 0;
  const c = vm.createContext({
    document: { addEventListener(type, callback) { listeners.set(type, [...(listeners.get(type) || []), callback]); },
      querySelector(selector) { return selector === '#dialog[open]' && dialogOpen ? {} : null; }, querySelectorAll() { return []; } },
    window: { studioRuntimeReady: Promise.resolve(true) },
    setTimeout(callback) { timers.push(callback); return timers.length; }, clearTimeout() {}, AbortController, Date,
    esc: String, ...extra,
  });
  vm.runInContext(source, c);
  c.loadStudioDefaultPlayerPassword = async () => password;
  c.playerJsonRequest = async () => ({ players: players.map((p) => ({ ...p })) });
  c.playerPost = async (url, payload) => {
    assert.equal(url, '/api/network/check'); assert.equal(payload.playerPassword, password);
    posted.push({ ...payload }); active++; peak = Math.max(peak, active);
    const id = posted.length.toString(16).padStart(32, '0'); jobs.set(id, payload); return { jobId: id };
  };
  c.waitPlayerJob = async (id) => {
    await new Promise((resolve) => setImmediate(resolve)); active--;
    const payload = jobs.get(id), p = players.find((p) => p.sn === payload.expectedSn);
    if (p.offline) throw new Error('Board is offline');
    p.connected = true;
    return { connectionId: p.connectionId, device: { sn: p.sn, ip: p.ip } };
  };
  return { c, timers, players, posted, jobs,
    emit(type) { for (const callback of listeners.get(type) || []) callback({}); },
    async flush() { const next = timers.shift(); if (next) next(); const running = vm.runInContext('playerAutoReconnect.running', c); if (running) await running; await new Promise((resolve) => setImmediate(resolve)); },
    setPassword(value) { password = value; }, setDialog(value) { dialogOpen = value; }, peak: () => peak,
    state: () => vm.runInContext('playerAutoReconnect', c), manager: () => vm.runInContext('playerManager', c),
  };
}

test('opening any page reconnects saved boards with three workers and skips valid/no-address players', async () => {
  const f = fixture([...Array.from({ length: 7 }, (_, n) => player(n + 1)), player(8, true), { ...player(9), ip: '' }]);
  f.players[2].offline = true;
  f.emit('DOMContentLoaded'); await f.flush();
  assert.equal(f.posted.length, 7); assert.equal(f.peak(), 3);
  assert.equal(f.players.filter((p) => p.connected).length, 7);
  assert.equal(f.manager().states.get('SN3').message, 'Board is offline');
  assert.match(f.manager().message, /Automatic reconnect: 6 connected.*1 failed/);
  // Repainting or dispatching another startup cannot hammer an offline board.
  f.c.mountPlayerManagement(); f.emit('DOMContentLoaded'); await f.flush();
  f.c.queueAutomaticPlayerConnections(); await f.flush();
  assert.equal(f.posted.length, 7);
  assert.equal('password' in f.state(), false);
});

test('startup stays quiet without a saved password and retries when a password is saved', async () => {
  const f = fixture([player(1)]); f.setPassword('');
  f.emit('DOMContentLoaded'); await f.flush();
  assert.equal(f.posted.length, 0); assert.equal(f.manager().error, '');
  f.setPassword('new-fixture-password'); f.emit('studio-player-password-saved'); await f.flush();
  assert.equal(f.posted.length, 1); assert.equal(f.posted[0].playerPassword, 'new-fixture-password');
});

test('automatic checks wait while an operator dialog or another network action is active', async () => {
  let busy = true;
  const f = fixture([player(1)], { isNetworkBatchBusy: () => busy });
  f.emit('DOMContentLoaded'); await f.flush();
  assert.equal(f.posted.length, 0);
  busy = false; f.setDialog(true); await f.flush(); assert.equal(f.posted.length, 0);
  f.setDialog(false); await f.flush(); assert.equal(f.posted.length, 1);
});

test('clearing a password stops undispatched automatic connections and stores no credential in reconnect state', async () => {
  const f = fixture(Array.from({ length: 7 }, (_, n) => player(n + 1)));
  let release;
  const barrier = new Promise((resolve) => { release = resolve; });
  const originalWait = f.c.waitPlayerJob;
  f.c.waitPlayerJob = async (id) => { await barrier; return originalWait(id); };
  f.emit('DOMContentLoaded'); f.timers.shift()();
  for (let i = 0; i < 5; i++) await new Promise((resolve) => setImmediate(resolve));
  assert.equal(f.posted.length, 3);
  f.setPassword(''); f.emit('studio-player-password-saved'); release();
  await vm.runInContext('playerAutoReconnect.running', f.c); await new Promise((resolve) => setImmediate(resolve));
  await f.flush();
  assert.equal(f.posted.length, 3); assert.equal(f.state().pending, false);
  assert.equal(f.manager().states.size, 0);
  assert.match(f.manager().message, /Save a player password/);
  assert.ok(!JSON.stringify(f.state()).includes('saved-fixture-password'));
});

test('a competing startup tab does not send duplicate connection checks', async () => {
  let lockOptions;
  const f = fixture([player(1)], { navigator: { locks: { async request(name, options, callback) {
    assert.equal(name, 'relay-saved-player-reconnect'); lockOptions = options; await callback(null);
  } } } });
  f.emit('DOMContentLoaded'); await f.flush();
  assert.equal(lockOptions.ifAvailable, true); assert.equal(f.posted.length, 0); assert.equal(f.manager().error, '');
});

test('a retired runtime cannot start automatic logins', async () => {
  const f = fixture([player(1)], { window: { studioRuntimeReady: Promise.resolve(false) } });
  f.c.loadStudioDefaultPlayerPassword = async () => { throw new Error('Must not load credentials from a retired service'); };
  f.emit('DOMContentLoaded'); await f.flush();
  assert.equal(f.posted.length, 0); assert.equal(f.manager().error, '');
});

test('a changed discovered address gets one new attempt without repeating an unchanged offline board', async () => {
  const f = fixture([player(1), player(2)]); f.players.forEach((p) => { p.offline = true; });
  f.emit('DOMContentLoaded'); await f.flush(); assert.equal(f.posted.length, 2);
  f.players[0].ip = '192.168.8.99'; f.players[0].offline = false;
  f.c.queueAutomaticPlayerConnections(); await f.flush();
  assert.equal(f.posted.length, 3); assert.equal(f.posted[2].ip, '192.168.8.99');
});
