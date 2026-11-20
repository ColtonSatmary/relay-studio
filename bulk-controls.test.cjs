'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const escape = (value) => String(value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
function sandbox(extra = {}) {
  const c = vm.createContext({ document: { addEventListener() {}, querySelector() { return null; } }, window: { addEventListener() {} },
    esc: escape, setTimeout, clearTimeout, Date, Intl, AbortController, ...extra });
  for (const file of ['player-management.js', 'board-controls.js', 'bulk-controls.js']) vm.runInContext(fs.readFileSync(path.join(__dirname, file), 'utf8'), c);
  c.paintPlayerManagement = () => {};
  return c;
}
const player = (n, extra = {}) => ({ id: `board-${n}`, sn: `SERIAL-${n}`, name: `Board ${n}`, ip: `192.168.8.${n}`, connected: true,
  connectionId: n.toString(16).padStart(32, '0'), connectedUntil: new Date(Date.now() + 60000).toISOString(), width: 320, ...extra });
const plain = (value) => JSON.parse(JSON.stringify(value));

test('browser synchronization copies browser timezone and current UTC time together', () => {
  class Clock extends Date { static now() { return 1795000000000; } }
  const c = sandbox({ Date: Clock, Intl: { DateTimeFormat() { return { resolvedOptions() { return { timeZone: 'Asia/Kathmandu' }; } }; } } });
  assert.deepEqual(plain(c.browserBoardClockValues()), { utcTimeMillis: 1795000000000, timeZone: 'Asia/Kathmandu' });
});

test('seven control changes run at most two at once and retain independent readback results', async () => {
  const c = sandbox(), players = Array.from({ length: 7 }, (_, i) => player(i + 1));
  const posts = []; let active = 0, peak = 0;
  c.postBulkBoardControl = async (payload) => {
    posts.push(plain(payload)); active++; peak = Math.max(peak, active);
    return { jobId: payload.connectionId };
  };
  c.waitPlayerJob = async (id) => {
    await new Promise((resolve) => setTimeout(resolve, 5)); active--;
    if (id === player(2).connectionId) { const error = new Error('The player rejected this setting'); error.jobFailed = true; throw error; }
    return { verified: id !== player(3).connectionId, device: { sn: `SERIAL-${parseInt(id, 16)}` }, message: 'Read back from this board.' };
  };
  const results = await c.runBulkBoardControls(players, { kind: 'brightness', ratio: 35, label: 'Brightness' }, 'fixture-password');
  assert.equal(posts.length, 7); assert.equal(peak, 2);
  assert.equal(posts.every((p) => p.playerPassword === 'fixture-password' && p.section === 'brightness' && p.values.ratio === 35), true);
  assert.equal(results[0].status, 'complete'); assert.equal(results[1].status, 'failed'); assert.equal(results[2].status, 'unconfirmed');
  assert.equal(results[6].status, 'complete'); assert.equal(c.isBulkBoardControlBusy(), false);
  assert.equal(JSON.stringify(results).includes('fixture-password'), false);
  assert.match(c.bulkBoardControlResultsHtml(), /5 of 7 boards verified/);
});

test('invalid or disconnected recipients prevent every write, including a later malformed mosaic geometry', async () => {
  const c = sandbox(); let posts = 0;
  c.postBulkBoardControl = async () => { posts++; };
  await assert.rejects(c.runBulkBoardControls([player(1), player(2, { connected: false })], { kind: 'brightness', ratio: 50 }, 'fixture'), /Connect Board 2/);
  await assert.rejects(c.runBulkBoardControls([player(1), player(2, { width: 4000 })], { kind: 'mosaic', enable: true, mode: 0, direction: 0, length: 6 }, 'fixture'), /supported range/);
  await assert.rejects(c.runBulkBoardControls([player(1), player(1)], { kind: 'brightness', ratio: 50 }, 'fixture'), /only once/);
  assert.equal(posts, 0); assert.equal(c.isBulkBoardControlBusy(), false);
});

test('mosaic geometry is calculated for each board and disabling does not overwrite layout', () => {
  const c = sandbox(), change = { kind: 'mosaic', enable: true, direction: 1, mode: 0, length: 4 };
  assert.equal(c.bulkBoardControlValues(change, player(1)).values.totalLength, 1280);
  assert.equal(c.bulkBoardControlValues(change, player(2, { width: 640 })).values.totalLength, 2560);
  assert.deepEqual(plain(c.bulkBoardControlValues({ kind: 'mosaic', enable: false }, player(1))), { section: 'mosaic', values: { enable: false } });
});

test('queued browser clock sync generates a fresh timestamp per dispatch and timezone-only does not set UTC', () => {
  let tick = 1795000000000;
  class Clock extends Date { static now() { return tick; } }
  const c = sandbox({ Date: Clock }), change = { kind: 'time', timeZone: 'America/Los_Angeles' };
  const first = c.bulkBoardControlValues(change, player(1)); tick += 45000;
  const next = c.bulkBoardControlValues(change, player(2));
  assert.equal(next.values.utcTimeMillis - first.values.utcTimeMillis, 45000);
  assert.equal(next.values.timeZone, 'America/Los_Angeles');
  assert.deepEqual(plain(c.bulkBoardControlValues({ kind: 'timezone', timeZone: 'Asia/Kathmandu' }, player(1))), { section: 'time', values: { timeZone: 'Asia/Kathmandu' } });
  assert.throws(() => c.bulkBoardControlValues({ kind: 'timezone', timeZone: 'Not/AZone' }, player(1)), /valid time zone/);
});

test('uncertain write responses are not replayed; known operation IDs can be checked without another write', async () => {
  const c = sandbox(); let posts = 0, reads = 0;
  c.postBulkBoardControl = async (payload) => { posts++; if (posts === 1) throw new Error('Network response lost'); return { jobId: payload.connectionId }; };
  c.waitPlayerJob = async () => { reads++; throw new Error('Status temporarily unavailable'); };
  await c.runBulkBoardControls([player(1), player(2)], { kind: 'colorTemperature', colorTemperature: 6500 }, 'fixture');
  assert.equal(posts, 2); assert.equal(reads, 1);
  assert.equal(vm.runInContext('bulkBoardControlState.targets.every(t => t.status === "unconfirmed")', c), true);
  c.waitPlayerJob = async () => { reads++; return { verified: true, device: { sn: 'SERIAL-2' } }; };
  await c.checkBulkBoardControlStatus();
  assert.equal(posts, 2); assert.equal(reads, 2);
  assert.equal(vm.runInContext('bulkBoardControlState.targets[0].status', c), 'unconfirmed');
  assert.equal(vm.runInContext('bulkBoardControlState.targets[1].status', c), 'complete');
});

test('manual date is interpreted in its chosen timezone and nonexistent daylight time is rejected', () => {
  const c = sandbox();
  assert.equal(c.boardClockMillis('2026-01-15T12:00:00', 'America/Los_Angeles'), Date.UTC(2026, 0, 15, 20));
  assert.throws(() => c.boardClockMillis('2026-03-08T02:30:00', 'America/Los_Angeles'), /does not exist/);
  const millis = c.boardClockMillis('2026-01-15T12:00:00', 'Asia/Kathmandu');
  assert.deepEqual(plain(c.bulkBoardControlValues({ kind: 'manualTime', timeZone: 'Asia/Kathmandu', utcTimeMillis: millis }, player(1))), { section: 'time', values: { utcTimeMillis: Date.UTC(2026, 0, 15, 6, 15), timeZone: 'Asia/Kathmandu' } });
});
