'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function setup(screens = []) {
  const state = { dialog: null, saved: null, hint: { textContent: '' }, remove: {} };
  const context = vm.createContext({
    $: () => ({ addEventListener() {} }),
    project: { screens, cues: [], solutions: [] },
    uid: () => 'new-screen',
    esc: (value) => String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('"', '&quot;'),
    FormData: class { constructor(form) { this.form = form; } get(key) { return this.form.elements[key]?.value ?? null; } },
    openDialog(config) {
      state.dialog = config;
      const selected = /<option value="([^"]+)" selected>/.exec(config.body)?.[1];
      state.form = {
        elements: { boardCount: { value: selected }, screenName: { value: 'Lobby' } },
        querySelector: (selector) => selector === '[data-screen-canvas]' ? state.hint : state.remove,
      };
      return state.form;
    },
    commit(project) { state.saved = JSON.parse(JSON.stringify(project)); return true; },
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'dialogs.js'), 'utf8'), context);
  return { state, open: context.openScreen };
}

test('new screen offers board counts and saves every supported canvas', () => {
  const { state, open } = setup();
  open();
  assert.equal(state.form.elements.boardCount.value, '6');
  assert.match(state.hint.textContent, /1920 × 1080/);
  assert.doesNotMatch(state.dialog.body, /name="(?:width|height)"/);
  assert.equal((state.dialog.body.match(/<option /g) || []).length, 6);
  for (const [count, width] of [[1, 320], [2, 640], [3, 960], [4, 1280], [5, 1600], [6, 1920]]) {
    state.form.elements.boardCount.value = String(count);
    state.form.elements.boardCount.onchange();
    assert.ok(state.hint.textContent.includes(`${width} × 1080`));
    state.dialog.onSubmit(state.form);
    assert.deepEqual(state.saved.screens[0], { id: 'new-screen', name: 'Lobby', width, height: 1080 });
  }
});

test('editing selects the existing count and retains imported screen metadata', () => {
  const { state, open } = setup([{ id: 's1', name: 'Old name', width: 960, height: 1080, sourceSchedule: 'native-schedule' }]);
  open('s1');
  assert.equal(state.form.elements.boardCount.value, '3');
  state.dialog.onSubmit(state.form);
  assert.deepEqual(state.saved.screens[0], { id: 's1', name: 'Lobby', width: 960, height: 1080, sourceSchedule: 'native-schedule' });
});

test('renaming a nonstandard imported canvas preserves its dimensions until a count is chosen', () => {
  const { state, open } = setup([{ id: 's1', name: 'Custom', width: 1920, height: 1200 }]);
  open('s1');
  assert.equal(state.form.elements.boardCount.value, 'existing');
  assert.match(state.hint.textContent, /1920 × 1200/);
  state.dialog.onSubmit(state.form);
  assert.equal(state.saved.screens[0].height, 1200);
  state.form.elements.boardCount.value = '2';
  state.dialog.onSubmit(state.form);
  assert.deepEqual(state.saved.screens[0], { id: 's1', name: 'Lobby', width: 640, height: 1080 });
});

test('out-of-range counts and duplicate screen names cannot save', () => {
  const { state, open } = setup([{ id: 's1', name: 'Lobby', width: 320, height: 1080 }]);
  open();
  for (const invalid of ['0', '7', '1.5', '', 'existing']) {
    state.form.elements.boardCount.value = invalid;
    assert.throws(() => state.dialog.onSubmit(state.form), /Choose between 1 and 6 boards/);
  }
  state.form.elements.boardCount.value = '2';
  assert.throws(() => state.dialog.onSubmit(state.form), /already exists/);
  assert.equal(state.saved, null);
});
