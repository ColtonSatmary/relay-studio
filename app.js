'use strict';

// Static files are reread on every request, but the local service keeps its
// loaded PowerShell functions. Never pair a new interface with an old worker.
const studioRuntimeBuild = '2026.11.19.2';
let studioRuntimeProblem = '';
function isLegacyStudioRuntime() {
  return location.hostname === '127.0.0.1' && location.port === '47832';
}
async function checkStudioRuntime() {
  if (location.protocol === 'file:') return true;
  const controller = new AbortController(), timeout = setTimeout(() => controller.abort(), 10000);
  try {
    const response = await fetch('/api/session', { cache: 'no-store', signal: controller.signal });
    if (!response.ok) throw new Error('The local service is unavailable.');
    const session = await response.json();
    if (session.runtimeBuild !== studioRuntimeBuild) {
      // The already-running, verified 2026.11.19.2 service predates build IDs.
      // Accept only that release's known origin and routes. A future build bump
      // must not use this exception to accept a different old service.
      if (session.runtimeBuild === undefined && studioRuntimeBuild === '2026.11.19.2' && location.hostname === '127.0.0.1' && location.port === '47833') {
        const [health, controls] = await Promise.all([
          fetch('/api/health', { cache: 'no-store', signal: controller.signal }),
          fetch('/bulk-controls.js', { cache: 'no-store', signal: controller.signal }),
        ]);
        if (health.ok && controls.ok && (await health.text()).startsWith('viplex-schedule-studio/')) return true;
      }
      if (isLegacyStudioRuntime()) {
        studioRuntimeProblem = 'This window is connected to an older Relay service. Open the updated app before uploading or changing player settings.';
        return false;
      }
      studioRuntimeProblem = 'The Relay service in this window needs an update before it can use these player controls and uploads. Open the updated app using the launcher.';
      return false;
    }
    return true;
  } catch {
    studioRuntimeProblem = 'Relay could not reach the local service. Open Launch Studio.cmd, then check again.';
    return false;
  } finally { clearTimeout(timeout); }
}
// Other startup work, including automatic player connections, uses this same
// decision. Assign immediately so later deferred scripts can await it.
window.studioRuntimeReady = checkStudioRuntime();
function showStudioRuntimeNotice() {
  let browserCopy = '';
  try { browserCopy = localStorage.getItem('relay-studio-project-v1') || ''; } catch { /* Saved disk data remains available. */ }
  $('#app').innerHTML = `<main class="panel" style="width:min(680px,calc(100% - 40px));margin:60px auto;padding:28px">
    <h1>Open updated Relay Studio</h1><p>${esc(studioRuntimeProblem)}</p>
    <p>Your saved workspace is shared with the updated app. This window's browser copy stays here.</p>
    <div class="title-actions"><a class="btn btn-primary" href="http://127.0.0.1:47833/" target="_blank" rel="noopener">Open updated Relay</a>
    <button class="btn btn-secondary" type="button" data-runtime-retry>Check again</button>
    ${browserCopy ? '<button class="btn btn-secondary" type="button" data-runtime-backup>Download browser workspace copy</button>' : ''}</div>
    ${browserCopy ? '<p class="field-help">Keep this JSON copy if you need to recover edits from this older window. Open it through Project in the updated app only if needed.</p>' : ''}
  </main>`;
  $('[data-runtime-retry]').onclick = () => location.reload();
  if (browserCopy) $('[data-runtime-backup]').onclick = () => download('Relay browser workspace recovery.json', browserCopy, 'application/json');
}

