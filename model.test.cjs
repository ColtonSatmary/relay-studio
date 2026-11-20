const test = require('node:test');
const assert = require('node:assert/strict');
const model = require('./model.js');

function project(...cues) {
  return {
    version: 1,
    screens: ['main', 'lobby'].map((id) => ({ id, name: id, width: 1920, height: 1080 })),
    solutions: ['welcome', 'break'].map((id) => ({
      id,
      name: id,
      width: 1920,
      height: 1080,
      color: '#008060',
    })),
    cues,
  };
}

function cue(id, fields = {}) {
  return {
    id,
    screenId: 'main',
    solutionId: 'welcome',
    startDate: '2026-11-16',
    endDate: '',
    start: '09:00',
    end: '10:00',
    days: [1],
    ...fields,
  };
}

test('screen moves keep cues and screen metadata attached to the same IDs', () => {
  const doc = project(cue('running'));
  const [main, lobby] = doc.screens;
  main.sourceSchedule = 'native-schedule';
  const ids = ['main', 'lobby'];
  const changed = model.reorderScreens(doc, ids, 'main', 'lobby', true);
  assert.equal(changed.screens[0], lobby);
  assert.equal(changed.screens[1], main);
  assert.equal(doc.screens[0], main);
  assert.equal(changed.cues, doc.cues);
  assert.equal(changed.solutions, doc.solutions);
  const restored = model.validateProject(JSON.parse(JSON.stringify(changed)));
  assert.deepEqual(restored.screens.map((screen) => screen.id), ['lobby', 'main']);
  assert.equal(restored.cues[0].screenId, 'main');
});

test('moving within a comparison reorders only the visible slots in board order', () => {
  const doc = project();
  doc.screens = ['main', 'hidden1', 'lobby', 'hidden2', 'stage']
    .map((id) => ({ ...doc.screens[0], id, name: id }));
  const visible = ['lobby', 'stage', 'main'];
  const changed = model.reorderScreens(doc, visible, 'stage', 'main', false);
  assert.deepEqual(changed.screens.map((screen) => screen.id), ['stage', 'hidden1', 'main', 'hidden2', 'lobby']);
  assert.equal(changed.screens[1], doc.screens[1]);
  assert.equal(changed.screens[3], doc.screens[3]);
});

test('same-position drops return the original project and invalid lane selections are rejected', () => {
  const doc = project();
  const both = ['main', 'lobby'];
  assert.equal(model.reorderScreens(doc, both, 'main', 'lobby', false), doc);
  assert.equal(model.reorderScreens(doc, both, 'lobby', 'main', true), doc);
  assert.equal(model.reorderScreens(doc, ['main'], 'main', 'main', false), doc);
  for (const args of [
    [['main'], 'main', 'lobby', true],
    [both, 'missing', 'main', true],
    [['main', 'missing'], 'main', 'main', true],
    [['main', 'main'], 'main', 'main', false],
    [both, 'main', 'lobby', 'after'],
  ]) assert.throws(() => model.reorderScreens(doc, ...args), /visible/i);
});

test('uses civil dates across leap days, early years and daylight-saving transitions', () => {
  assert.equal(model.addDays('2024-02-28', 2), '2024-03-01');
  assert.equal(model.addDays('2026-03-08', 1), '2026-03-09');
  assert.equal(model.addDays('2026-11-01', 1), '2026-11-02');
  assert.equal(model.addDays('0099-12-31', 1), '0100-01-01');
  assert.equal(model.weekday('1969-12-28'), 0);
  assert.equal(model.weekday('2026-11-16'), 1);
  assert.equal(model.localDate(new Date(2026, 10, 16, 23, 59)), '2026-11-16');
  assert.throws(() => model.addDays('2026-02-29', 1), /invalid/i);
  assert.throws(() => model.addDays('2026-13-01', 1), /invalid/i);
});

test('a single day can be scheduled all day, with a half-open end boundary', () => {
  const block = cue('one', { start: '00:00', end: '24:00', endDate: '2026-11-16' });
  const doc = project(block, cue('next', { startDate: '2026-11-17', days: [2], start: '00:00' }));
  model.validateProject(doc);
  assert.deepEqual(model.occurrences(doc, '2026-11-16', 'main'), [
    { cue: block, startMinute: 0, endMinute: 1440, continued: false, continues: false },
  ]);
  assert.deepEqual(model.occurrences(doc, '2026-11-16', 'lobby'), []);
  assert.deepEqual(model.occurrences(doc, '2026-11-23'), []);
});

