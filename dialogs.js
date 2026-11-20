'use strict';

function optionRow(key, ico, title, description) {
  return `<button class="option-row" type="button" data-option="${key}">${icon(ico, 20)}<span><strong>${esc(title)}</strong><small>${esc(description)}</small></span>${icon('right', 15)}</button>`;
}
function pick(form, key, callback) {
  const item = form.querySelector(`[data-option="${key}"]`);
  if (item) item.onclick = callback;
}
function download(name, body, type) {
  const link = document.createElement('a'),
    url = URL.createObjectURL(new Blob([body], { type }));
  link.href = url;
  link.download = name;
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 30000);
}
function backup() {
  if (loadError && rawRevision !== null) {
    download('Relay browser workspace recovery.json', rawRevision, 'application/json');
    notice('Saved the original browser workspace for recovery');
    return;
  }
  download(`Relay workspace ${day}.json`, JSON.stringify(project, null, 2), 'application/json');
  notice('Workspace backup downloaded');
}
function chooseLanes() {
  if (!project.screens.length) {
    openScreen();
    return;
  }
  const visible = new Set(visibleScreens().map((s) => s.id));
  const form = openDialog({
    title: 'Compare schedules',
    subtitle: 'Choose the schedules you want to see together on the timeline.',
    body: `<div class="pick-list">${project.screens.map((s) => `<label><input type="checkbox" name="screen" value="${esc(s.id)}" ${visible.has(s.id) ? 'checked' : ''}><span><strong>${esc(s.name)}</strong><small>${s.width} × ${s.height}</small></span></label>`).join('')}</div>`,
    extra: '<button type="button" class="btn btn-secondary" data-toggle>Clear selection</button>',
    submitLabel: 'Show lanes',
    onSubmit(form) {
      const ids = new FormData(form).getAll('screen');
      if (!ids.length) throw new Error('Choose at least one lane.');
      filter = ids.length === 1 ? ids[0] : '';
      compare = ids.length === 1 || ids.length === project.screens.length ? [] : ids;
      render();
    },
  });
  const boxes = [...form.querySelectorAll('[name=screen]')],
    toggle = form.querySelector('[data-toggle]');
  function label() {
    toggle.textContent = boxes.some((b) => b.checked) ? 'Clear selection' : 'Select all';
  }
  toggle.onclick = () => {
    const check = !boxes.some((b) => b.checked);
    boxes.forEach((b) => (b.checked = check));
    label();
  };
  form.addEventListener('change', label);
  label();
}
function openScreen(id) {
  const s = project.screens.find((row) => row.id === id);
  const currentCount = s && s.height === 1080 && Number.isInteger(s.width / 320) && s.width >= 320 && s.width <= 1920
    ? s.width / 320 : null;
  const keepExisting = Boolean(s && currentCount === null);
  const selectedCount = keepExisting ? 'existing' : String(currentCount || 6);
  function canvasFor(value) {
    if (value === 'existing' && keepExisting) return { width: s.width, height: s.height };
    if (!/^[1-6]$/.test(value)) throw new Error('Choose between 1 and 6 boards.');
    return { width: Number(value) * 320, height: 1080 };
  }
  const options = Array.from({ length: 6 }, (_, i) => i + 1).map((count) =>
    `<option value="${count}" ${String(count) === selectedCount ? 'selected' : ''}>${count} ${count === 1 ? 'board' : 'boards'} (${count * 320} px wide)</option>`,
  ).join('');
  const form = openDialog({
    title: s ? 'Edit schedule' : 'Add a schedule',
    subtitle: 'Choose how many boards this schedule spans. Each board is 320 × 1080 px.',
    body: `<div class="form-grid"><label class="field span-2">Schedule name<input name="screenName" value="${esc(s?.name || '')}" placeholder="e.g. Lobby portrait" required maxlength="100" autofocus></label><label class="field span-2">Number of boards<select name="boardCount" required aria-describedby="screen-canvas-preview">${keepExisting ? `<option value="existing" selected>Keep existing canvas (${esc(s.width)} × ${esc(s.height)} px)</option>` : ''}${options}</select></label><p class="field-help span-2" id="screen-canvas-preview" data-screen-canvas aria-live="polite"></p></div>`,
    submitLabel: s ? 'Save schedule' : 'Add schedule',
    extra: s ? '<button class="btn btn-danger" type="button" data-remove>Remove schedule</button>' : '',
    onSubmit(form) {
      const data = new FormData(form),
        canvas = canvasFor(data.get('boardCount')),
        screen = {
          ...s,
          id: s?.id || uid(),
          name: data.get('screenName').trim(),
          width: canvas.width,
          height: canvas.height,
        };
      if (
        project.screens.some(
          (old) => old.id !== screen.id && old.name.toLowerCase() === screen.name.toLowerCase(),
        )
      )
        throw new Error('A schedule with this name already exists.');
      return commit(
        {
          ...project,
          screens: s
            ? project.screens.map((old) => (old.id === s.id ? screen : old))
            : [...project.screens, screen],
        },
        s ? 'Schedule updated' : 'Schedule added',
      );
    },
  });
  const countSelect = form.elements.boardCount;
  function updateCanvas() {
    const canvas = canvasFor(countSelect.value);
    form.querySelector('[data-screen-canvas]').textContent =
      `Schedule canvas: ${canvas.width} × ${canvas.height} px.` + (countSelect.value === 'existing'
        ? ' Your existing dimensions will be preserved.'
        : Number(countSelect.value) > 1 ? ' Boards are arranged side by side.' : ' One portrait board.');
  }
  countSelect.onchange = updateCanvas;
  updateCanvas();
  if (s)
    form.querySelector('[data-remove]').onclick = () =>
      openDialog({
        title: 'Remove this schedule?',
        body: `<p class="dialog-copy">Remove ${esc(s.name)} and its ${project.cues.filter((c) => c.screenId === s.id).length} blocks from this workspace?</p>`,
        submitLabel: 'Remove schedule',
        onSubmit: () =>
          commit(
            {
              ...project,
              screens: project.screens.filter((row) => row.id !== s.id),
              cues: project.cues.filter((c) => c.screenId !== s.id),
            },
            'Schedule removed',
          ),
      });
}
function openSolution() {
  openDialog({
    title: 'Add a solution reference',
    subtitle:
      'Use a local reference to plan content you’ll author later. ViPlex package export uses solutions from your linked library.',
    body: `<div class="form-grid"><label class="field span-2">Solution name<input name="solutionName" required maxlength="160" placeholder="e.g. Doors open" autofocus></label><label class="field">Width (px)<input type="number" min="1" name="width" required value="1920"></label><label class="field">Height (px)<input type="number" min="1" name="height" required value="1080"></label></div>`,
    submitLabel: 'Add solution',
    async onSubmit(form) {
      const data = new FormData(form),
        name = data.get('solutionName').trim();
      if (project.solutions.some((s) => s.name.toLowerCase() === name.toLowerCase()))
        throw new Error('A solution with this name already exists.');
      const solution = {
        id: uid(),
        name,
        width: Number(data.get('width')),
        height: Number(data.get('height')),
        color: '#5d7955',
      };
      await commit({ ...project, solutions: [...project.solutions, solution] }, 'Solution reference added');
      if (page === 'solutions') {
        inspectedSolutionId = solution.id;
        libraryType = 'all';
        query = '';
        render();
        revealInspectedSolution();
      }
    },
  });
}
function projectMenu() {
  const form = openDialog({
    title: 'Workspace',
    body: `<div class="option-list">${optionRow('backup', 'export', 'Save project file', 'Back up all schedules, solution references and scheduling rules.')}${optionRow('open', 'folder', 'Open project file', 'Restore a Relay Studio JSON backup.')}${optionRow('native', 'import', 'Load ViPlex schedules', 'Choose native schedules to copy into this board.')}${optionRow('new', 'plus', 'New board', 'Start with your solution library and empty schedules.')}</div>`,
  });
  pick(form, 'backup', () => {
    backup();
    closeDialog();
  });
  pick(form, 'open', () => $('#project-file').click());
  pick(form, 'native', () => loadNative());
  pick(
    form,
    'new',
    () =>
      (openDialog({
        title: 'Start a new board?',
        body: '<p class="dialog-copy">The new board starts with your current solution library and no schedules. Save a project file to keep a copy of your current board.</p>',
        extra: '<button type="button" data-backup class="btn btn-secondary">Save project file</button>',
        submitLabel: 'Start new board',
        onSubmit: async () => {
          await commit(
            { version: 1, title: 'Local workspace', screens: [], solutions: project.solutions, cues: [] },
            'New board created',
          );
          goNav('screens');
        },
      }).querySelector('[data-backup]').onclick = backup),
  );
}
$('#project-file').addEventListener('change', async (e) => {
  const file = e.target.files[0];
  if (!file) return;
  try {
    const incoming = M.validateProject(JSON.parse((await file.text()).replace(/^\uFEFF/, '')));
    openDialog({
      title: 'Open project file?',
      body: `<p class="dialog-copy"><strong>${esc(file.name)}</strong> contains ${incoming.screens.length} schedules, ${incoming.solutions.length} solutions and ${incoming.cues.length} scheduling rules. Opening it replaces the current board.</p>`,
      submitLabel: 'Open project',
      onSubmit: async () => {
        await commit(incoming, 'Project opened', true);
        goNav('schedule');
      },
    });
  } catch (err) {
    openDialog({ title: 'Cannot open project', body: `<p class="dialog-copy">${esc(err.message)}</p>` });
  } finally {
    e.target.value = '';
  }
});
async function loadNative() {
  try {
    catalog = await fetchCatalog();
  } catch (e) {
    openDialog({ title: 'Library unavailable', body: `<p class="dialog-copy">${esc(e.message)}</p>` });
    return;
  }
  const native = catalog.schedules;
  if (!native.length) {
    openDialog({
      title: 'No ViPlex schedules found',
      body: '<p class="dialog-copy">Save a schedule in ViPlex Express, then load it here.</p>',
    });
    return;
  }
  openDialog({
    title: 'Load ViPlex schedules',
    subtitle: 'Selected schedules replace their matching lanes. Other lanes keep their edits.',
    body: `<div class="pick-list">${native.map((s, i) => `<label><input type="checkbox" name="schedule" value="${i}"><span><strong>${esc(s.name)}</strong><small>${s.cues.length} rules · ${s.width} × ${s.height}${s.warning ? ` · ${esc(s.warning)}` : ''}</small></span></label>`).join('')}</div>`,
    submitLabel: 'Load selected',
    onSubmit(form) {
      const picked = new FormData(form).getAll('schedule').map((n) => native[Number(n)]);
      if (!picked.length) throw new Error('Choose at least one schedule.');
      const p = M.reconcileCatalog(project, catalog.solutions);
      p.screens = [...p.screens];
      for (const s of picked) {
        let lane = p.screens.find((l) => l.sourceSchedule === s.id);
        if (!lane) {
          lane = { id: uid(), name: s.name, width: s.width, height: s.height, sourceSchedule: s.id };
          p.screens.push(lane);
        }
        p.screens = p.screens.map((l) =>
          l.id === lane.id ? { ...lane, width: s.width, height: s.height, warning: s.warning || '' } : l,
        );
        p.cues = p.cues
          .filter((c) => c.screenId !== lane.id)
          .concat(s.cues.map((c) => ({ ...c, id: uid(), screenId: lane.id })));
      }
      return commit(p, `Loaded ${picked.length} ViPlex ${picked.length === 1 ? 'schedule' : 'schedules'}`);
    },
  });
}
function csvCell(value) {
  let text = String(value);
  if (/^[\s]*[=+@\-\t\r]/.test(text)) text = "'" + text;
  return `"${text.replace(/"/g, '""')}"`;
}
function exportRunSheet() {
  const rows = [['Date', 'Start', 'End', 'Schedule', 'Solution', 'Width (px)', 'Height (px)']];
  for (const o of visibleOccurrences()) {
    const screen = getScreen(o.cue.screenId),
      s = getSolution(o.cue.solutionId);
    rows.push([day, clock(o.startMinute), clock(o.endMinute), screen.name, s.name, s.width, s.height]);
  }
  download(
    `Run sheet ${day}.csv`,
    '\uFEFF' + rows.map((r) => r.map(csvCell).join(',')).join('\r\n'),
    'text/csv;charset=utf-8',
  );
  closeDialog();
  notice('Run sheet downloaded');
}
function exportMenu() {
  const form = openDialog({
    title: 'Export',
    body: `<div class="option-list">${optionRow('network', 'network', 'Network playback', 'Send a schedule to a player over the local network.')}${optionRow('usb', 'drive', 'USB playback', 'Prepare a schedule for USB playback. Export individual solutions from Solution library.')}${optionRow('native', 'screen', 'ViPlex schedule import', 'Create packages for ViPlex Express → Schedule → Import.')}${optionRow('csv', 'list', 'Run sheet (.csv)', `All visible lanes on ${formatDate(day, { dateStyle: 'long' })}, ordered by switch time.`)}${optionRow('json', 'file', 'Project backup (.json)', 'Save all schedules and dates so you can reopen the board in Relay Studio.')}</div>`,
  });
  pick(form, 'native', nativeExport);
  pick(form, 'usb', () => openUsbPlayback());
  pick(form, 'network', () => openNetworkPlayback());
  pick(form, 'csv', exportRunSheet);
  pick(form, 'json', () => {
    backup();
    closeDialog();
  });
}
function nativeExport() {
  const activeProject = { ...project, cues: project.cues.filter(M.cueHasOccurrences) };
  const lanes = project.screens.filter((s) => activeProject.cues.some((c) => c.screenId === s.id));
  if (!lanes.length) {
    openDialog({
      title: 'No schedules with blocks',
      body: '<p class="dialog-copy">Schedule at least one solution before exporting.</p>',
    });
    return;
  }
  const existingNames = new Set(catalog.schedules.map((s) => s.name.toLowerCase()));
  const names = new Map();
  for (const lane of lanes) {
    const base = 'Relay' + (lane.name.replace(/[^a-z0-9]/gi, '').slice(0, 32) || 'Schedule');
    let name = base,
      version = 2;
    while (existingNames.has(name.toLowerCase())) name = base + 'V' + version++;
    names.set(lane.id, name);
    existingNames.add(name.toLowerCase());
  }
  const form = openDialog({
    title: 'Export for ViPlex import',
    subtitle: 'Choose schedules to import into ViPlex Express. Each gets its own media folder.',
    body: `<label class="check-row select-all"><input type="checkbox" id="toggle-all"> Select all schedules</label><div class="export-head"><span>Schedule</span><span>Name in ViPlex</span></div><div class="export-list">${lanes.map((s, i) => `<div class="export-line"><label><input type="checkbox" name="screen" value="${esc(s.id)}" ${filter === s.id || compare.includes(s.id) || lanes.length === 1 ? 'checked' : ''}><span>${esc(s.name)}</span></label><input data-export-name="${i}" aria-label="Name in ViPlex for ${esc(s.name)}" maxlength="48" value="${esc(names.get(s.id))}"></div>`).join('')}</div><p class="field-help" data-progress>Use letters and numbers for names that are easy to find after import.</p>`,
    submitLabel: 'Create packages',
    onSubmit: async (form) => {
      const ids = new FormData(form).getAll('screen');
      if (!ids.length) throw new Error('Choose at least one schedule.');
      const scheduleNames = Object.create(null),
        usedNames = new Set();
      for (const id of ids) {
        const field = form.querySelector(`[data-export-name="${lanes.findIndex((s) => s.id === id)}"]`);
        const name = field.value.trim();
        if (!/^[A-Za-z0-9]{1,48}$/.test(name))
          throw new Error(`Choose a name with 1–48 letters or digits for ${getScreen(id).name}.`);
        if (usedNames.has(name.toLowerCase()))
          throw new Error(`Two lanes use the ViPlex name “${name}”. Give each one a different name.`);
        scheduleNames[id] = name;
        usedNames.add(name.toLowerCase());
        const used = activeProject.cues
          .filter((c) => c.screenId === id)
          .map((c) => getSolution(c.solutionId));
        const local = used.find((s) => !s?.source?.playlistUuid && !['localVideo', 'localImage'].includes(s?.source?.kind));
        if (local)
          throw new Error(
            `${getScreen(id).name} uses the local reference “${local.name}”. Choose a ViPlex library solution for this block before exporting.`,
          );
        const missing = used.find((s) => s.missing);
        if (missing)
          throw new Error(
            `“${missing.name}” on ${getScreen(id).name} is missing from ViPlex. Assign an available solution to its blocks.`,
          );
      }
      const info = form.querySelector('[data-progress]');
      info.textContent = 'Building schedules and verifying media. This may take a moment…';
      const active = form.querySelectorAll('input,button');
      active.forEach((node) => (node.disabled = true));
      try {
        const session = await fetch('/api/session', { cache: 'no-store' });
        if (!session.ok) throw new Error('Open Launch Studio.cmd to export a native package.');
        const { exportToken } = await session.json();
        const response = await fetch('/api/export-viplex', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'X-Studio-Token': exportToken },
          body: JSON.stringify(
            ids.length === 1
              ? { project: activeProject, screenId: ids[0], scheduleNames }
              : { project: activeProject, screenIds: ids, scheduleNames },
          ),
        });
        const result = await response.json();
        if (!response.ok || result.error) throw new Error(result.error || 'Export failed.');
        const actual = (Array.isArray(result.metadata) ? result.metadata : [result.metadata]).map(
          (m, i) => m?.scheduleName || scheduleNames[ids[i]],
        );
        const done = openDialog({
          title: 'ViPlex import packages created',
          body: `<p class="dialog-copy">After import, look for ${actual.map((name) => `<strong>${esc(name)}</strong>`).join(', ')} in ViPlex’s <strong>Schedule</strong> list.</p><p class="success-path">${esc(result.path)}</p><p class="field-help">In ViPlex Express, open Schedule → Import and select the folder containing <strong>nova</strong> for the schedule you want. Review the imported schedule before publishing.</p>`,
          extra: '<button class="btn btn-secondary" type="button" data-copy>Copy folder path</button>',
        });
        done.querySelector('[data-copy]').onclick = async (e) => {
          try {
            await navigator.clipboard.writeText(result.path);
            e.target.textContent = 'Copied';
          } catch {
            notice('Select the folder path to copy it.');
          }
        };
        return false;
      } finally {
        active.forEach((node) => (node.disabled = false));
        info.textContent = 'Packages are saved under Documents / Relay Studio Exports.';
      }
    },
  });
  const all = form.querySelector('#toggle-all'),
    boxes = [...form.querySelectorAll('[name=screen]')];
  function reconcile() {
    all.checked = boxes.every((b) => b.checked);
    all.indeterminate = !all.checked && boxes.some((b) => b.checked);
  }
  all.onchange = () => {
    boxes.forEach((b) => (b.checked = all.checked));
    reconcile();
  };
  boxes.forEach((b) => (b.onchange = reconcile));
  reconcile();
}
