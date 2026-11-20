'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function fixture() {
  const nodes = new Map(), handlers = {}, requests = [];
  const node = () => ({ value: '', checked: false, disabled: false, hidden: false, dataset: {},
    textContent: '', innerHTML: '', classList: { toggle() {} } });
  const get = (selector) => { if (!nodes.has(selector)) nodes.set(selector, node()); return nodes.get(selector); };
  const elements = { destination: node(), clearDrive: node(), reusePassword: node(), playerPassword: node(), playMode: node(), overwriteExisting: node() };
  elements.playMode.value = 'copy'; elements.overwriteExisting.checked = true;
  const form = { elements, isConnected: true, querySelector: get, querySelectorAll() { return []; }, addEventListener(type, callback) { handlers[type] = callback; } };
  const dialog = { addEventListener() {}, removeEventListener() {} };
  let definition;
  const c = vm.createContext({ document: {}, esc: String, readableSize: String, $: () => dialog,
    project: { cues: [] }, M: { cueHasOccurrences: () => true },
    getSolution: () => ({ id: 'image1', name: 'Fixture image', source: { kind: 'localImage' } }),
    openDialog(value) { definition = value; return form; },
    applyDefaultPlayerPassword: async (input) => { input.value = 'fixture-password'; return input.value; },
    fetch: async (url, options) => {
      if (url === '/api/usb-drives') return { ok: true, json: async () => ({ drives: [
        { id: 'volume-e', root: 'E:\\', freeBytes: 100, totalBytes: 200 },
        { id: 'volume-f', root: 'F:\\', freeBytes: 100, totalBytes: 200 } ] }) };
      if (url === '/api/session') return { ok: true, json: async () => ({ exportToken: 'fixture-token' }) };
      assert.equal(url, '/api/export-usb'); requests.push(JSON.parse(options.body));
      return { ok: false, json: async () => ({ error: 'Fixture export stopped before writing.' }) };
    } });
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'usb-playback.js'), 'utf8'), c);
  c.openUsbPlayback('image1');
  return { elements, form, handlers, requests, nodes, submit: () => definition.onSubmit() };
}
async function settle() { for (let n = 0; n < 8; n++) await new Promise(resolve => setImmediate(resolve)); }

test('USB erase defaults to the selected verified volume and is explicit in the export command', async () => {
  const f = fixture(); await settle();
  assert.equal(f.elements.destination.value, 'volume-e');
  assert.equal(f.elements.clearDrive.checked, true);
  assert.equal(f.elements.clearDrive.dataset.volume, 'volume-e');
  assert.equal(f.nodes.get('[type=submit]').textContent, 'Erase E:\\ and export');
  await assert.rejects(f.submit(), /Fixture export stopped/);
  assert.equal(f.requests[0].clearDrive, true);
  assert.equal(f.requests[0].eraseVolumeId, 'volume-e');
  assert.equal(f.requests[0].volumeId, 'volume-e');
  assert.equal(f.elements.clearDrive.checked, false, 'A failed export should require a deliberate retry of erase.');
});

test('unchecking erase preserves files and a newly selected drive uses its own volume identity', async () => {
  const f = fixture(); await settle();
  f.elements.destination.value = 'volume-f'; f.elements.destination.onchange(); await settle();
  assert.equal(f.elements.clearDrive.checked, true);
  assert.equal(f.elements.clearDrive.dataset.volume, 'volume-f');
  f.elements.clearDrive.checked = false; f.handlers.change({ target: f.elements.clearDrive });
  await assert.rejects(f.submit(), /Fixture export stopped/);
  assert.equal(f.requests[0].clearDrive, false);
  assert.equal('eraseVolumeId' in f.requests[0], false);
  assert.equal(f.requests[0].volumeId, 'volume-f');
});

test('local folder export never arms erase and a stale volume identity is refused', async () => {
  const f = fixture(); await settle();
  f.elements.clearDrive.dataset.volume = 'different-volume';
  await assert.rejects(f.submit(), /Choose the erase checkbox again/);
  assert.equal(f.requests.length, 0);
  f.elements.destination.value = 'folder'; f.elements.destination.onchange(); await settle();
  assert.equal(f.elements.clearDrive.checked, false);
  assert.equal(f.elements.clearDrive.dataset.volume, undefined);
  await assert.rejects(f.submit(), /Fixture export stopped/);
  assert.equal(f.requests[0].clearDrive, false);
  assert.equal(f.requests[0].destination, 'folder');
  assert.equal('eraseVolumeId' in f.requests[0], false);
  assert.equal('volumeId' in f.requests[0], false);
});
