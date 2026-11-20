'use strict';

let inspectedSolutionId = '';
let solutionRequest;

function solutionSourceLabel(solution) {
  if (solution.source?.kind === 'localVideo') return 'Imported video';
  if (solution.source?.kind === 'localImage') return 'Imported image';
  if (solution.missing) return 'Missing in ViPlex';
  return solution.source?.playlistUuid ? 'ViPlex Express' : 'Local reference';
}

function filteredSolutions() {
  const search = query.trim().toLowerCase();
  return project.solutions.filter((s) =>
    matchesLibraryType(s, libraryType) && s.name.toLowerCase().includes(search));
}

function matchesLibraryType(solution, type) {
  const kind = solution.source?.kind;
  return type === 'all' ||
    (type === 'imported' && ['localVideo', 'localImage'].includes(kind)) ||
    (type === 'video' && kind === 'localVideo') ||
    (type === 'image' && kind === 'localImage');
}

function retainLibrarySelection(list) {
  if (!list.some((s) => s.id === inspectedSolutionId)) inspectedSolutionId = list[0]?.id || '';
}

function solutionRows(list) {
  return list.map((s) => {
    const usbAvailable = canUsbPlaybackSolution(s);
    const usbLabel = `USB playback for ${s.name}`;
    const usbHelp = usbAvailable ? usbLabel : s.missing
      ? `USB playback unavailable: ${s.name} is missing from the ViPlex library.`
      : `USB playback unavailable: ${s.name} has no attached media.`;
    const networkHelp = usbAvailable ? `Send ${s.name} over network` : s.missing
      ? `Network playback unavailable: ${s.name} is missing from the ViPlex library.`
      : `Network playback unavailable: ${s.name} has no attached media.`;
    return `<div class="browser-row">
    <button class="solution-pick" type="button" data-inspect="${esc(s.id)}" aria-label="View ${esc(s.name)}" aria-controls="solution-inspector" aria-pressed="${s.id === inspectedSolutionId}">
      ${thumb(s)}<span class="browser-row-info"><strong>${esc(s.name)}</strong><small>${esc(s.width)} × ${esc(s.height)} · ${solutionSourceLabel(s)}</small></span>
    </button>
    <button type="button" class="row-usb" data-usb-solution="${esc(s.id)}" title="${esc(usbHelp)}" aria-label="${esc(usbAvailable ? usbLabel : usbHelp)}"${usbAvailable ? '' : ' disabled'}>${icon('drive', 14)}<span>USB</span></button>
    <button type="button" class="row-network" data-network-solution="${esc(s.id)}" title="${esc(networkHelp)}" aria-label="${esc(networkHelp)}"${usbAvailable ? '' : ' disabled'}>${icon('network', 14)}<span>Send</span></button>
    <button type="button" class="row-schedule" data-solution="${esc(s.id)}" title="Schedule ${esc(s.name)}" aria-label="Schedule ${esc(s.name)}">${icon('plus', 15)}</button>
  </div>`;
  }).join('') || '<p class="empty">No matching solutions.</p>';
}

function solutionBrowser() {
  const list = filteredSolutions();
  retainLibrarySelection(list);
  return `<div class="solution-browser"><section class="panel library-list" aria-label="Browse solutions">
    <header class="panel-head"><label class="search-field catalog-search">${icon('search', 17)}<input type="search" id="solution-search" aria-label="Search solutions" placeholder="Search solutions…" value="${esc(query)}"></label>
      <label class="solution-filter"><select id="library-type" aria-label="Solution type">${[['all', 'All solutions'], ['imported', 'Imported media'], ['video', 'Imported videos'], ['image', 'Imported images']].map(([value, label]) => `<option value="${value}" ${libraryType === value ? 'selected' : ''}>${label}</option>`).join('')}</select></label>
    </header><div id="library-entries">${solutionRows(list)}</div></section>
    <aside class="panel solution-inspector" id="solution-inspector" aria-label="Solution details" tabindex="-1"></aside></div>`;
}