test('weekly overnight shows the tail after the final selected day, including Saturday to Sunday', () => {
  const block = cue('late', {
    startDate: '2026-11-21',
    endDate: '2026-11-28',
    days: [6],
    start: '22:30',
    end: '01:15',
  });
  const doc = project(block);
  model.validateProject(doc);
  assert.deepEqual(model.occurrences(doc, '2026-11-28'), [
    { cue: block, startMinute: 1350, endMinute: 1440, continued: false, continues: true },
  ]);
  assert.deepEqual(model.occurrences(doc, '2026-11-29'), [
    { cue: block, startMinute: 0, endMinute: 75, continued: true, continues: false },
  ]);
  assert.deepEqual(model.occurrences(doc, '2026-12-05'), []);
});

test('detects an overlap between a final overnight tail and a new series many years in the future', () => {
  const doc = project(
    cue('weekly', { days: [6], start: '23:00', end: '01:00' }),
    cue('future', { solutionId: 'break', startDate: '2099-01-01', days: [0], start: '00:30', end: '02:00' }),
  );
  assert.throws(() => model.validateProject(doc), /break.*overlaps.*welcome.*2099-01-04 at 00:30/);
  doc.cues[1].start = '01:00';
  model.validateProject(doc);
});

test('permits touching times, nonintersecting date ranges, and different screens', () => {
  const doc = project(
    cue('ends', { endDate: '2026-11-18' }),
    cue('other-dates', { startDate: '2026-11-17' }),
    cue('other-screen', { screenId: 'lobby' }),
    cue('after', { start: '10:00', end: '11:00' }),
  );
  model.validateProject(doc);
  assert.deepEqual(
    model.occurrences(doc, '2026-11-16', 'main').map((item) => item.cue.id),
    ['ends', 'after'],
  );
  assert.deepEqual(
    model.occurrences(doc, '2026-11-23', 'main').map((item) => item.cue.id),
    ['other-dates', 'after'],
  );
});

test('calendar range intersection alone is insufficient when no selected weekday falls in it', () => {
  const doc = project(
    cue('first', { startDate: '2026-11-10', endDate: '2026-11-18' }),
    cue('second', { startDate: '2026-11-17', endDate: '2026-11-25' }),
  );
  model.validateProject(doc);
  doc.cues[0].endDate = '2026-11-23';
  assert.throws(() => model.validateProject(doc), /2026-11-23 at 09:00/);
});

test('an exact-midnight ending does not create a phantom tail', () => {
  const same = cue('evening', { start: '20:45', end: '00:00' });
  const doc = project(same, cue('morning', { days: [2], start: '00:00', end: '00:05' }));
  model.validateProject(doc);
  assert.equal(model.occurrences(doc, '2026-11-16')[0].continues, false);
  assert.deepEqual(
    model.occurrences(doc, '2026-11-17').map((item) => item.cue.id),
    ['morning'],
  );
});

test('new blocks choose a full quarter after the playhead and skip small gaps around ViPlex times', () => {
  const doc = project(
    cue('legacy', { start: '09:09', end: '09:31' }),
    cue('following', { start: '09:57', end: '10:04' }),
  );
  model.validateProject(doc);
  const before = JSON.stringify(doc);
  assert.equal(model.suggestBlockStart(doc, '2026-11-16', 'main', 9 * 60 + 1), 10 * 60 + 15);
  assert.equal(model.suggestBlockStart(doc, '2026-11-16', 'lobby', 9 * 60 + 1), 9 * 60 + 15);
  assert.equal(model.suggestBlockStart(doc, '2026-11-16', 'main', 8 * 60 + 45), 8 * 60 + 45);
  assert.equal(JSON.stringify(doc), before);
});

