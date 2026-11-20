'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, 'player-management.js'), 'utf8');
function sandbox(extra = {}) {
  const context = vm.createContext({ document: { addEventListener() {}, querySelector() { return null; }, querySelectorAll() { return []; } },
    setTimeout, clearTimeout, AbortController, Date, esc: (value) => String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]), ...extra });
  vm.runInContext(source, context);
  return context;
}
const checked = (sn, n) => ({ id: sn, sn, name: `Board ${n}`, ip: `192.168.1.${n}`, connected: true,
  connectionId: n.toString(16).padStart(32, '0'), connectedUntil: new Date(Date.now() + 60000).toISOString() });

test('seven boards connect with at most three operations and one failure does not cancel others', async () => {
  const c = sandbox(); let current = 0, peak = 0;
  const results = await c.runPlayerQueue([1, 2, 3, 4, 5, 6, 7], 3, async (n) => {
    current++; peak = Math.max(peak, current);
    await new Promise((resolve) => setTimeout(resolve, 5));
    current--;
    if (n === 3) throw new Error('Offline');
    return n;
  });
  assert.equal(peak, 3);
  assert.equal(results.length, 7);
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 6);
  assert.equal(results[2].reason.message, 'Offline');
  assert.equal(results[6].value, 7);
});

test('connection reuse requires verified identity, token, and an unexpired check', () => {
  const c = sandbox(), p = checked('SN1', 1);
  assert.equal(c.relayPlayerConnection(p).device.sn, 'SN1');
  for (const change of [{ connected: false }, { sn: '' }, { ip: '' }, { connectionId: 'bad' }, { connectedUntil: 'bad' }, { connectedUntil: new Date(Date.now() - 1000).toISOString() }]) {
    assert.equal(c.relayPlayerConnection({ ...p, ...change }), null);
  }
});

test('multiple check results preserve existing connections and expose board-specific failures', async () => {
  const persisted = [checked('existing', 11)], jobs = new Map(); let index = 20;
  const c = sandbox();
  c.playerPost = async (url, payload) => {
    assert.equal(url, '/api/network/check');
    assert.equal(payload.playerPassword, 'fixture');
    const id = (++index).toString(16).padStart(32, '0'); jobs.set(id, payload); return { jobId: id };
  };
  c.waitPlayerJob = async (id) => {
    const p = jobs.get(id);
    if (p.expectedSn === 'offline') throw new Error('Board did not answer');
    const entry = checked(p.expectedSn, Number(p.ip.split('.').at(-1))); persisted.push(entry);
    return { status: 'complete', connectionId: entry.connectionId, device: { sn: entry.sn, ip: entry.ip } };
  };
  c.playerJsonRequest = async () => ({ players: persisted });
  await c.connectManagedPlayers([{ id: 'new1', sn: 'new1', ip: '192.168.1.21' }, { id: 'offline', sn: 'offline', ip: '192.168.1.22' }, { id: 'new2', sn: 'new2', ip: '192.168.1.23' }], 'fixture');
  assert.equal(vm.runInContext('playerManager.players.filter(relayPlayerConnection).length', c), 3);
  assert.equal(vm.runInContext("playerManager.players.some(p => p.sn === 'existing')", c), true);
  assert.equal(vm.runInContext("playerManager.states.get('offline').message", c), 'Board did not answer');
  assert.equal(vm.runInContext('playerManager.batch', c), false);
  assert.match(vm.runInContext('playerManager.message', c), /2 connected.*1 failed/);
});

test('board names, aliases and failure messages are escaped in the directory', () => {
  const c = sandbox({ fixture: { ...checked('SN1', 1), alias: '<img src=x>', name: '<img src=x>', deviceName: '<script>' } });
  vm.runInContext("playerManager.players = [fixture]; playerManager.states.set('SN1', { status: 'failed', message: '<script>alert(1)</script>' })", c);
  const html = c.playerDirectoryHtml();
  assert.ok(html.includes('&lt;img src=x&gt;'));
  assert.ok(html.includes('&lt;script&gt;'));
  assert.ok(!html.includes('<script>'));
  assert.ok(!html.includes('<img src=x>'));
});

test('posting erases the transient password even after an HTTP failure', async () => {
  const c = sandbox(); let calls = 0;
  c.playerJsonRequest = async () => { if (++calls === 1) return { exportToken: 'fixture' }; throw new Error('Unavailable'); };
  const payload = { ip: '192.168.1.24', playerPassword: 'fixture' };
  await assert.rejects(c.playerPost('/api/network/check', payload), /Unavailable/);
  assert.equal('playerPassword' in payload, false);
});

test('an interrupted discovery resumes the same job instead of starting another scan', async () => {
  const c = sandbox(); let posted = 0, polled = 0;
  c.playerPost = async () => { posted++; return { jobId: 'a'.repeat(32) }; };
  c.playerJsonRequest = async () => ({ players: [] });
  c.waitPlayerJob = async (id) => { polled++; assert.equal(id, 'a'.repeat(32)); if (polled === 1) throw new Error('Status unavailable'); return { message: 'Found 7 boards' }; };
  await c.discoverManagedPlayers();
  assert.equal(vm.runInContext('playerManager.discoveryJobId', c), 'a'.repeat(32));
  await c.discoverManagedPlayers();
  assert.equal(posted, 1);
  assert.equal(vm.runInContext('playerManager.discoveryJobId', c), '');
  assert.equal(vm.runInContext('playerManager.message', c), 'Found 7 boards');
});

test('discovery selects only boards found now and puts them before stale saved addresses', async () => {
  const c = sandbox();
  const found = [1, 2, 3, 4, 5, 6, 7].map((n) => ({ ...checked(`live${n}`, n), connected: false }));
  const stale = { ...checked('old', 100), connected: false, name: 'A stale board' };
  const result = { status: 'complete', players: found, message: 'Found 7 boards' };
  c.playerPost = async () => ({ jobId: 'b'.repeat(32) });
  c.waitPlayerJob = async () => result;
  c.playerJsonRequest = async () => ({ players: [stale, ...found], discovery: result });
  await c.discoverManagedPlayers();
  assert.equal(vm.runInContext('playerManager.selected.size', c), 7);
  assert.equal(vm.runInContext("playerManager.selected.has('old')", c), false);
  assert.equal(vm.runInContext('playerManager.players.at(-1).sn', c), 'old');
  assert.match(vm.runInContext('playerManager.message', c), /7 found boards selected/);
});