function refreshSolutionList() {
  const list = filteredSolutions();
  retainLibrarySelection(list);
  const entries = $('#library-entries');
  entries.innerHTML = solutionRows(list);
  entries.scrollTop = 0;
  mountSolutionInspector();
}

function revealInspectedSolution() {
  const selected = $('#library-entries [aria-pressed="true"]');
  if (selected) {
    const list = $('#library-entries');
    const offset = selected.getBoundingClientRect().top - list.getBoundingClientRect().top;
    if (offset < 0 || offset + selected.offsetHeight > list.clientHeight) list.scrollTop += offset;
  }
  if (matchMedia('(max-width: 680px)').matches) {
    const panel = $('#solution-inspector');
    panel.focus({ preventScroll: true });
    panel.scrollIntoView({ block: 'start' });
  }
}

function selectInspectedSolution(id) {
  inspectedSolutionId = id;
  for (const button of document.querySelectorAll('#library-entries [data-inspect]')) {
    button.setAttribute('aria-pressed', String(button.dataset.inspect === id));
  }
  mountSolutionInspector();
  revealInspectedSolution();
}

function mediaDuration(milliseconds) {
  if (!(milliseconds > 0)) return '';
  if (milliseconds < 60000) return `${Number((milliseconds / 1000).toFixed(1))} s`;
  const seconds = Math.round(milliseconds / 1000);
  return `${Math.floor(seconds / 60)}m ${String(seconds % 60).padStart(2, '0')}s`;
}

function lastModifiedLabel(stamp) {
  if (typeof stamp !== 'string') return '';
  const date = new Date(stamp.replace(' ', 'T').replace(/(\.\d{3})\d+/, '$1'));
  return Number.isFinite(date.getTime())
    ? new Intl.DateTimeFormat(undefined, {dateStyle: 'medium', timeStyle: 'short'}).format(date) : '';
}

function detailFields(rows) {
  return `<dl class="solution-properties">${rows.filter(([,v]) => v).map(([label, value]) =>
    `<div><dt>${esc(label)}</dt><dd>${esc(value)}</dd></div>`).join('')}</dl>`;
}

function solutionUsage(id) {
  const used = new Set(project.cues.filter((cue) => cue.solutionId === id).map((cue) => cue.screenId));
  const screens = project.screens.filter((s) => used.has(s.id));
  return `<div class="solution-usage"><h3>Scheduled on</h3>${screens.length
    ? `<ul>${screens.map((s) => `<li><button type="button" data-filter="${esc(s.id)}" title="Open ${esc(s.name)} on the board">${icon('screen', 13)}${esc(s.name)}</button></li>`).join('')}</ul>`
    : '<p>No scheduled blocks.</p>'}</div>`;
}

function previewFallback(solution, message) {
  const poster = solutionThumbnail(solution);
  return `<div class="solution-stage">${poster
    ? `<img src="${esc(poster)}" alt="Thumbnail of ${esc(solution.name)}" onerror="this.hidden=true">`
    : icon('layers', 32)}</div>${message ? `<p class="preview-note">${esc(message)}</p>` : ''}`;
}