test('the last quarter ends at midnight and a booked final quarter wraps to the first available slot', () => {
  const doc = project(
    cue('late', { start: '23:52', end: '24:00' }),
    cue('early', { start: '00:00', end: '00:03' }),
  );
  assert.equal(model.nextQuarterStart(1439), 1425);
  assert.equal(model.suggestBlockStart(doc, '2026-11-16', 'lobby', 1439) + model.blockMinutes, 1440);
  assert.equal(model.suggestBlockStart(doc, '2026-11-16', 'main', 1439), 15);
  const changed = model.overlayDay(doc, '2026-11-16', [
    { screenId: 'main', solutionId: 'break', start: '23:45', end: '' },
  ]);
  const last = model.occurrences(changed, '2026-11-16', 'main').slice(-2);
  assert.deepEqual(last.map(({ startMinute, endMinute }) => [startMinute, endMinute]), [[1425, 1432], [1432, 1440]]);
});

test('exclusion removes both parts of an overnight occurrence and permits a replacement', () => {
  const series = cue('saturday', { days: [6], start: '22:30', end: '01:15', excludedDates: ['2026-11-21'] });
  const replacement = cue('sunday', {
    startDate: '2026-11-22',
    endDate: '2026-11-22',
    days: [0],
    start: '00:30',
    end: '01:00',
  });
  const doc = project(series, replacement);
  model.validateProject(doc);
  assert.deepEqual(model.occurrences(doc, '2026-11-21'), []);
  assert.deepEqual(
    model.occurrences(doc, '2026-11-22').map((item) => item.cue.id),
    ['sunday'],
  );
  assert.deepEqual(
    model.occurrences(doc, '2026-11-29').map((item) => item.cue.id),
    ['saturday'],
  );
  // A second occurrence beyond the exception still conflicts.
  replacement.endDate = '';
  assert.throws(() => model.validateProject(doc), /2026-11-29 at 00:30/);
});

test("conflict detection combines the two series' exclusions across multiple weeks", () => {
  const first = cue('first', { excludedDates: ['2026-11-16', '2026-11-30'] });
  const second = cue('second', { excludedDates: ['2026-11-23', '2026-12-07'], endDate: '2026-12-07' });
  const doc = project(first, second);
  model.validateProject(doc);
  second.endDate = '';
  assert.throws(() => model.validateProject(doc), /2026-12-14 at 09:00/);
});

test('import errors identify malformed and dangling data, and additional metadata survives', () => {
  for (const patch of [
    { screenId: 'gone' },
    { solutionId: 'gone' },
    { days: [] },
    { days: [1, 1] },
    { days: [7] },
    { endDate: '2026-11-10' },
    { endDate: '2026-11-16', days: [0] },
    { endDate: null },
    { start: '24:00' },
    { end: '09:00' },
    { start: '9:00' },
    { end: '09:60' },
    { excludedDates: '2026-11-22' },
    { excludedDates: ['2026-02-31'] },
  ]) {
    assert.throws(() => model.validateProject(project(cue('invalid', patch))), Error, JSON.stringify(patch));
  }
  assert.throws(() => model.validateProject(project(cue('duplicate'), cue('duplicate'))), /duplicate/i);
  const doc = project(cue('keep', { title: 'A cue', imported: true }));
  doc.solutions[0].source = { vendor: 'example' };
  const original = JSON.stringify(doc);
  assert.equal(model.validateProject(doc), doc);
  assert.equal(JSON.stringify(doc), original);
});

function lineup(doc, date, screen = 'main') {
  return model
    .occurrences(doc, date, screen)
    .map(({ cue, startMinute, endMinute }) => [cue.solutionId, startMinute, endMinute]);
}

test('moving a one-off onto another screen keeps its ID, imported times and extra metadata', () => {
  const date = '2026-11-16';
  const source = cue('one', { endDate: date, start: '16:07', end: '16:52', title: 'Doors' });
  const doc = project(source);
  const target = { cueId: 'one', screenId: 'lobby', startMinute: 967, endMinute: 1012 };
  assert.equal(model.editOccurrence(doc, date, { ...target, screenId: 'main' }), doc);
  const moved = model.editOccurrence(doc, date, target);
  assert.deepEqual(moved.cues, [{ ...source, screenId: 'lobby' }]);
  assert.equal(doc.cues[0].screenId, 'main');
  const longer = model.editOccurrence(moved, date, { ...target, endMinute: 1020 });
  assert.deepEqual(lineup(longer, date, 'lobby'), [['welcome', 967, 1020]]);
});

