'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, 'app.js'), 'utf8');

function fixture(options = {}) {
  const { port = '47833', unavailable = false, protocol = 'http:', browserCopy = '', healthMarker = 'viplex-schedule-studio/fixture', controlsAvailable = true } = options;
  const build = Object.hasOwn(options, 'build') ? options.build : '2026.11.19.2';
  const requests = [], downloads = [], documentEvents = {}, windowEvents = {}, elements = new Map();
  const element = (selector) => { if (!elements.has(selector)) elements.set(selector, {}); return elements.get(selector); };
  const window = { StudioModel: { localDate: () => '2026-11-19' }, addEventListener: (name, handler) => { windowEvents[name] = handler; } };
  const context = vm.createContext({ window, location: { hostname: '127.0.0.1', port, protocol, reload() {} }, AbortController, setTimeout, clearTimeout,
    document: { querySelector: element, addEventListener: (name, handler) => { documentEvents[name] = handler; } },
    localStorage: { getItem: () => browserCopy, setItem() { throw new Error('The old browser draft must not be overwritten.'); } },
    download: (...args) => downloads.push(args),
    fetch: async (url, requestOptions) => {
      requests.push({ url, options: requestOptions });
      if (unavailable) throw new Error('Offline');
      if (url === '/api/health') return { ok: true, text: async () => healthMarker };
      if (url === '/bulk-controls.js') return { ok: controlsAvailable };
      return { ok: true, json: async () => ({ runtimeBuild: build, exportToken: 'fixture-private-token' }) };
    },
  });
  vm.runInContext(source, context);
  return { context, window, requests, downloads, documentEvents, windowEvents, element };
}

test('retired origin does not read or save the project and preserves its browser copy for recovery', async () => {
  const browserCopy = '{"version":1,"title":"Original browser draft"}';
  const f = fixture({ port: '47832', build: undefined, browserCopy });
  assert.equal(await f.window.studioRuntimeReady, false);
  await f.documentEvents.DOMContentLoaded();
  await f.windowEvents.storage({ key: 'relay-studio-project-v1' });
  assert.deepEqual(f.requests.map((request) => request.url), ['/api/session']);
  const html = f.element('#app').innerHTML;
  assert.match(html, /http:\/\/127\.0\.0\.1:47833\//);
  assert.match(html, /target="_blank" rel="noopener"/);
  assert.match(html, /Download browser workspace copy/);
  f.element('[data-runtime-backup]').onclick();
  assert.deepEqual(f.downloads[0], ['Relay browser workspace recovery.json', browserCopy, 'application/json']);
});

test('matching runtime build allows startup through one shared readiness promise', async () => {
  const f = fixture();
  assert.equal(await f.window.studioRuntimeReady, true);
  assert.equal(f.requests.length, 1);
  assert.equal(f.requests[0].url, '/api/session');
  assert.equal(f.requests[0].options.cache, 'no-store');
  assert.equal(f.element('#app').innerHTML, undefined);
  assert.ok(!JSON.stringify(f.window).includes('fixture-private-token'));
});

test('missing and different service builds block catalog/bootstrap writes', async () => {
  for (const build of [undefined, 'old-build', '2026.11.20.1']) {
    const f = fixture({ build, port: '50001' });
    const ready = f.window.studioRuntimeReady;
    assert.equal(await ready, false);
    f.window.studioRuntimeReady = ready;
    await f.documentEvents.DOMContentLoaded();
    assert.ok(f.requests.every((request) => request.url === '/api/session'));
    assert.match(f.element('#app').innerHTML, /service in this window needs an update/);
  }
});

test('the existing fixed service is accepted only on its verified origin and with both markers', async () => {
  const existing = fixture({ build: undefined });
  assert.equal(await existing.window.studioRuntimeReady, true);
  assert.deepEqual(existing.requests.map((request) => request.url), ['/api/session', '/api/health', '/bulk-controls.js']);
  for (const options of [{ healthMarker: 'unrelated-service' }, { controlsAvailable: false }, { port: '50001' }, { build: 'old-build' }]) {
    const other = fixture({ build: undefined, ...options });
    assert.equal(await other.window.studioRuntimeReady, false);
  }
});

test('a matching explicit build also permits custom local ports', async () => {
  assert.equal(await fixture({ port: '50001' }).window.studioRuntimeReady, true);
});

test('unavailable service shows retry guidance without discarding browser data', async () => {
  const f = fixture({ unavailable: true });
  assert.equal(await f.window.studioRuntimeReady, false);
  await f.documentEvents.DOMContentLoaded();
  assert.match(f.element('#app').innerHTML, /Open Launch Studio.cmd/);
  assert.equal(f.downloads.length, 0);
});

test('offline file mode retains local planning without a network service', async () => {
  const f = fixture({ protocol: 'file:' });
  assert.equal(await f.window.studioRuntimeReady, true);
  assert.equal(f.requests.length, 0);
});
