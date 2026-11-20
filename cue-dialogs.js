(function cueDialogs() {
  'use strict';

  const days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const field = (label, input, wide = false) =>
    `<label class="field${wide ? ' span-2' : ''}"><span>${label}</span>${input}</label>`;
  const nativeTime = (value) => value === '24:00' ? '00:00' : value;
  const gridMessage = 'Choose a quarter hour (00, 15, 30 or 45 minutes).';
  function timeInput(name, value, required = true) {
    // Existing ViPlex times may sit between quarters. Let the user retain each original endpoint.
    const offGrid = value && StudioModel.timeMinutes(value) % StudioModel.blockMinutes;
    const step = offGrid ? 60 : StudioModel.blockMinutes * 60;
    return `<input type="time" name="${name}" min="00:00" step="${step}" value="${Relay.esc(nativeTime(value))}"${required ? ' required' : ''}>`;
  }
  function checkQuarter(input, original = '') {
    const value = input.value;
    const valid = !value || value === nativeTime(original) ||
      StudioModel.timeMinutes(value) % StudioModel.blockMinutes === 0;
    input.setCustomValidity(valid ? '' : gridMessage);
    return valid;
  }

  function options(items, selected, duplicateNames = new Set()) {
    return items
      .map(
        (item) =>
          `<option value="${Relay.esc(item.id)}"${item.id === selected ? ' selected' : ''}${item.missing && item.id !== selected ? ' disabled' : ''}>${Relay.esc(item.name)}${duplicateNames.has(item.name) ? ' · ' + Relay.esc(item.importPath || item.source?.fileName || item.width + ' × ' + item.height) : ''}${item.missing ? ' (missing in ViPlex)' : ''}</option>`,
      )
      .join('');
  }

  function solutionOptions(screenId, selected) {
    const screen = Relay.project.screens.find((row) => row.id === screenId);
    const sorted = [...Relay.project.solutions].sort((a, b) =>
      a.name.localeCompare(b.name, undefined, { numeric: true }),
    );
    const seen = new Set(),
      duplicates = new Set();
    for (const item of sorted) {
      if (seen.has(item.name)) duplicates.add(item.name);
      seen.add(item.name);
    }
    let html = '<option value="">Choose a solution…</option>';
    if (!screen) return html + options(sorted, selected, duplicates);
    const matching = sorted.filter((item) => item.width === screen.width && item.height === screen.height);
    const other = sorted.filter((item) => item.width !== screen.width || item.height !== screen.height);
    if (matching.length && other.length) {
      return `${html}<optgroup label="Matching schedule size">${options(matching, selected, duplicates)}</optgroup><optgroup label="Other sizes">${options(other, selected, duplicates)}</optgroup>`;
    }
    return html + options(sorted, selected, duplicates);
  }

  function ready() {
    if (!Relay.project.screens.length) Relay.notice('Add a schedule before scheduling a solution.');
    else if (!Relay.project.solutions.length) Relay.notice('Add a solution to your library first.');
    else return true;
    return false;
  }

  function changeEnd(time) {
    // Native time inputs express midnight as 00:00.
    return time === '00:00' ? '24:00' : time;
  }

  function selectedMinute() {
    return Number.isInteger(Relay.playhead) && Relay.playhead >= 0 && Relay.playhead < 1440
      ? Relay.playhead
      : 540;
  }

  function openCue(preset = {}) {
    if (!ready()) return;
    const before = Relay.project;
    const saved = preset.id ? before.cues.find((cue) => cue.id === preset.id) : null;
    if (preset.id && !saved) return Relay.notice('That block is no longer in the schedule.');
    const screenId = saved?.screenId || preset.screenId || Relay.filter || before.screens[0].id;
    const solutionId = saved?.solutionId || preset.solutionId || '';
    const start = saved?.start || preset.start ||
      Relay.clock(StudioModel.suggestBlockStart(before, Relay.date, screenId, selectedMinute()));
    const end = saved?.end || preset.end || Relay.clock(StudioModel.timeMinutes(start) + StudioModel.blockMinutes);
    const date = saved?.startDate || Relay.date;
    const repeat = Boolean(saved && saved.startDate !== saved.endDate);
    const selectedDays = saved?.days || [StudioModel.weekday(date)];
    const dayBoxes = days
      .map(
        (label, day) =>
          `<label><input type="checkbox" name="days" value="${day}"${selectedDays.includes(day) ? ' checked' : ''}> ${label}</label>`,
      )
      .join('');
    const repeatSelect = `<select name="repeat"><option value="once">Does not repeat</option><option value="weekly"${repeat ? ' selected' : ''}>Weekly</option></select>`;
    const dateInput = `<input type="date" name="firstDate" value="${Relay.esc(date)}" required>`;
    const lastDate = `<input type="date" name="lastDate" value="${Relay.esc(repeat ? saved.endDate : '')}">`;
    const body = `<div class="form-grid">
      ${field('Schedule', `<select name="screenId" required>${options(before.screens, screenId)}</select>`)}
      ${field('Solution', `<select name="solutionId" required>${solutionOptions(screenId, solutionId)}</select>`)}
      ${field('Start time', timeInput('start', start))}
      ${field('End time', timeInput('end', end))}
      <div class="field-help span-2" data-duration></div>
      ${field('<span data-date-label>Date</span>', dateInput)}
      ${field('Repeat', repeatSelect)}
      <div class="field span-2" data-weekly><span id="repeat-days-title">Repeat on</span><div class="check-row" role="group" aria-labelledby="repeat-days-title">${dayBoxes}</div></div>
      <div class="field span-2" data-weekly>${field('Last date (optional)', lastDate)}</div>
      ${saved?.excludedDates?.length ? `<p class="field-help span-2">This series has ${saved.excludedDates.length} date ${saved.excludedDates.length === 1 ? 'exception' : 'exceptions'} from individual day changes.</p>` : ''}
    </div>`;
    Relay.openDialog({
      title: saved ? (repeat ? 'Edit recurring block' : 'Edit block') : 'Add a block',
      subtitle: repeat ? 'Saving updates the entire series, across all of its scheduled days.' : undefined,
      body,
      submitLabel: saved ? 'Save changes' : 'Add block',
      extra: saved
        ? `<button type="button" class="btn btn-danger" data-delete>${repeat ? 'Delete series' : 'Delete block'}</button>`
        : '',
      onSubmit(form) {
        if (!checkQuarter(form.elements.start, saved?.start) || !checkQuarter(form.elements.end, saved?.end))
          throw new Error(gridMessage);
        const fields = new FormData(form);
        const weekly = fields.get('repeat') === 'weekly';
        const startDate = fields.get('firstDate');
        const cue = {
          ...saved,
          id: saved?.id || Relay.uid(),
          screenId: fields.get('screenId'),
          solutionId: fields.get('solutionId'),
          startDate,
          endDate: weekly ? fields.get('lastDate') : startDate,
          start: fields.get('start'),
          end: saved && fields.get('end') === nativeTime(saved.end) ? saved.end : changeEnd(fields.get('end')),
          days: weekly ? fields.getAll('days').map(Number) : [StudioModel.weekday(startDate)],
        };
        if (!weekly) delete cue.excludedDates;
        const project = Relay.project;
        const cues = saved
          ? project.cues.map((item) => (item.id === cue.id ? cue : item))
          : [...project.cues, cue];
        const result = StudioModel.validateProject({ ...project, cues });
        return Relay.commit(result, saved ? 'Block updated.' : 'Block added.');
      },
    });

    const dialog = document.querySelector('#dialog');
    const form = dialog.querySelector('form');
    const controls = form.elements;
    function update() {
      const weekly = controls.repeat.value === 'weekly';
      for (const element of form.querySelectorAll('[data-weekly]')) element.hidden = !weekly;
      controls.lastDate.disabled = !weekly;
      controls.lastDate.min = controls.firstDate.value;
      form.querySelector('[data-date-label]').textContent = weekly ? 'First date' : 'Date';
      const note = form.querySelector('[data-duration]');
      const startValid = checkQuarter(controls.start, saved?.start);
      const endValid = checkQuarter(controls.end, saved?.end);
      if (!startValid || !endValid) {
        note.textContent = gridMessage;
        return;
      }
      if (!controls.start.value || !controls.end.value) {
        note.textContent = '';
        return;
      }
      const from = StudioModel.timeMinutes(controls.start.value);
      const to = StudioModel.timeMinutes(changeEnd(controls.end.value));
      const duration = (to - from + 1440) % 1440 || (from === 0 && to === 1440 ? 1440 : 0);
      const hours = Math.floor(duration / 60),
        minutes = duration % 60;
      const length = [hours && `${hours} hr`, minutes && `${minutes} min`].filter(Boolean).join(' ');
      const gridHint = saved ? 'New times use quarter hours' : `${StudioModel.blockMinutes}-minute increments`;
      note.textContent = duration
        ? `${length}${to < from ? ' · Ends the following day' : ''} · ${gridHint}`
        : 'Choose different start and end times.';
    }
    if (!saved) {
      const initialLength = StudioModel.timeMinutes(end) - StudioModel.timeMinutes(start);
      let endEdited = false;
      controls.end.addEventListener('input', () => { endEdited = true; });
      controls.start.addEventListener('change', () => {
        if (!endEdited && controls.start.value && checkQuarter(controls.start)) {
          const from = StudioModel.timeMinutes(controls.start.value);
          controls.end.value = Relay.clock((from + initialLength) % 1440);
          update();
        }
      });
    }
    controls.screenId.addEventListener('change', () => {
      controls.solutionId.innerHTML = solutionOptions(controls.screenId.value, controls.solutionId.value);
    });
    form.addEventListener('input', update);
    update();

    const remove = dialog.querySelector('[data-delete]');
    if (remove) {
      remove.addEventListener('click', async () => {
        const target = repeat ? 'every occurrence of this series' : 'this block';
        if (!window.confirm(`Delete ${target} from the schedule?`)) return;
        try {
          const project = Relay.project;
          const result = { ...project, cues: project.cues.filter((item) => item.id !== saved.id) };
          const committed = await Relay.commit(result, repeat ? 'Series deleted.' : 'Block deleted.');
          if (committed !== false) Relay.closeDialog();
        } catch (error) {
          Relay.notice(error.message);
        }
      });
    }
  }

  function openSync() {
    if (!ready()) return;
    const project = Relay.project;
    const rows = project.screens
      .map(
        (screen, index) => `<div class="sync-row" data-sync-index="${index}">
      <label class="sync-screen"><input type="checkbox" name="lane"${Relay.selectedScreenIds.includes(screen.id) ? ' checked' : ''}> <span>${Relay.esc(screen.name)}</span></label>
      <select aria-label="Solution for ${Relay.esc(screen.name)}">${solutionOptions(screen.id, '')}</select>
      <span class="field-help" data-impact></span>
    </div>`,
      )
      .join('');
    const body = `<div class="form-grid">
      ${field('Date', `<input type="date" name="date" value="${Relay.esc(Relay.date)}" required>`, true)}
      ${field('Start together at', timeInput('start', Relay.clock(StudioModel.nextQuarterStart(selectedMinute()))))}
      ${field('End time (optional)', timeInput('end', '', false))}
      <p class="field-help span-2">Leave the end blank to run until each schedule’s next block, or midnight.</p>
    </div>
    <div class="sync-list">${rows}</div>
    <div class="field-help" data-summary aria-live="polite"></div>`;
    Relay.openDialog({
      title: 'Coordinated change',
      subtitle: 'Choose a solution for each schedule that should change on this date.',
      body,
      wide: true,
      submitLabel: 'Apply change',
      onSubmit(form) {
        if (!checkQuarter(form.elements.start) || !checkQuarter(form.elements.end))
          throw new Error(gridMessage);
        const date = form.elements.date.value;
        const changes = selectedChanges(form);
        const result = StudioModel.overlayDay(Relay.project, date, changes);
        return Relay.commit(
          result,
          `Change scheduled on ${changes.length} ${changes.length === 1 ? 'schedule' : 'schedules'}.`,
        );
      },
    });

    const form = document.querySelector('#dialog form');
    const laneRows = [...form.querySelectorAll('[data-sync-index]')];
    const submit = form.querySelector('button[type="submit"]');
    const summary = form.querySelector('[data-summary]');
    function selectedChanges(form) {
      const start = form.elements.start.value,
        end = changeEnd(form.elements.end.value);
      return laneRows
        .filter((row) => row.querySelector('input').checked)
        .map((row) => ({
          screenId: project.screens[Number(row.dataset.syncIndex)].id,
          solutionId: row.querySelector('select').value,
          start,
          end,
        }));
    }
    function update() {
      const { date, start, end } = form.elements;
      let problem = '',
        from,
        until;
      try {
        StudioModel.weekday(date.value);
        from = StudioModel.timeMinutes(start.value);
        until = end.value ? StudioModel.timeMinutes(changeEnd(end.value)) : null;
        if (until !== null && until <= from) problem = 'Choose an end time after the start on this date.';
        const startValid = checkQuarter(start);
        const endValid = checkQuarter(end);
        if (!startValid || !endValid) problem = gridMessage;
      } catch {
        problem = 'Choose a valid date and start time.';
      }
      const filled = selectedChanges(form);
      for (const row of laneRows) {
        const checkbox = row.querySelector('input');
        const hint = row.querySelector('[data-impact]');
        hint.textContent = '';
        hint.hidden = true;
        if (!checkbox.checked || problem) continue;
        const screen = project.screens[Number(row.dataset.syncIndex)];
        const schedule = StudioModel.occurrences(project, date.value, screen.id);
        const to = until ?? schedule.find((cue) => cue.startMinute > from)?.startMinute ?? 1440;
        const affected = schedule.filter((cue) => cue.startMinute < to && cue.endMinute > from);
        const label = to === 1440 ? 'midnight' : Relay.clock(to);
        hint.textContent = `Until ${label} · ${affected.length ? `${affected.length} ${affected.length === 1 ? 'block' : 'blocks'} affected` : 'Open time'}`;
        hint.hidden = false;
      }
      if (!problem && !filled.length) problem = 'Choose at least one schedule.';
      if (!problem && filled.some((change) => !change.solutionId))
        problem = 'Choose a solution for each selected schedule.';
      summary.textContent =
        problem ||
        `${filled.length} ${filled.length === 1 ? 'schedule' : 'schedules'} will change at ${start.value} on ${date.value}.`;
      if (submit) submit.disabled = Boolean(problem);
    }
    for (const row of laneRows) {
      row.querySelector('select').addEventListener('change', (event) => {
        if (event.target.value) row.querySelector('input').checked = true;
        update();
      });
    }
    form.addEventListener('input', update);
    form.addEventListener('change', update);
    update();
  }

  Object.assign(globalThis, { openCue, openSync });
})();