test('resizing a recurring block detaches only the chosen start, preserving earlier exceptions', () => {
  const doc = project(cue('repeat', { excludedDates: ['2026-11-23'], title: 'Doors' }));
  const target = { cueId: 'repeat', screenId: 'main', startMinute: 525, endMinute: 600 };
  const result = model.editOccurrence(doc, '2026-11-30', target);
  const [series, changed] = result.cues;
  assert.deepEqual(series.excludedDates, ['2026-11-23', '2026-11-30']);
  assert.notEqual(changed.id, series.id);
  assert.equal(changed.title, 'Doors');
  assert.deepEqual(lineup(result, '2026-11-30'), [['welcome', 525, 600]]);
  for (const date of ['2026-11-16', '2026-11-23', '2026-12-07'])
    assert.deepEqual(lineup(result, date), lineup(doc, date));
  assert.throws(() => model.editOccurrence(result, '2026-11-30', target), /no longer scheduled/);
  const finite = project(cue('repeat', { endDate: '2026-11-25', excludedDates: ['2026-11-16'] }));
  assert.deepEqual(model.editOccurrence(finite, '2026-11-23', target).cues.map((c) => c.id), ['repeat']);
});

test('daily overnight head and tail on the same day address two different airings', () => {
  const doc = project(cue('night', {
    startDate: '2026-11-01', days: [0, 1, 2, 3, 4, 5, 6], start: '23:00', end: '01:15',
  }));
  const date = '2026-11-16';
  const [tail, head] = model.occurrences(doc, date);
  assert.deepEqual(model.occurrenceBounds(tail), { startMinute: -60, endMinute: 75 });
  assert.deepEqual(model.occurrenceBounds(head), { startMinute: 1380, endMinute: 1515 });
  const moved = model.editOccurrence(doc, date, {
    cueId: 'night', continued: true, screenId: 'lobby', startMinute: -15, endMinute: 120,
  });
  assert.deepEqual(lineup(moved, '2026-11-15', 'lobby'), [['welcome', 1425, 1440]]);
  assert.deepEqual(lineup(moved, date, 'lobby'), [['welcome', 0, 120]]);
  assert.deepEqual(lineup(moved, date), [['welcome', 1380, 1440]]);
  assert.deepEqual(lineup(moved, '2026-11-17'), lineup(doc, '2026-11-17'));
  const resized = model.editOccurrence(moved, date, {
    cueId: 'night', continued: false, screenId: 'main', startMinute: 1395, endMinute: 1515,
  });
  assert.deepEqual(lineup(resized, date), [['welcome', 1395, 1440]]);
  assert.deepEqual(lineup(resized, '2026-11-17'), lineup(doc, '2026-11-17'));
  assert.deepEqual(resized.cues.find((c) => c.id === 'night').excludedDates, ['2026-11-15', date]);
});

test('moving an overnight airing fully onto the displayed day updates its calendar date and weekday', () => {
  const doc = project(cue('night', { endDate: '2026-11-16', start: '23:45', end: '00:30' }));
  const moved = model.editOccurrence(doc, '2026-11-17', {
    cueId: 'night', continued: true, screenId: 'main', startMinute: 15, endMinute: 60,
  });
  assert.deepEqual(lineup(moved, '2026-11-16'), []);
  assert.deepEqual(lineup(moved, '2026-11-17'), [['welcome', 15, 60]]);
  assert.equal(moved.cues[0].id, 'night');
  assert.equal(moved.cues[0].startDate, '2026-11-17');
  assert.deepEqual(moved.cues[0].days, [2]);
});

test('a blocked drop, including an overlap on the following day, leaves the original schedule intact', () => {
  const doc = project(
    cue('late', { start: '23:15', end: '01:15' }),
    cue('other', { screenId: 'lobby', days: [2], start: '01:15', end: '02:15' }),
  );
  const before = JSON.stringify(doc);
  const target = { cueId: 'late', screenId: 'lobby', startMinute: 1395, endMinute: 1515 };
  assert.doesNotThrow(() => model.editOccurrence(doc, '2026-11-16', target));
  assert.throws(() => model.editOccurrence(doc, '2026-11-16', { ...target, endMinute: 1530 }), /overlaps.*lobby.*2026-11-17/);
  assert.throws(() => model.editOccurrence(doc, '2026-11-16', { ...target, screenId: 'gone' }), /schedule/i);
  assert.throws(() => model.editOccurrence(doc, '2026-11-16', { ...target, startMinute: 1515 }), /time range/);
  assert.throws(() => model.editOccurrence(doc, '2026-11-16', { ...target, endMinute: 2835 }), /24 hours/);
  assert.equal(JSON.stringify(doc), before);
});