function paintSolutionMedia(root, solution, detail, index, status) {
  const items = Array.isArray(detail?.items) ? detail.items : [];
  const item = items[index];
  const source = solution.source || {};
  const stage = root.querySelector('[data-media-stage]');
  const url = item?.url;
  const supported = item?.type === 'video' || item?.type === 'image';
  const validUrl = typeof url === 'string' && url === `/api/solutions/${encodeURIComponent(solution.id)}/media/${index}`;
  if (validUrl && supported) {
    const poster = solutionThumbnail(solution);
    const name = esc(item.fileName || item.name || solution.name);
    stage.innerHTML = item.type === 'video'
      ? `<div class="solution-stage"><video controls playsinline preload="metadata" aria-label="Preview ${name}" ${poster ? `poster="${esc(poster)}"` : ''} src="${esc(url)}"></video></div>`
      : `<div class="solution-stage"><img src="${esc(url)}" alt="Preview of ${name}"></div>`;
    const media = stage.querySelector('video,img');
    media.addEventListener('error', () => {
      if (stage.contains(media)) stage.innerHTML = previewFallback(solution, 'This browser could not display the media file.');
    }, {once: true});
  } else {
    const message = status || (item ? 'A browser preview is unavailable for this item.' : 'No media preview is available.');
    stage.innerHTML = previewFallback(solution, message);
  }
  const size = item?.bytes ?? source.bytes;
  const fileName = item?.fileName || source.fileName;
  const extension = /\.([a-z0-9]+)$/i.exec(fileName || '')?.[1];
  const fields = [
    ['Canvas', `${solution.width} × ${solution.height} px`],
    ['Duration', source.kind !== 'localImage' && mediaDuration(detail?.durationMs || source.durationMs)],
    ['Playback', source.kind === 'localImage' && 'Holds for the scheduled block'],
    ['Source', solutionSourceLabel(solution)],
    ['File', fileName],
    ['Import path', solution.importPath && solution.importPath !== fileName && solution.importPath],
    ['Format', [extension?.toUpperCase(), item?.codec || source.codec].filter(Boolean).join(' · ')],
    ['File size', size > 0 && readableSize(size)],
    ['Scene', items.length > 1 && item?.scene],
    ['Item duration', items.length > 1 && mediaDuration(item?.durationMs)],
    ['Last modified', lastModifiedLabel(detail?.modified || source.modified)],
  ];
  root.querySelector('[data-solution-fields]').innerHTML = detailFields(fields);
}

async function mountSolutionInspector() {
  const root = $('#solution-inspector');
  if (root && root.dataset.showing === inspectedSolutionId) return;
  solutionRequest?.abort();
  solutionRequest = null;
  if (!root) return;
  root.dataset.showing = inspectedSolutionId;
  const solution = getSolution(inspectedSolutionId);
  if (!solution) {
    root.innerHTML = '<p class="empty">Select a solution to see its preview and details.</p>';
    return;
  }
  root.innerHTML = `<header class="inspector-head"><div><span class="inspector-label">Solution details</span><h2>${esc(solution.name)}</h2></div>
    ${btn('Schedule', '', 'plus', 'btn-primary compact', `data-solution="${esc(solution.id)}"`)}</header>
    <div data-item-picker></div><div data-media-stage></div><div data-solution-fields></div>${solutionUsage(solution.id)}`;
  let unavailable = '';
  if (!solution.source?.playlistUuid && !['localVideo', 'localImage'].includes(solution.source?.kind)) unavailable = 'This planning reference has no attached media.';
  else if (solution.missing) unavailable = 'The source solution is missing from the ViPlex library.';
  else if (location.protocol === 'file:') unavailable = 'Open Relay Studio using the launcher to preview media.';
  paintSolutionMedia(root, solution, null, 0, unavailable || 'Loading media preview…');
  if (unavailable) return;

  const request = new AbortController();
  solutionRequest = request;
  try {
    const response = await fetch(`/api/solutions/${encodeURIComponent(solution.id)}`, {signal: request.signal, cache: 'no-store'});
    if (!response.ok) throw new Error('Media details could not be loaded from the local library.');
    const detail = await response.json();
    if (request.signal.aborted || !root.isConnected) return;
    const items = Array.isArray(detail.items) ? detail.items : [];
    if (items.length > 1) {
      const picker = root.querySelector('[data-item-picker]');
      picker.innerHTML = `<label class="media-picker">Preview item<select>${items.map((item, i) =>
        `<option value="${i}">${i + 1}. ${esc(item.name || item.fileName || item.type || 'Item')}</option>`).join('')}</select></label>`;
      picker.querySelector('select').onchange = (e) => paintSolutionMedia(root, solution, detail, Number(e.target.value));
    }
    paintSolutionMedia(root, solution, detail, 0);
  } catch (error) {
    if (!request.signal.aborted && root.isConnected) paintSolutionMedia(root, solution, null, 0, error.message);
  }
}
