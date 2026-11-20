'use strict';

const videoTypes = new Set(
  'mp4 m4v mov mkv webm avi wmv asf mpeg mpg mpe m2v ts mts m2ts mxf vob flv ogv 3gp 3g2'.split(' '),
);
const imageTypes = new Set('jpg jpeg jpe jfif png apng gif bmp dib tif tiff webp ico avif heic heif svg psd tga j2k jp2 jpf jpx exr dds pbm pgm ppm pnm dng cr2 nef arw orf rw2 jxr wdp'.split(' '));
let importingMedia = false;
let libraryType = 'all';

function mediaDropZone() {
  return `<section class="video-drop"><div class="upload-mark">${icon('import', 24)}</div><div><h2>Drop videos or images</h2><p>Each file becomes a solution with its filename. Drop folders too. Images use the first frame or page; transparency becomes black.</p></div><div class="drop-actions"><button class="btn btn-primary" type="button" data-video-picker="folder">${icon('folder', 15)} Choose folder</button><button type="button" class="text-link" data-video-picker="files">Choose files</button></div></section>`;
}
function isVideo(file) {
  return /^video\//i.test(file.type || '') || videoTypes.has(file.name.split('.').pop().toLowerCase());
}
function isImage(file) {
  return imageTypes.has((file.name || '').split('.').pop().toLowerCase());
}
function isSupportedMedia(file) {
  return isVideo(file) || isImage(file);
}
function validateSvgImage(text) {
  if (text.length > 2 * 1024 * 1024 || /<!DOCTYPE|<!ENTITY|<\?(?!xml\s)/i.test(text)) throw new Error('Export this SVG as PNG: embedded document types or oversized SVG markup are unsupported.');
  const parsed = new DOMParser().parseFromString(text, 'image/svg+xml');
  const root = parsed.documentElement;
  if (!root || root.localName !== 'svg' || parsed.querySelector('parsererror')) throw new Error('The SVG file is not valid.');
  const nodes = [...parsed.querySelectorAll('*')];
  const allowed = new Set('svg g defs symbol use path rect circle ellipse line polyline polygon text tspan textPath title desc clipPath mask pattern linearGradient radialGradient stop filter feBlend feColorMatrix feComponentTransfer feComposite feConvolveMatrix feDiffuseLighting feDisplacementMap feDistantLight feDropShadow feFlood feFuncA feFuncB feFuncG feFuncR feGaussianBlur feImage feMerge feMergeNode feMorphology feOffset fePointLight feSpecularLighting feSpotLight feTile feTurbulence image style'.split(' '));
  if (nodes.length > 50000) throw new Error('This SVG is too complex. Export it as PNG and try again.');
  for (const node of nodes) {
    if (node.namespaceURI !== 'http://www.w3.org/2000/svg' || !allowed.has(node.localName)) throw new Error('This SVG contains active or unsupported elements. Export a static PNG copy.');
    for (const attribute of node.attributes) {
      const value = attribute.value.trim();
      if (/^on/i.test(attribute.localName)) throw new Error('SVG event handlers are unsupported. Export a static PNG copy.');
      if (attribute.localName === 'href' && !/^#[\w:.-]+$/.test(value) && !/^data:image\/(?:png|jpeg|webp);base64,[a-z0-9+/=\s]+$/i.test(value)) throw new Error('SVG external resources are unsupported. Embed its images or export as PNG.');
      if (/\\|@/.test(value) || /url\s*\(\s*['"]?(?!#)/i.test(value.replace(/url\s*\(\s*['"]?#[\w:.-]+['"]?\s*\)/gi, ''))) throw new Error('SVG external styles or resources are unsupported. Export it as PNG.');
    }
    if (node.localName === 'style' && (/\\|@/.test(node.textContent) || /url\s*\(/i.test(node.textContent.replace(/url\s*\(\s*['"]?#[\w:.-]+['"]?\s*\)/gi, '')))) throw new Error('SVG external styles or resources are unsupported. Export it as PNG.');
  }
  return text;
}
async function prepareBrowserImage(file) {
  if (!/\.(?:svg|avif)$/i.test(file.name)) return { file, sourceName: '' };
  if (file.size > 256 * 1024 * 1024) throw new Error('This image file is too large. Export a copy smaller than 256 MB.');
  const blob = /\.svg$/i.test(file.name) ? new Blob([validateSvgImage(await file.text())], { type: 'image/svg+xml' }) : file;
  const url = URL.createObjectURL(blob), image = new Image();
  let timer;
  try {
    await new Promise((resolve, reject) => {
      timer = setTimeout(() => reject(new Error('Reading this image timed out. Export it as PNG or JPG.')), 20000);
      image.onload = resolve;
      image.onerror = () => reject(new Error('This browser could not decode the image. Export it as PNG or JPG.'));
      image.src = url;
    });
    const width = image.naturalWidth, height = image.naturalHeight;
    if (!width || !height || width > 32768 || height > 32768 || width * height > 64 * 1024 * 1024) throw new Error('Resize this image to at most 64 megapixels and 32768 pixels per side.');
    const canvas = document.createElement('canvas'); canvas.width = width; canvas.height = height;
    const painter = canvas.getContext('2d');
    painter.fillStyle = '#000'; painter.fillRect(0, 0, width, height); painter.drawImage(image, 0, 0);
    const pixels = await new Promise((resolve, reject) => canvas.toBlob(value => value ? resolve(value) : reject(new Error('The image could not be converted. Export it as PNG.')), 'image/png'));
    return { file: new File([pixels], file.name.replace(/\.[^.]+$/, '.png'), { type: 'image/png' }), sourceName: file.name };
  } finally { clearTimeout(timer); image.src = ''; URL.revokeObjectURL(url); }
}
function readableSize(bytes) {
  if (bytes >= 1073741824) return `${(bytes / 1073741824).toFixed(1)} GB`;
  return bytes >= 1048576 ? `${(bytes / 1048576).toFixed(1)} MB` : `${Math.ceil(bytes / 1024)} KB`;
}
function canImport() {
  if (importingMedia) {
    notice('An import is already in progress.');
    return false;
  }
  if (!project || !projectStoreReady || loadError) {
    notice('Open Launch Studio.cmd and reload the workspace to import media files.');
    return false;
  }
  if ($('#dialog').open) {
    notice('Finish the open dialog before importing media.');
    return false;
  }
  return true;
}
// A directory reader returns batches, with an empty batch marking the end.
async function readDroppedEntry(entry, items, errors) {
  if (entry.isFile) {
    try {
      const file = await new Promise((resolve, reject) => entry.file(resolve, reject));
      items.push({ file, path: (entry.fullPath || file.name).replace(/^\//, '') });
    } catch (e) {
      errors.push(`${entry.name}: ${e.message || 'Could not read this file.'}`);
    }
    return;
  }
  if (!entry.isDirectory) return;
  const reader = entry.createReader();
  for (;;) {
    const entries = await new Promise((resolve, reject) => reader.readEntries(resolve, reject));
    if (!entries.length) break;
    for (const child of entries) {
      try {
        await readDroppedEntry(child, items, errors);
      } catch (e) {
        errors.push(`${child.name}: ${e.message || 'Could not read this folder.'}`);
      }
    }
  }
}
function fileUpload(file, token, progress, onRequest, sourceName = '') {
  return new Promise((resolve, reject) => {
    const request = new XMLHttpRequest();
    request.open('POST', `/api/media?name=${encodeURIComponent(file.name)}${sourceName ? `&sourceName=${encodeURIComponent(sourceName)}` : ''}`);
    request.setRequestHeader('X-Studio-Token', token);
    request.setRequestHeader('Content-Type', 'application/octet-stream');
    request.upload.onprogress = (e) => {
      if (e.lengthComputable) progress(e.loaded, e.total);
    };
    request.upload.onload = () => progress(file.size, file.size);
    request.onload = () => {
      try {
        const result = JSON.parse(request.responseText);
        if (request.status < 200 || request.status >= 300 || !result.solution)
          throw new Error(result.error || `Import failed (${request.status}).`);
        resolve(result.solution);
      } catch (e) {
        reject(e);
      }
    };
    request.onerror = () => reject(new Error('Could not reach the local Studio service.'));
    request.onabort = () => reject(new Error('Import stopped.'));
    onRequest(request);
    request.send(file);
  });
}
function uploadReport(added, existing, ignored, errors, stopped) {
  const counts = [`${added.length} added`, `${existing} already in the library`];
  if (ignored) counts.push(`${ignored} unsupported ${ignored === 1 ? 'file' : 'files'} skipped`);
  if (errors.length) counts.push(`${errors.length} ${errors.length === 1 ? 'issue' : 'issues'}`);
  const form = openDialog({
    title: stopped ? 'Import stopped' : 'Media import complete',
    body: `<p class="dialog-copy">${esc(counts.join(' · '))}</p>${
      added.length
        ? `<div class="import-results">${added
            .slice(0, 8)
            .map(
              (s) =>
                `<div>${thumb(s)}<span><strong>${esc(s.name)}</strong><small>${s.width} × ${s.height} · ${s.source.kind === 'localImage' ? 'Still image' : `${(s.source.durationMs / 1000).toFixed(1)}s`}</small></span></div>`,
            )
            .join(
              '',
            )}</div>${added.length > 8 ? `<p class="field-help">And ${added.length - 8} more in the library.</p>` : ''}`
        : ''
    }${errors.length ? `<details class="import-errors" open><summary>Import details</summary><ul>${errors.map((text) => `<li>${esc(text)}</li>`).join('')}</ul></details>` : ''}`,
    extra:
      added.length || existing
        ? '<button type="button" class="btn btn-primary" data-show-media>Show imported media</button>'
        : '',
  });
  const show = form.querySelector('[data-show-media]');
  if (show)
    show.onclick = () => {
      closeDialog();
      libraryType = 'imported';
      query = '';
      if (added.length) inspectedSolutionId = added[0].id;
      goNav('solutions');
      revealInspectedSolution();
    };
}
async function importMediaItems(getItems) {
  if (!canImport()) return;
  importingMedia = true;
  let stopped = false,
    request = null,
    added = [],
    existing = 0,
    ignored = 0;
  const errors = [];
  const form = openDialog({
    title: 'Import videos and images',
    subtitle: 'Files are copied into this computer’s Relay Studio library.',
    body: `<div class="import-progress"><strong data-file>Reading files…</strong><progress max="100" value="0" aria-label="Current media file"></progress><p class="field-help" data-count></p></div>`,
  });
  const dlg = $('#dialog'),
    fileLabel = form.querySelector('[data-file]'),
    bar = form.querySelector('progress'),
    count = form.querySelector('[data-count]');
  function stop() {
    stopped = true;
    request?.abort();
    fileLabel.textContent = 'Finishing import…';
  }
  const cancel = (e) => {
    e.preventDefault();
    stop();
  };
  dlg.addEventListener('cancel', cancel);
  form.querySelectorAll('[data-close]').forEach((b) => {
    b.onclick = stop;
    if (b.textContent === 'Close') b.textContent = 'Stop import';
  });
  try {
    const items = await getItems(errors);
    const media = items
      .filter(({ file }) => isSupportedMedia(file))
      .sort((a, b) => a.path.localeCompare(b.path, undefined, { numeric: true }));
    ignored = items.length - media.length;
    if (!media.length && !errors.length) errors.push('The selection contains no supported videos or images.');
    const session = await fetch('/api/session', { cache: 'no-store' });
    if (!session.ok) throw new Error('Open the Studio launcher and retry.');
    const { exportToken } = await session.json();
    for (let i = 0; i < media.length && !stopped; i++) {
      const { file, path } = media[i];
      fileLabel.textContent = path;
      bar.value = 0;
      count.textContent = `File ${i + 1} of ${media.length} · ${readableSize(file.size)}`;
      let solution;
      try {
        const prepared = await prepareBrowserImage(file);
        if (stopped) break;
        solution = await fileUpload(
          prepared.file,
          exportToken,
          (done, total) => {
            bar.value = total ? (done / total) * 100 : 0;
            count.textContent =
              done === total
                ? `File ${i + 1} of ${media.length} · Checking media and building preview…`
                : `File ${i + 1} of ${media.length} · ${readableSize(done)} of ${readableSize(total)}`;
          },
          (xhr) => (request = xhr),
          prepared.sourceName,
        );
      } catch (e) {
        if (!stopped) errors.push(`${path}: ${e.message}`);
        continue;
      } finally {
        request = null;
      }
      if (project.solutions.some((s) => s.id === solution.id)) {
        existing++;
        continue;
      }
      // Persist each success so a later bad file or cancellation cannot discard it.
      try {
        solution.importPath = path;
        await commit({ ...project, solutions: [solution, ...project.solutions] }, '');
        added.push(solution);
      } catch (e) {
        errors.push(`${path}: ${e.message} Reopen the board and drop the folder again to retry.`);
        break;
      }
    }
  } catch (e) {
    errors.push(e.message);
  } finally {
    importingMedia = false;
    dlg.removeEventListener('cancel', cancel);
    uploadReport(added, existing, ignored, errors, stopped);
  }
}
document.addEventListener('click', (e) => {
  const picker = e.target.closest('[data-video-picker]');
  if (!picker) return;
  if (canImport()) $(picker.dataset.videoPicker === 'folder' ? '#video-folder' : '#video-files').click();
});
for (const selector of ['#video-folder', '#video-files']) {
  $(selector).addEventListener('change', (e) => {
    const files = Array.from(e.target.files || []);
    e.target.value = '';
    if (files.length)
      void importMediaItems(() =>
        files.map((file) => ({ file, path: file.webkitRelativePath || file.name })),
      );
  });
}
function draggedFiles(event) {
  return Array.from(event.dataTransfer?.types || []).includes('Files');
}
let dragDepth = 0;
document.addEventListener('dragenter', (e) => {
  if (!draggedFiles(e)) return;
  e.preventDefault();
  dragDepth++;
  if (!$('#dialog').open && !importingMedia) document.body.classList.add('dragging-files');
});
document.addEventListener('dragover', (e) => {
  if (draggedFiles(e)) {
    e.preventDefault();
    e.dataTransfer.dropEffect = $('#dialog').open ? 'none' : 'copy';
  }
});
document.addEventListener('dragleave', (e) => {
  if (!draggedFiles(e)) return;
  dragDepth = Math.max(0, dragDepth - 1);
  if (!dragDepth) document.body.classList.remove('dragging-files');
});
document.addEventListener('drop', (e) => {
  if (!draggedFiles(e)) return;
  e.preventDefault();
  dragDepth = 0;
  document.body.classList.remove('dragging-files');
  // Capture entry handles before the drag event's protected data store closes.
  const entries = Array.from(e.dataTransfer.items || [])
    .map((item) => item.webkitGetAsEntry?.())
    .filter(Boolean);
  const files = Array.from(e.dataTransfer.files || []);
  void importMediaItems(async (errors) => {
    if (!entries.length) return files.map((file) => ({ file, path: file.name }));
    const items = [];
    for (const entry of entries) {
      try {
        await readDroppedEntry(entry, items, errors);
      } catch (error) {
        errors.push(`${entry.name}: ${error.message}`);
      }
    }
    return items;
  });
});