const change = (fields = {}) => ({
  screenId: 'main',
  solutionId: 'break',
  start: '09:30',
  end: '09:45',
  ...fields,
});

test("a coordinated overlay with an automatic end reaches each screen's own next start", () => {
  const doc = project(
    cue('early'),
    cue('next', { start: '11:15', end: '13:00' }),
    cue('other', { screenId: 'lobby', start: '09:45', end: '11:00' }),
  );
  const copy = JSON.stringify(doc);
  const result = model.overlayDay(doc, '2026-11-16', [
    change({ end: '' }),
    change({ screenId: 'lobby', end: '' }),
  ]);
  assert.equal(JSON.stringify(doc), copy);
  assert.deepEqual(lineup(result, '2026-11-16'), [
    ['welcome', 540, 570],
    ['break', 570, 675],
    ['welcome', 675, 780],
  ]);
  assert.deepEqual(lineup(result, '2026-11-16', 'lobby'), [
    ['break', 570, 585],
    ['welcome', 585, 660],
  ]);
  assert.deepEqual(lineup(result, '2026-11-23'), lineup(doc, '2026-11-23'));
  assert.deepEqual(lineup(result, '2026-11-23', 'lobby'), lineup(doc, '2026-11-23', 'lobby'));
});

test('explicit overlay cuts across multiple one-offs and preserves split metadata', () => {
  const one = { endDate: '2026-11-16' };
  const doc = project(
    cue('before', { ...one, title: 'doors' }),
    cue('under', { ...one, start: '10:00', end: '10:45' }),
    cue('after', { ...one, start: '10:45', end: '11:30', title: 'exits' }),
  );
  const result = model.overlayDay(doc, '2026-11-16', [change({ end: '11:15' })]);
  assert.deepEqual(lineup(result, '2026-11-16'), [
    ['welcome', 540, 570],
    ['break', 570, 675],
    ['welcome', 675, 690],
  ]);
  assert.deepEqual(
    result.cues.filter((item) => item.solutionId === 'welcome').map((item) => item.title),
    ['doors', 'exits'],
  );
  assert.equal(result.cues.length, 3);
});

test('day-only overlay of two ends of a daily overnight recurrence preserves adjacent days', () => {
  const doc = project(
    cue('nights', { days: [0, 1, 2, 3, 4, 5, 6], startDate: '2026-11-01', start: '22:00', end: '03:00' }),
  );
  const result = model.overlayDay(doc, '2026-11-16', [change({ start: '01:00', end: '23:00' })]);
  assert.deepEqual(lineup(result, '2026-11-16'), [
    ['welcome', 0, 60],
    ['break', 60, 1380],
    ['welcome', 1380, 1440],
  ]);
  for (const date of ['2026-11-14', '2026-11-15', '2026-11-17', '2026-11-18']) {
    assert.deepEqual(lineup(result, date), lineup(doc, date));
  }
  assert.deepEqual(result.cues.find((item) => item.id === 'nights').excludedDates, [
    '2026-11-15',
    '2026-11-16',
  ]);
  const allDay = model.overlayDay(doc, '2026-11-16', [change({ start: '00:00', end: '24:00' })]);
  assert.deepEqual(lineup(allDay, '2026-11-16'), [['break', 0, 1440]]);
  assert.deepEqual(lineup(allDay, '2026-11-15'), lineup(doc, '2026-11-15'));
  assert.deepEqual(lineup(allDay, '2026-11-17'), lineup(doc, '2026-11-17'));
});

test('a late automatic change runs to midnight and repeated changes compose', () => {
  const doc = project(cue('last', { start: '20:00', end: '01:00' }));
  const first = model.overlayDay(doc, '2026-11-16', [change({ start: '23:00', end: '' })]);
  const edited = model.overlayDay(first, '2026-11-16', [
    change({ solutionId: 'welcome', start: '23:15', end: '23:30' }),
  ]);
  assert.deepEqual(lineup(edited, '2026-11-16'), [
    ['welcome', 1200, 1380],
    ['break', 1380, 1395],
    ['welcome', 1395, 1410],
    ['break', 1410, 1440],
  ]);
  assert.deepEqual(lineup(edited, '2026-11-17'), [['welcome', 0, 60]]);
});