const M = window.StudioModel;
const storageKey = 'relay-studio-project-v1';
const clockSettingKey = 'relay-studio-sync-browser-time';
const $ = (selector) => document.querySelector(selector);
const esc = (value) =>
  String(value ?? '').replace(
    /[&<>"']/g,
    (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[char],
  );
const uid = () => crypto.randomUUID?.() || `relay-${Date.now()}-${Math.random().toString(36).slice(2)}`;
const clock = (minute) =>
  `${String(Math.floor(minute / 60)).padStart(2, '0')}:${String(minute % 60).padStart(2, '0')}`;
const formatDate = (day, options) =>
  new Intl.DateTimeFormat('en-US', options).format(new Date(`${day}T12:00:00`));
const icons = {
  calendar:
    '<rect x="3.5" y="5" width="17" height="16" rx="2.5"/><path d="M7.5 3v4m9-4v4M4 10h16m-12 4h2m3 0h2"/>',
  shelf:
    '<rect x="3" y="3.5" width="7" height="7" rx="1.5"/><rect x="14" y="3.5" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',
  screen: '<rect x="2.5" y="4" width="19" height="13.5" rx="2"/><path d="M12 17.5v3M8 21h8"/>',
  screens: '<rect x="6" y="3" width="15.5" height="11" rx="1.5"/><path d="M3 7v10h13m-7 0v3m-4 0h8"/>',
  layers: '<path d="m12 3 9 5-9 5-9-5 9-5Zm-8.5 9 8.5 5 8.5-5m-17 4 8.5 5 8.5-5"/>',
  timeline: '<path d="M4 4v16h17M8 7h8m-5 5h9m-12 5h5"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  left: '<path d="m14.5 5-7 7 7 7"/>',
  right: '<path d="m9 5 7 7-7 7"/>',
  down: '<path d="m6 9 6 6 6-6"/>',
  arrow: '<path d="M4 12h15m-6-6 6 6-6 6"/>',
  out: '<path d="M6 18 18 6M8 6h10v10"/>',
  x: '<path d="m6 6 12 12M18 6 6 18"/>',
  sync: '<path d="M3 6h11m4 0h3M3 12h3m4 0h11M3 18h11m4 0h3"/><rect x="14" y="3.5" width="4" height="5" rx="1"/><rect x="6" y="9.5" width="4" height="5" rx="1"/><rect x="14" y="15.5" width="4" height="5" rx="1"/>',
  blocks:
    '<rect x="3" y="5" width="12" height="5.5" rx="1"/><rect x="8" y="14" width="13" height="5.5" rx="1"/>',
  time: '<circle cx="12" cy="12" r="8.5"/><path d="M12 6v6l4 2"/>',
  file: '<path d="M5 3h9l5 5v13H5zM14 3v6h5M8 13h8m-8 4h7"/>',
  check: '<path d="m4.5 12.5 5 5 10-11"/>',
  save: '<path d="m9 13 2 2 4-4"/><path d="M6 17a4.5 4.5 0 0 1-.5-9A6.5 6.5 0 0 1 18 7.5 5 5 0 0 1 18 17"/>',
  list: '<path d="M8 6h12M8 12h12M8 18h12M3.5 6h.5m-.5 6h.5m-.5 6h.5"/>',
  folder: '<path d="M3 8V5h6l2 2h10v12H3z"/>',
  play: '<path d="m8 5 11 7-11 7z"/>',
  locate:
    '<circle cx="12" cy="12" r="7"/><circle cx="12" cy="12" r="2"/><path d="M12 2v3m0 14v3M2 12h3m14 0h3"/>',
  export: '<path d="M12 15V3m-5 5 5-5 5 5M4 14v6h16v-6"/>',
  import: '<path d="M12 3v12m-5-5 5 5 5-5M4 15v5h16v-5"/>',
  menu: '<path d="M3 6h18M3 12h18M3 18h18"/>',
  search: '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m15.5 15.5 5 5"/>',
  drive: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 14h18m-4 3h1"/>',
  network: '<rect x="8" y="3" width="8" height="5" rx="1"/><rect x="2" y="16" width="7" height="5" rx="1"/><rect x="15" y="16" width="7" height="5" rx="1"/><path d="M12 8v4m-6.5 4v-4h13v4"/>',
  grip: '<g fill="currentColor" stroke="none"><circle cx="8" cy="5" r="1.7"/><circle cx="16" cy="5" r="1.7"/><circle cx="8" cy="12" r="1.7"/><circle cx="16" cy="12" r="1.7"/><circle cx="8" cy="19" r="1.7"/><circle cx="16" cy="19" r="1.7"/></g>',
  undo: '<path d="m9 4-6 6 6 6M3 10h10a7 7 0 0 1 7 7"/>',
  edit: '<path d="m4 16-1 5 5-1L20 8l-4-4z"/>',
  warning: '<path d="m12 3 10 17H2zM12 8v5m0 3v.2"/>',
  print: '<path d="M6 9V3h12v6M6 17H3v-7h18v7h-3"/><path d="M6 14h12v7H6z"/>',
};
function icon(name, size = 18) {
  return `<svg aria-hidden="true" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round">${icons[name] || icons.blocks}</svg>`;
}
const colors = [
  ['#d9eadc', '#327554', '#a4d6ab'],
  ['#e4def3', '#725597', '#c5ade9'],
  ['#f6e8c9', '#966416', '#e8c782'],
  ['#d9e9f3', '#427592', '#9fcce0'],
  ['#f2ded9', '#995847', '#eab0a2'],
  ['#d9eae6', '#397a72', '#9acabf'],
];
const hash = (text) =>
  Array.from(String(text)).reduce((acc, ch) => ((acc << 5) - acc + ch.charCodeAt(0)) | 0, 0) >>> 0;
const palette = (key) => colors[hash(key) % colors.length];
function theme(key) {
  const [bg, ink, line] = palette(key);
  return `--tint:${bg};--ink:${ink};--edge:${line}`;
}
let catalog = { solutions: [], schedules: [] };
let project,
  previousProject,
  rawRevision = null,
  loadError = '',
  catalogError = '',
  saved = false;
let serverRevision = null,
  projectStoreReady = false,
  writing = false;
let day = M.localDate(),
  page = 'schedule',
  filter = '',
  compare = [],
  view = 'timeline',
  range = 'show',
  query = '';
let playhead = Math.max(480, Math.min(1079, new Date().getHours() * 60 + new Date().getMinutes()));
let syncBrowserTime = false,
  clockTimeout;
let timer,
  navOpen = false;
const ranges = { show: [480, 1080], full: [0, 1440], morning: [0, 720], evening: [720, 1440] };
const getSolution = (id) => project.solutions.find((s) => s.id === id);
const getScreen = (id) => project.screens.find((s) => s.id === id);
const visibleScreens = () =>
  project.screens.filter((s) => (filter ? s.id === filter : !compare.length || compare.includes(s.id)));
function visibleOccurrences() {
  const ids = new Set(visibleScreens().map((s) => s.id));
  return M.occurrences(project, day).filter((o) => ids.has(o.cue.screenId));
}
function timeRange() {
  if (range !== 'close') return ranges[range];
  const start = Math.min(1320, Math.max(0, Math.floor((playhead - 60) / 30) * 30));
  return [start, start + 120];
}
function btn(label, action, ico = '', kind = 'btn-secondary', more = '') {
  return `<button type="button" class="btn ${kind}" data-action="${action}" ${more}>${ico ? icon(ico, 16) : ''}${esc(label)}</button>`;
}
function iconBtn(label, action, ico, more = '') {
  return `<button type="button" aria-label="${esc(label)}" title="${esc(label)}" class="icon-btn" data-action="${action}" ${more}>${icon(ico, 16)}</button>`;
}
function notice(message) {
  const box = $('#notice');
  box.textContent = message;
  box.classList.add('visible');
  clearTimeout(timer);
  timer = setTimeout(() => box.classList.remove('visible'), 4800);
}
function defaultProject() {
  const base = {
    version: 1,
    title: 'Local workspace',
    screens: [],
    solutions: catalog.solutions.map((s) => ({ ...s })),
    cues: [],
  };
  // A native schedule is a planning lane. No hardware assignment is implied.
  for (const native of catalog.schedules) {
    const lane = {
      id: native.id,
      name: native.name,
      width: native.width,
      height: native.height,
      sourceSchedule: native.id,
      warning: native.warning || '',
    };
    const cues = native.cues.map((c, i) => ({ ...c, id: `${lane.id}-block-${i}`, screenId: lane.id }));
    try {
      M.validateProject({ ...base, screens: [...base.screens, lane], cues: [...base.cues, ...cues] });
    } catch (e) {
      catalogError = `A ViPlex schedule could not be loaded: ${native.name}. ${e.message}`;
      continue;
    }
    base.screens.push(lane);
    base.cues.push(...cues);
  }
  if (base.screens.length) {
    const counts = new Map(base.screens.map((s) => [s.id, M.occurrences(base, day, s.id).length]));
    base.screens.sort((a, b) => counts.get(b.id) - counts.get(a.id) || a.name.localeCompare(b.name));
  }
  return base;
}
async function storeOnDisk(candidate) {
  const session = await fetch('/api/session', { cache: 'no-store' });
  if (!session.ok) throw new Error('The local service is unavailable. Open Launch Studio.cmd and try again.');
  const { exportToken } = await session.json();
  const response = await fetch('/api/project', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Studio-Token': exportToken },
    body: JSON.stringify({ baseRevision: serverRevision, project: candidate }),
  });
  if (response.status === 409)
    throw new Error('A newer copy was saved in another window. Reload the board before applying this edit.');
  if (!response.ok)
    throw new Error(
      (await response.json().catch(() => ({}))).error ||
        'The workspace could not be saved to disk. Open the launcher and retry.',
    );
  const result = await response.json();
  serverRevision = result.revision;
}
async function commit(candidate, message = 'Changes saved', restoreBackup = false) {
  M.validateProject(candidate);
  if (writing) throw new Error('A save is already in progress. Try again when it finishes.');
  if (loadError && !(restoreBackup && (projectStoreReady || location.protocol === 'file:')))
    throw new Error(loadError);
  writing = true;
  try {
    const serial = JSON.stringify(candidate);
    if (projectStoreReady) {
      await storeOnDisk(candidate);
    } else if (location.protocol !== 'file:')
      throw new Error('Open Launch Studio.cmd and reload the board to save.');
    else if (localStorage.getItem(storageKey) !== rawRevision)
      throw new Error('A newer copy was saved. Reload before editing.');
    if (projectStoreReady) {
      try {
        localStorage.setItem(storageKey, serial);
      } catch {
        /* The workspace is already on disk. */
      }
    } else localStorage.setItem(storageKey, serial);
    rawRevision = serial;
    previousProject = project;
    project = candidate;
    saved = true;
    loadError = '';
  } finally {
    writing = false;
  }
  if (filter && !getScreen(filter)) filter = '';
  compare = compare.filter((id) => getScreen(id));
  render();
  if (message) notice(message);
  return true;
}
async function readProject() {
  let disk = null;
  if (location.protocol !== 'file:') {
    try {
      const response = await fetch('/api/project', { cache: 'no-store' });
      if (!response.ok)
        throw new Error('The workspace file could not be read. Reopen the launcher and reload.');
      disk = await response.json();
      serverRevision = disk.revision;
      projectStoreReady = true;
      if (disk.project) {
        project = M.validateProject(disk.project);
        saved = true;
        loadError = '';
        if (disk.recovered)
          catalogError = 'Opened the last saved backup after a problem reading the workspace file.';
        return;
      }
    } catch (e) {
      loadError = e.message;
    }
  }
  try {
    rawRevision = localStorage.getItem(storageKey);
  } catch {
    /* Desktop storage also works without browser cache. */
  }
  try {
    project = rawRevision ? M.validateProject(JSON.parse(rawRevision)) : defaultProject();
  } catch (e) {
    project = defaultProject();
    loadError = 'The earlier browser workspace could not be opened. ' + e.message;
  }
  if (loadError) return;
  try {
    if (projectStoreReady) {
      if (catalogError && !rawRevision && !project.screens.length && !project.solutions.length) return;
      await storeOnDisk(project);
    } else {
      rawRevision = JSON.stringify(project);
      localStorage.setItem(storageKey, rawRevision);
    }
    saved = true;
  } catch (e) {
    loadError = e.message;
  }
}
function openDialog({ title, subtitle = '', body, submitLabel, onSubmit, wide = false, extra = '' }) {
  const dlg = $('#dialog');
  if (dlg.open) dlg.close();
  dlg.className = wide ? 'wide' : '';
  dlg.innerHTML = `<form><header class="modal-head"><div><h2 id="dialog-title">${esc(title)}</h2>${subtitle ? `<p>${esc(subtitle)}</p>` : ''}</div><button type="button" class="icon-btn" data-close aria-label="Close">${icon('x')}</button></header><section class="modal-body">${body}</section><p class="form-error" role="alert" hidden></p><footer class="modal-foot">${extra}<span class="spacer"></span><button class="btn btn-secondary" type="button" data-close>${submitLabel ? 'Cancel' : 'Close'}</button>${submitLabel ? `<button type="submit" class="btn btn-primary">${esc(submitLabel)}</button>` : ''}</footer></form>`;
  dlg.querySelectorAll('[data-close]').forEach((b) => (b.onclick = () => dlg.close()));
  const form = dlg.querySelector('form');
  form.onsubmit = async (e) => {
    e.preventDefault();
    const error = form.querySelector(':scope > .form-error');
    error.hidden = true;
    const submit = form.querySelector('[type=submit]');
    if (submit?.disabled) return;
    if (submit) submit.disabled = true;
    try {
      const result = await onSubmit?.(form);
      if (result !== false && dlg.open && dlg.contains(form)) dlg.close();
    } catch (err) {
      error.textContent = err.message || String(err);
      error.hidden = false;
    } finally {
      if (submit) submit.disabled = false;
    }
  };
  dlg.showModal();
  return form;
}
function closeDialog() {
  if ($('#dialog').open) $('#dialog').close();
}
function solutionThumbnail(solution) {
  const src = solution?.thumbnail;
  return typeof src === 'string' &&
    /^(?:\/api\/thumbnail\/viplex-[0-9a-f-]+|\/api\/media-preview\/[0-9a-f]{64})$/i.test(src) ? src : '';
}
function thumb(solution, klass = '') {
  const src = solutionThumbnail(solution);
  if (src) {
    return `<div class="thumb ${klass}">${icon('layers', 22)}<img loading="lazy" src="${esc(src)}" alt="" onerror="this.hidden=true"></div>`;
  }
  return `<div class="thumb abstract ${klass}" style="${theme(solution?.id)}">${icon('layers', 24)}</div>`;
}
function laneGrip(screen, enabled) {
  const name = esc(screen.name);
  return `<button type="button" class="lane-grip" data-lane-grip aria-label="Reorder ${name}" aria-describedby="lane-reorder-help" aria-keyshortcuts="ArrowUp ArrowDown"
    title="${enabled ? `Drag to reorder ${name}, or use the up and down arrow keys` : 'Reordering needs two visible schedules'}"${enabled ? '' : ' disabled'}>${icon('grip', 17)}</button>`;
}
function side() {
  const nav = [
    ['schedule', 'timeline', 'Schedule board'],
    ['solutions', 'shelf', 'Solution library'],
    ['screens', 'screens', 'Schedules'],
    ['players', 'network', 'Players'],
  ];
  return `<aside class="sidebar ${navOpen ? 'open' : ''}"><div class="brand"><img src="favicon.svg" alt=""><span>Relay <strong>Studio</strong></span></div>
 <div class="nav-area"><p class="eyebrow">Workspace</p><nav>${nav.map(([id, ic, title]) => `<button data-nav="${id}" class="nav-item ${page === id ? 'active' : ''}" ${page === id ? 'aria-current="page"' : ''}>${icon(ic, 19)}${title}</button>`).join('')}</nav>
 <div class="side-divider"></div><div class="side-subhead"><span class="eyebrow">Schedules</span>${iconBtn('Add schedule', 'screen-new', 'plus')}</div>
 <button data-filter="" class="lane-link ${!filter && !compare.length && page === 'schedule' ? 'selected' : ''}">${icon('layers', 15)}<span>All schedules</span><small>${project.screens.length}</small></button>
 <div class="lane-links" data-lane-list="sidebar">${project.screens.map((s) => `<div class="sidebar-lane" data-lane-id="${esc(s.id)}"><div class="lane-heading ${(filter === s.id || compare.includes(s.id)) && page === 'schedule' ? 'selected' : ''}" data-lane-label style="--lane-color:${palette(s.id)[2]}">
   ${laneGrip(s, project.screens.length > 1)}<button type="button" data-filter="${esc(s.id)}" class="lane-link" title="${project.screens.length > 1 ? 'Drag to reorder · ' : ''}Click to filter to ${esc(s.name)}"><span>${esc(s.name)}</span></button></div></div>`).join('')}</div></div>
 <div class="sidebar-foot"><div class="source-mark">${icon('drive', 20)}</div><div><strong>Local workspace</strong><small><i class="status-dot"></i>${catalog.solutions.length ? 'ViPlex library linked' : 'On this computer'}</small></div></div></aside>`;
}
function shellHeader() {
  const name = { schedule: 'Schedule board', solutions: 'Solution library', screens: 'Schedules', players: 'Players' }[page];
  return `<header class="topbar"><div class="crumb">${iconBtn('Open navigation', 'menu', 'menu', 'id="menu-toggle"')}${icon('layers', 17)}<span>Workspace</span><b>/</b><strong>${name}</strong></div><div class="top-actions"><span class="save-status">${icon('save', 17)}${saved ? 'Saved locally' : 'Unsaved workspace'}</span>${studioPasswordControls()}${studioThemeButton()}${previousProject ? iconBtn('Undo last change', 'undo', 'undo') : ''}${btn('Players', 'player-controls', 'network', 'btn-secondary compact')}${btn('Project', 'project-menu', 'folder', 'btn-secondary compact')}${btn('Export', 'export', 'export', 'btn-dark compact')}</div></header>`;
}
function titleArea(title, sub, actions) {
  return `<div class="title-area"><div><h1>${esc(title)}</h1><p>${sub}</p></div><div class="title-actions">${actions}</div></div>`;
}
function dateStrip() {
  const monday = M.addDays(day, -((M.weekday(day) + 6) % 7)),
    today = M.localDate();
  const days = Array.from({ length: 7 }, (_, i) => M.addDays(monday, i));
  return `<div class="week-strip"><div class="month"><label class="calendar-picker" aria-label="Choose schedule date">${icon('calendar', 20)}<input aria-label="Choose schedule date" type="date" data-date value="${day}"></label><div><strong>${formatDate(day, { month: 'long' })}</strong><small>${day.slice(0, 4)}</small></div></div>${iconBtn('Previous week', 'prev-week', 'left')}<div class="week-days">${days.map((d) => `<button data-day="${d}" class="day ${day === d ? 'active' : ''}" aria-pressed="${day === d}" title="${formatDate(d, { dateStyle: 'full' })}"><span>${formatDate(d, { weekday: 'short' })}</span><strong>${+d.slice(8)}</strong>${d === today ? '<b aria-label="Today"></b>' : ''}</button>`).join('')}</div>${iconBtn('Next week', 'next-week', 'right')}${btn('Today', 'today', '', 'btn-secondary compact')}</div>`;
}
function timelineCue(occurrence, screen, from, to) {
  const { cue, startMinute, endMinute, continued, continues } = occurrence;
  const solution = getSolution(cue.solutionId);
  const span = to - from;
  const left = ((Math.max(from, startMinute) - from) / span) * 100;
  const width = ((Math.min(to, endMinute) - Math.max(from, startMinute)) / span) * 100;
  const times = `${clock(startMinute)} – ${clock(endMinute)}`;
  const handle = (edge) => `<span aria-hidden="true" class="cue-handle" data-resize="${edge}" title="Drag to change the ${edge} time"></span>`;
  return `<button type="button" class="cue ${width < 7 ? 'tiny' : ''}" data-cue="${esc(cue.id)}" data-continued="${continued}"
    style="${theme(solution.id)};left:calc(${left}% + 1px);width:calc(${width}% - 2px)" aria-describedby="timeline-edit-help"
    title="${esc(solution.name)} · ${times} · ${esc(screen.name)}"><strong>${esc(solution.name)}</strong><small>${times}</small>${!continued && startMinute >= from ? handle('start') : ''}${!continues && endMinute <= to ? handle('end') : ''}</button>`;
}
function timeline() {
  const [from, to] = timeRange(),
    span = to - from,
    lanes = visibleScreens(),
    all = visibleOccurrences();
  const divisions = range === 'show' ? 5 : range === 'close' ? 4 : 6;
  const ticks = Array.from({ length: divisions + 1 }, (_, i) => clock(from + (span * i) / divisions));
  const pos = ((playhead - from) / span) * 100;
  const pin = pos >= 0 && pos <= 100 ? `<i class="cursor-line" style="left:${pos}%"></i>` : '';
  const rows = lanes
    .map((s) => {
      const blocks = all.filter((o) => o.cue.screenId === s.id && o.startMinute < to && o.endMinute > from);
      return `<div class="timeline-row" data-lane-id="${esc(s.id)}"><div class="lane-heading" data-lane-label style="--lane-color:${palette(s.id)[1]}">
        ${laneGrip(s, lanes.length > 1)}<button type="button" class="row-label" title="${lanes.length > 1 ? 'Drag to reorder · ' : ''}Click to filter to ${esc(s.name)}" data-filter="${esc(s.id)}"><span><strong>${esc(s.name)}</strong><small>${s.width} × ${s.height}</small></span></button></div><div class="track" data-track="${esc(s.id)}">${blocks
        .map((o) => timelineCue(o, s, from, to))
        .join('')}${pin}</div></div>`;
    })
    .join('');
  return `<div class="timeline-scroll" id="tracks"><div data-lane-list="timeline" class="timeline-inner ${span <= 600 ? 'quarter-guides' : ''}" style="--tick-width:${100 / divisions}%;--quarter-width:${(M.blockMinutes / span) * 100}%"><div class="timeline-axis"><div class="axis-label">${icon('screen', 14)} Schedule</div><div class="ruler" data-ruler title="Click to move the playhead">${ticks.map((t, i) => `<span class="tick ${i === 0 ? 'tick-0' : i === divisions ? 'tick-6' : ''}" style="left:${(i * 100) / divisions}%">${t}</span>`).join('')}${pos >= 0 && pos <= 100 ? `<b class="head-marker" style="left:${pos}%"></b>` : ''}</div></div>${rows}</div></div>`;
}
function agenda() {
  const events = visibleOccurrences();
  return `<div class="agenda-scroll"><table><thead><tr><th>Start</th><th>End</th><th>Schedule</th><th>Solution</th><th></th></tr></thead><tbody>${events.map(({ cue, startMinute, endMinute }) => `<tr><td class="mono">${clock(startMinute)}</td><td class="mono">${clock(endMinute)}</td><td>${esc(getScreen(cue.screenId).name)}</td><td><i class="inline-dot" style="--dot:${palette(cue.solutionId)[1]}"></i>${esc(getSolution(cue.solutionId).name)}</td><td>${iconBtn('Edit block', 'edit-block', 'edit', `data-id="${esc(cue.id)}"`)}</td></tr>`).join('')}</tbody></table>${!events.length ? '<p class="empty">No blocks scheduled for this date.</p>' : ''}</div>`;
}
function schedulePanel() {
  const count = visibleOccurrences().length;
  const screenCount = visibleScreens().length;
  const switchView = [['timeline', 'timeline', 'Timeline'], ['agenda', 'list', 'Run sheet']]
    .map(([value, mark, label]) => `<button data-view="${value}" aria-pressed="${view === value}" class="${view === value ? 'on' : ''}">${icon(mark, 15)}${label}</button>`)
    .join('');
  const hourOptions = {show: '08:00 – 18:00', close: '2h at playhead', full: 'Full day', morning: '00:00 – 12:00', evening: '12:00 – 24:00'};
  const hours = `<select id="range" aria-label="Timeline hours">${Object.entries(hourOptions)
    .map(([value, label]) => `<option value="${value}" ${range === value ? 'selected' : ''}>${label}</option>`).join('')}</select>`;
  return `<section class="panel timeline-panel" aria-labelledby="timeline-heading">
    <header class="timeline-tools">
      <div class="panel-title"><h2 id="timeline-heading">${view === 'timeline' ? 'Schedule timeline' : 'Run sheet'}</h2><span class="muted">${count} ${count === 1 ? 'block' : 'blocks'}</span></div>
      <div class="playhead-controls">
        <label class="playhead">Playhead <input type="time" id="play-time" aria-label="Playhead time" required value="${clock(playhead)}"></label>
        <label class="clock-follow" title="Follow this browser’s local date and time. Moving the playhead or selecting another day pauses sync."><input id="playhead-sync" type="checkbox"${syncBrowserTime ? ' checked' : ''}>Sync to browser time</label>
      </div>
      <div class="timeline-filters"><button class="lane-picker" data-action="compare" title="Choose schedules to compare">${icon('screens', 14)}${screenCount} ${screenCount === 1 ? 'schedule' : 'schedules'} ${icon('down', 12)}</button>
        ${view === 'timeline' ? hours : btn('Print', 'print', 'print', 'btn-text')}</div>
      <div class="segmented" role="group" aria-label="Schedule view">${switchView}</div>
    </header>
    <span id="timeline-edit-help" class="timeline-help">Drag a block to move it. Drag either edge to resize it. Click to edit.</span>
    ${!project.screens.length ? `<div class="empty"><p>Add a schedule to start planning.</p>${btn('Add schedule', 'screen-new', 'plus')}</div>` : view === 'timeline' ? timeline() : agenda()}
  </section>`;
}
function schedule() {
  return (
    titleArea(
      'Schedule board',
      `${icon('calendar', 15)} ${formatDate(day, { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' })}`,
      `${btn('Add block', 'cue-new', 'plus')}${btn('Coordinate schedules', 'sync', 'sync', 'btn-primary')}`,
    ) +
    dateStrip() +
    schedulePanel()
  );
}
function solutionPage() {
  return (
    titleArea(
      'Solution library',
      `${project.solutions.length} solutions in this workspace`,
      btn('Add reference', 'solution-new', 'plus') + btn('Refresh from ViPlex', 'refresh', 'import'),
    ) +
    mediaDropZone() +
    solutionBrowser()
  );
}
function screenPage() {
  return (
    titleArea(
      'Schedules',
      'Build a sequence of solutions, then send it to one or more boards.',
      btn('Add schedule', 'screen-new', 'plus', 'btn-primary'),
    ) +
    `<section class="panel"><header class="panel-head"><div class="panel-title"><span class="panel-icon">${icon('screens')}</span><h2>Your schedules</h2></div><span class="muted">${project.screens.length} schedules</span></header><div class="table-wrap"><table><thead><tr><th>Schedule</th><th>Resolution</th><th>Schedule source</th><th>Blocks today</th><th></th></tr></thead><tbody>${project.screens.map((s) => `<tr><td><button class="text-link" data-filter="${esc(s.id)}">${icon('screen', 15)}${esc(s.name)}</button></td><td>${s.width} × ${s.height}</td><td>${s.sourceSchedule ? 'ViPlex schedule' : 'Local schedule'}${s.warning ? ` <button class="icon-btn" data-warning="${esc(s.id)}" aria-label="View import notes">${icon('warning', 14)}</button>` : ''}</td><td>${M.occurrences(project, day, s.id).length}</td><td>${iconBtn('Edit schedule', 'screen-edit', 'edit', `data-id="${esc(s.id)}"`)}</td></tr>`).join('')}</tbody></table></div></section>`
  );
}
function render() {
  if (!project) return;
  window.TimelineEdit?.cancel();
  window.LaneReorder?.cancel();
  const oldTracks = $('#tracks');
  const top = oldTracks?.scrollTop || 0, left = oldTracks?.scrollLeft || 0;
  const sideScroll = $('.nav-area')?.scrollTop || 0;
  $('#app').innerHTML =
    `${side()}${navOpen ? '<button class="backdrop" data-action="menu" aria-label="Close navigation"></button>' : ''}<div class="workspace${page === 'schedule' ? ' schedule-workspace' : ''}">${shellHeader()}<main id="main">${loadError || catalogError ? `<div class="banner" role="status">${icon('warning', 16)}${esc(loadError || catalogError)}</div>` : ''}${page === 'schedule' ? schedule() : page === 'solutions' ? solutionPage() : page === 'players' ? playerManagementPage() : screenPage()}</main></div>`;
  $('#tracks')?.scrollTo(left, top);
  $('.nav-area').scrollTop = sideScroll;
  mountSolutionInspector();
  mountStudioPasswordControls();
  mountPlayerManagement();
}
function changeDay(value) {
  M.weekday(value);
  if (syncBrowserTime && value !== M.localDate()) setClockSync(false);
  day = value;
  render();
}
function setPlayhead(n) {
  if (syncBrowserTime) setClockSync(false);
  playhead = Math.min(1439, Math.max(0, n));
  render();
}
function setClockSync(enabled) {
  syncBrowserTime = enabled;
  try {
    localStorage.setItem(clockSettingKey, String(enabled));
  } catch { /* The setting still applies in this tab. */ }
  const toggle = $('#playhead-sync');
  if (toggle) toggle.checked = enabled;
  updateBrowserClock();
}
function updateBrowserClock() {
  clearTimeout(clockTimeout);
  if (!syncBrowserTime || document.hidden) return;
  const now = new Date();
  clockTimeout = setTimeout(updateBrowserClock, 60000 - now.getSeconds() * 1000 - now.getMilliseconds());
  const today = M.localDate(now), minute = now.getHours() * 60 + now.getMinutes();
  // A dragged block needs a stable ruler. Active forms retain their selected date across midnight.
  if (!project || drawing || window.TimelineEdit?.active || window.LaneReorder?.active) return;
  if (day !== today && ($('#dialog').open || document.activeElement?.matches('[data-date]'))) return;
  const previousDay = day, previousMinute = playhead, previousRange = range;
  const [previousStart, previousEnd] = timeRange();
  day = today;
  playhead = minute;
  const [from, to] = timeRange();
  if (minute < from || minute >= to) range = 'full';
  if (previousDay === day && previousMinute === minute && previousRange === range) return;
  // Other views, including active video previews, keep their own DOM.
  if (page !== 'schedule') {
    if (page === 'screens' && previousDay !== day) render();
    return;
  }
  if (previousDay !== day) {
    const focused = document.activeElement;
    render();
    const replacement = document.getElementById(focused?.id);
    replacement?.focus({ preventScroll: true });
    if (focused?.type === 'text' && replacement)
      replacement.setSelectionRange(focused.selectionStart, focused.selectionEnd);
    return;
  }
  const input = $('#play-time');
  if (!input) return;
  input.value = clock(minute);
  const rangePicker = $('#range');
  if (rangePicker) rangePicker.value = range;
  const tracks = $('#tracks');
  if (tracks) {
    const redraw = previousRange !== range || previousStart !== timeRange()[0] ||
      previousMinute < previousStart || previousMinute > previousEnd;
    if (redraw) {
      const { scrollTop, scrollLeft } = tracks;
      tracks.outerHTML = timeline();
      $('#tracks').scrollTo(scrollLeft, scrollTop);
    } else {
      const [start, end] = timeRange();
      const left = `${((minute - start) / (end - start)) * 100}%`;
      document.querySelectorAll('.head-marker,.cursor-line').forEach((marker) => { marker.style.left = left; });
    }
  }
}
function trackTime(event, node, snap = M.blockMinutes) {
  const [from, to] = timeRange(),
    rect = node.getBoundingClientRect();
  return Math.min(
    to,
    Math.max(
      from,
      Math.round((from + ((event.clientX - rect.left) / rect.width) * (to - from)) / snap) * snap,
    ),
  );
}
function goNav(p) {
  page = p;
  navOpen = false;
  render();
  window.scrollTo(0, 0);
}
function cueLaunch(args = {}) {
  if (!project.screens.length) {
    notice('Add a schedule before scheduling.');
    return openScreen();
  }
  if (!project.solutions.length) {
    notice('Add a solution before scheduling.');
    return openSolution();
  }
  window.openCue(args);
}
document.addEventListener('click', async (e) => {
  const b = e.target.closest('button,[data-ruler]');
  if (!b || b.closest('dialog')) return;
  const d = b.dataset;
  try {
    if (d.nav) {
      goNav(d.nav);
      return;
    }
    if ('filter' in d) {
      filter = d.filter;
      compare = [];
      goNav('schedule');
      return;
    }
    if (d.day) {
      changeDay(d.day);
      return;
    }
    if (d.view) {
      view = d.view;
      render();
      return;
    }
    if (d.cue) {
      cueLaunch({ id: d.cue });
      return;
    }
    if (d.inspect) {
      selectInspectedSolution(d.inspect);
      return;
    }
    if (d.usbSolution) {
      if (!b.disabled) openUsbPlayback(d.usbSolution);
      return;
    }
    if (d.networkSolution) {
      if (!b.disabled) openNetworkPlayback(d.networkSolution);
      return;
    }
    if (d.solution) {
      cueLaunch({ solutionId: d.solution, screenId: filter || undefined });
      return;
    }
    if (d.warning) {
      notice(getScreen(d.warning).warning);
      return;
    }
    if ('ruler' in d) {
      setPlayhead(trackTime(e, b, 1));
      return;
    }
    switch (d.action) {
      case 'player-controls':
        goNav('players');
        break;
      case 'toggle-theme':
        toggleStudioTheme();
        break;
      case 'menu':
        navOpen = !navOpen;
        render();
        break;
      case 'prev-week':
        changeDay(M.addDays(day, -7));
        break;
      case 'next-week':
        changeDay(M.addDays(day, 7));
        break;
      case 'today':
        changeDay(M.localDate());
        break;
      case 'cue-new':
        cueLaunch({ screenId: filter || undefined });
        break;
      case 'edit-block':
        cueLaunch({ id: d.id });
        break;
      case 'sync':
        if (!project.screens.length || !project.solutions.length) {
          notice('Add at least one schedule and solution to coordinate a change.');
          break;
        }
        openSync();
        break;
      case 'compare':
        chooseLanes();
        break;
      case 'screen-new':
        openScreen();
        break;
      case 'screen-edit':
        openScreen(d.id);
        break;
      case 'solution-new':
        openSolution();
        break;
      case 'project-menu':
        projectMenu();
        break;
      case 'export':
        exportMenu();
        break;
      case 'refresh':
        await refreshLibrary();
        break;
      case 'print':
        window.print();
        break;
      case 'undo': {
        const prior = previousProject;
        if (prior) {
          await commit(prior, 'Last change undone');
          previousProject = null;
          render();
        }
        break;
      }
    }
  } catch (err) {
    notice(err.message);
  }
});
document.addEventListener('change', (e) => {
  const input = e.target;
  if (input.matches('[data-date]') && input.value) changeDay(input.value);
  if (input.id === 'library-type') {
    libraryType = input.value;
    refreshSolutionList();
  }
  if (input.id === 'range') {
    range = input.value;
    const [from, to] = timeRange();
    if (syncBrowserTime && (playhead < from || playhead >= to)) setClockSync(false);
    render();
  }
  if (input.id === 'playhead-sync') setClockSync(input.checked);
  if (input.id === 'play-time' && input.value) setPlayhead(M.timeMinutes(input.value));
});
document.addEventListener('input', (e) => {
  const id = e.target.id;
  if (id === 'play-time' && syncBrowserTime) setClockSync(false);
  if (id === 'solution-search') {
    query = e.target.value;
    refreshSolutionList();
  }
});
let drawing = null;
function drawnRange(start, end) {
  const first = Math.min(start, end, timeRange()[1] - M.blockMinutes);
  return [first, Math.max(start, end, first + M.blockMinutes)];
}
function showDrawnRange(end) {
  const [first, last] = drawnRange(drawing.start, end);
  const [from, to] = timeRange();
  drawing.band.style.left = `${((first - from) / (to - from)) * 100}%`;
  drawing.band.style.width = `${((last - first) / (to - from)) * 100}%`;
}
document.addEventListener('pointerdown', (e) => {
  const lane = e.target.closest('[data-track]');
  if (!lane || !e.isPrimary || drawing || window.TimelineEdit?.active || window.LaneReorder?.active || e.button !== 0 || e.target.closest('[data-cue]')) return;
  const start = trackTime(e, lane);
  drawing = { lane, start, pointerId: e.pointerId };
  lane.setPointerCapture(e.pointerId);
  const band = document.createElement('i');
  band.className = 'draw-block';
  lane.append(band);
  drawing.band = band;
  showDrawnRange(start);
});
document.addEventListener('pointermove', (e) => {
  if (drawing?.pointerId !== e.pointerId) return;
  showDrawnRange(trackTime(e, drawing.lane));
});
function cancelDraw(e) {
  if (drawing?.pointerId !== e.pointerId) return;
  drawing.band.remove();
  drawing = null;
  updateBrowserClock();
}
document.addEventListener('pointercancel', cancelDraw);
document.addEventListener('lostpointercapture', cancelDraw);
document.addEventListener('pointerup', (e) => {
  if (drawing?.pointerId !== e.pointerId) return;
  const { lane, start, band } = drawing;
  drawing = null;
  band.remove();
  const end = trackTime(e, lane);
  const [first, last] = drawnRange(start, end);
  cueLaunch({
    screenId: lane.dataset.track,
    start: clock(first),
    end: clock(last),
  });
});
window.addEventListener('storage', async (e) => {
  if (e.key !== storageKey) return;
  if (!(await window.studioRuntimeReady)) return;
  if ($('#dialog').open) {
    notice('Workspace changed in another window. Reload before saving this edit.');
    return;
  }
  await readProject();
  previousProject = null;
  render();
  notice('Workspace updated from another window.');
});
async function fetchCatalog() {
  if (location.protocol === 'file:') throw new Error('Open Launch Studio.cmd to connect to ViPlex.');
  const response = await fetch('/api/catalog', { cache: 'no-store' });
  if (!response.ok) throw new Error('Could not read the local ViPlex catalog.');
  const data = await response.json();
  if (!Array.isArray(data.solutions) || !Array.isArray(data.schedules))
    throw new Error('Unexpected catalog format.');
  return data;
}
async function refreshLibrary() {
  catalog = await fetchCatalog();
  catalogError = (catalog.messages || []).join(' ');
  if (catalogError) throw new Error(catalogError);
  await commit(
    M.reconcileCatalog(project, catalog.solutions),
    `Refreshed ${catalog.solutions.length} ViPlex solutions`,
  );
}
window.Relay = {
  get project() {
    return project;
  },
  get date() {
    return day;
  },
  get filter() {
    return filter;
  },
  get selectedScreenIds() {
    return filter ? [filter] : compare;
  },
  get playhead() {
    return playhead;
  },
  esc,
  uid,
  clock,
  icon,
  openDialog,
  closeDialog,
  commit,
  notice,
};
document.addEventListener('DOMContentLoaded', async () => {
  if (!(await window.studioRuntimeReady)) { showStudioRuntimeNotice(); return; }
  try {
    syncBrowserTime = localStorage.getItem(clockSettingKey) === 'true';
  } catch { /* Browser preferences can be unavailable in private windows. */ }
  document.addEventListener('visibilitychange', updateBrowserClock);
  window.addEventListener('focus', updateBrowserClock);
  $('#dialog').addEventListener('close', updateBrowserClock);
  document.addEventListener('focusout', (event) => {
    if (event.target.matches('[data-date]') && syncBrowserTime) queueMicrotask(updateBrowserClock);
  });
  try {
    catalog = await fetchCatalog();
    catalogError = (catalog.messages || []).join(' ');
  } catch (e) {
    catalogError = e.message;
  }
  await readProject();
  if (projectStoreReady && !loadError && !catalogError && catalog.solutions.length) {
    const linked = M.reconcileCatalog(project, catalog.solutions);
    if (JSON.stringify(linked) !== JSON.stringify(project)) {
      try {
        await commit(linked, '');
        previousProject = null;
      } catch (error) {
        catalogError = error.message;
      }
    }
  }
  updateBrowserClock();
  render();
});