test('batch edits validate all changes atomically', () => {
  const doc = project(cue('weekly'));
  const before = JSON.stringify(doc);
  for (const changes of [
    [],
    [change(), change()],
    [change(), change({ screenId: 'absent' })],
    [change(), change({ screenId: 'lobby', solutionId: 'absent' })],
    [change({ start: '24:00' })],
    [change({ start: 'tomorrow' })],
    [change({ end: '09:00' })],
    [change({ end: '09:30' })],
  ]) {
    assert.throws(() => model.overlayDay(doc, '2026-11-16', changes));
    assert.equal(JSON.stringify(doc), before);
  }
});

test('replacing the final start of a finite series removes its unscheduled solution reference', () => {
  const series = cue('reference', {
    startDate: '2026-11-09',
    endDate: '2026-11-17',
    excludedDates: ['2026-11-09'],
  });
  assert.equal(model.cueHasOccurrences(series), true);
  assert.equal(model.cueHasOccurrences({ ...series, excludedDates: ['2026-11-09', '2026-11-16'] }), false);
  assert.equal(
    model.cueHasOccurrences({ ...series, endDate: '', excludedDates: ['2026-11-09', '2026-11-16'] }),
    true,
  );
  const result = model.overlayDay(project(series), '2026-11-16', [change({ start: '09:00', end: '10:00' })]);
  assert.deepEqual(
    result.cues.map((item) => item.solutionId),
    ['break'],
  );
});

test('catalog refresh relinks verified aliases and media while preserving local solutions', () => {
  const doc = project(cue('published'), cue('other', { solutionId: 'break', screenId: 'lobby' }));
  doc.solutions[0].source = { playlistUuid: 'old-a' };
  doc.solutions[1].source = { playlistUuid: 'old-b', mediaFingerprint: 'b-hash' };
  doc.solutions.push({ ...doc.solutions[1], id: 'removed', source: { playlistUuid: 'removed' } });
  doc.solutions.push({ ...doc.solutions[1], id: 'local', source: { kind: 'localVideo', assetId: 'sha' } });
  const fresh = [
    { ...doc.solutions[0], id: 'new-a', source: { playlistUuid: 'a', aliases: ['viplex-OLD-A'] } },
    { ...doc.solutions[1], id: 'new-b', source: { playlistUuid: 'b', mediaFingerprint: 'B-hash' } },
  ];
  const before = JSON.stringify(doc);
  const result = model.reconcileCatalog(doc, fresh);
  assert.deepEqual(
    result.cues.map((c) => c.solutionId),
    ['new-a', 'new-b'],
  );
  assert.deepEqual(
    result.solutions.map((s) => s.id),
    ['new-a', 'new-b', 'local'],
  );
  assert.equal(JSON.stringify(doc), before);
});

test('a reused name, conflicting fingerprint or ambiguous alias never retargets an old cue', () => {
  const doc = project(cue('published'));
  const old = doc.solutions[0];
  old.source = { playlistUuid: 'original' };
  const fresh = { ...old, id: 'current', source: { playlistUuid: 'current', mediaFingerprint: 'different' } };
  function checkMissing(candidates) {
    const next = model.reconcileCatalog(doc, candidates);
    assert.equal(next.cues[0].solutionId, old.id);
    assert.equal(next.solutions.find((s) => s.id === old.id).missing, true);
  }
  checkMissing([fresh]);
  old.source.mediaFingerprint = 'original-hash';
  fresh.source.aliases = ['original'];
  checkMissing([fresh]);
  fresh.source.mediaFingerprint = 'original-hash';
  checkMissing([fresh, { ...fresh, id: 'also-current' }]);
  delete fresh.source.aliases;
  checkMissing([fresh, { ...fresh, id: 'other-media-twin' }]);
  const exact = {
    ...fresh,
    id: old.id,
    source: { playlistUuid: 'original', mediaFingerprint: 'new revision' },
  };
  assert.equal(
    model.reconcileCatalog(doc, [fresh, exact]).solutions.find((s) => s.id === old.id),
    exact,
  );
});
