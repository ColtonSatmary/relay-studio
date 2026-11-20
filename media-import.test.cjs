'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const surface = { addEventListener() {} };
const context = vm.createContext({ document: surface, $: () => surface });
vm.runInContext(fs.readFileSync(path.join(__dirname, 'media-import.js'), 'utf8'), context);

function fileEntry(name, type, fullPath = name) {
  return {
    isFile: true,
    name,
    fullPath,
    file(success) {
      success({ name, type });
    },
  };
}
function directory(name, batches) {
  return {
    isDirectory: true,
    name,
    createReader() {
      let next = 0;
      return {
        readEntries(success) {
          success(batches[next++] || []);
        },
      };
    },
  };
}
test('folder drop drains every directory batch, recursively, while preserving file paths', async () => {
  const first = Array.from({ length: 100 }, (_, i) =>
    fileEntry(`video-${i}.mp4`, 'video/mp4', `/Show/video-${i}.mp4`),
  );
  const sub = directory('Day 2', [
    [
      fileEntry('Doors.Open.mov', '', '/Show/Day 2/Doors.Open.mov'),
      fileEntry('notes.txt', 'text/plain', '/Show/Day 2/notes.txt'),
    ],
  ]);
  const root = directory('Show', [first, [sub]]);
  const files = [],
    errors = [];
  await context.readDroppedEntry(root, files, errors);
  assert.equal(files.length, 102);
  const videos = files.filter((item) => context.isVideo(item.file));
  assert.equal(videos.length, 101);
  assert.equal(videos.at(-1).path, 'Show/Day 2/Doors.Open.mov');
  assert.deepEqual(errors, []);
});
test('an unreadable folder entry reports the file and allows the remaining videos through', async () => {
  const broken = {
    isFile: true,
    name: 'Missing.mp4',
    file(_, fail) {
      fail(new Error('Unavailable'));
    },
  };
  const root = directory('Show', [[broken, fileEntry('Finale.MP4', '')]]);
  const files = [],
    errors = [];
  await context.readDroppedEntry(root, files, errors);
  assert.deepEqual(
    files.map((item) => item.file.name),
    ['Finale.MP4'],
  );
  assert.deepEqual(errors, ['Missing.mp4: Unavailable']);
  assert.ok(context.isVideo(files[0].file));
});

test('mixed nested folders include supported raster images and skip unrelated files', async () => {
  const root = directory('Show', [[
    fileEntry('Intro.mp4', 'video/mp4', '/Show/Intro.mp4'),
    directory('Stills', [[
      fileEntry('Welcome.JPG', 'image/jpeg', '/Show/Stills/Welcome.JPG'),
      fileEntry('Sponsor.JPEG', '', '/Show/Stills/Sponsor.JPEG'),
      fileEntry('Unsupported.png', 'image/png', '/Show/Stills/Unsupported.png'),
      fileEntry('Misnamed.png', 'image/jpeg', '/Show/Stills/Misnamed.png'),
      fileEntry('notes.txt', 'text/plain', '/Show/Stills/notes.txt'),
    ]]),
  ]]);
  const files = [], errors = [];
  await context.readDroppedEntry(root, files, errors);
  assert.deepEqual(files.filter(({ file }) => context.isSupportedMedia(file)).map(({ path }) => path), [
    'Show/Intro.mp4', 'Show/Stills/Welcome.JPG', 'Show/Stills/Sponsor.JPEG', 'Show/Stills/Unsupported.png', 'Show/Stills/Misnamed.png',
  ]);
  assert.equal(context.isVideo({ name: 'Welcome.JPG', type: 'image/jpeg' }), false);
  assert.deepEqual(errors, []);
});

test('image extensions include common formats, vectors and Windows codec candidates', () => {
  for (const extension of 'jpg jpeg png gif bmp tif tiff webp ico avif heic heif svg psd tga jp2 exr dds ppm dng cr2 nef arw jxr wdp'.split(' ')) {
    assert.equal(context.isImage({ name: `Still.${extension.toUpperCase()}`, type: '' }), true, extension);
  }
  assert.equal(context.isImage({ name: 'document.pdf', type: 'image/png' }), false);
});

test('SVG validation rejects active nodes, external fetches, obfuscated CSS, and XML declarations', () => {
  const svgNode = (localName, attributes = [], textContent = '') => ({ localName, namespaceURI: 'http://www.w3.org/2000/svg', attributes: attributes.map(([localName, value]) => ({ localName, value })), textContent });
  const root = svgNode('svg'); let nodes = [root, svgNode('rect', [['fill', 'url(#fill)']])];
  context.DOMParser = class { parseFromString() { return { documentElement: root, querySelector: () => null, querySelectorAll: () => nodes }; } };
  assert.equal(context.validateSvgImage('<svg/>'), '<svg/>');
  for (const bad of [svgNode('script'), svgNode('foreignObject'), svgNode('image', [['href', 'https://example.test/pixel']]), svgNode('use', [['href', 'javascript:alert(1)']]), svgNode('rect', [['onload', 'alert(1)']]), svgNode('style', [], '@import "https://example.test/x"'), svgNode('style', [], 'rect {fill:u\\72l(https://example.test/x)}'), svgNode('rect', [['fill', 'url(https://example.test/x)']])]) {
    nodes = [root, bad]; assert.throws(() => context.validateSvgImage('<svg/>'), /unsupported|static PNG|external/i);
  }
  for (const declaration of ['<!DOCTYPE svg><svg/>', '<!ENTITY x SYSTEM "file:///x"><svg/>', '<?xml-stylesheet href="https://example.test/x"?><svg/>']) assert.throws(() => context.validateSvgImage(declaration), /document types/i);
});

test('browser image conversion keeps original names and checks canvas bounds', async () => {
  const painted = [], revoked = []; let width = 640;
  context.File = File; context.Blob = Blob; context.setTimeout = setTimeout; context.clearTimeout = clearTimeout;
  context.URL = { createObjectURL: () => 'blob:fixture', revokeObjectURL: (url) => revoked.push(url) };
  context.Image = class { naturalWidth = width; naturalHeight = 360; set src(value) { if (value) queueMicrotask(() => this.onload()); } };
  context.document = { createElement: () => ({ getContext: () => ({ fillRect: (...args) => painted.push(args), drawImage() {} }), toBlob: (done) => done(new Blob(['fixture pixels'], { type: 'image/png' })) }) };
  const file = new File(['avif fixture'], 'Welcome.PHOTO.avif', { type: 'image/avif' });
  const converted = await context.prepareBrowserImage(file);
  assert.equal(converted.file.name, 'Welcome.PHOTO.png'); assert.equal(converted.sourceName, file.name);
  assert.equal(converted.file.type, 'image/png'); assert.deepEqual(painted, [[0, 0, 640, 360]]); assert.deepEqual(revoked, ['blob:fixture']);
  width = 100000;
  await assert.rejects(() => context.prepareBrowserImage(file), /64 megapixels/);
  assert.equal(revoked.length, 2);
});

test('the import workflow uploads and saves both supported media kinds while counting skipped files', async () => {
  const progress = {}, label = {}, count = {};
  const dialog = { open: false, addEventListener() {}, removeEventListener() {} };
  const form = {
    querySelector(selector) { return selector === 'progress' ? progress : selector === '[data-file]' ? label : count; },
    querySelectorAll() { return []; },
  };
  const uploaded = [], reports = [];
  const workflow = vm.createContext({
    document: surface, $: (selector) => selector === '#dialog' ? dialog : surface,
    project: { solutions: [] }, projectStoreReady: true, loadError: false,
    notice(message) { throw new Error(message); }, openDialog() { return form; },
    fetch: async () => ({ ok: true, json: async () => ({ exportToken: 'fixture-token' }) }),
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'media-import.js'), 'utf8'), workflow);
  workflow.fileUpload = async (file, token, progress) => {
    assert.equal(token, 'fixture-token');
    uploaded.push(file.name); progress(file.size, file.size);
    return { id: file.name, name: file.name.replace(/\.[^.]+$/, ''), source: { kind: /jpe?g$/i.test(file.name) ? 'localImage' : 'localVideo' } };
  };
  workflow.commit = async (next) => { workflow.project = next; };
  workflow.uploadReport = (...args) => reports.push(args);
  await workflow.importMediaItems(async () => [
    { file: { name: '02-Sponsor.JPEG', type: '', size: 200 }, path: 'Show/02-Sponsor.JPEG' },
    { file: { name: '01-Opening.mp4', type: 'video/mp4', size: 400 }, path: 'Show/01-Opening.mp4' },
    { file: { name: 'notes.txt', type: 'text/plain', size: 20 }, path: 'Show/notes.txt' },
  ]);
  assert.deepEqual(uploaded, ['01-Opening.mp4', '02-Sponsor.JPEG']);
  assert.equal(workflow.project.solutions.length, 2);
  assert.equal(workflow.project.solutions[0].source.kind, 'localImage');
  assert.equal(workflow.project.solutions[0].importPath, 'Show/02-Sponsor.JPEG');
  assert.equal(reports[0][0].length, 2);
  assert.equal(reports[0][2], 1);
  assert.equal(reports[0][3].length, 0);
});

test('image library filters and playback availability include JPG solutions', () => {
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'solution-viewer.js'), 'utf8'), context);
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'usb-playback.js'), 'utf8'), context);
  const still = { id: 'image-fixture', source: { kind: 'localImage' } };
  const video = { id: 'video-fixture', source: { kind: 'localVideo' } };
  const native = { id: 'viplex-fixture', source: { playlistUuid: 'fixture' } };
  assert.equal(context.solutionSourceLabel(still), 'Imported image');
  assert.equal(context.matchesLibraryType(still, 'image'), true);
  assert.equal(context.matchesLibraryType(video, 'image'), false);
  assert.equal(context.matchesLibraryType(still, 'video'), false);
  assert.equal(context.matchesLibraryType(still, 'imported'), true);
  assert.equal(context.matchesLibraryType(video, 'imported'), true);
  assert.equal(context.matchesLibraryType(native, 'imported'), false);
  assert.equal(context.matchesLibraryType(native, 'all'), true);
  assert.equal(context.canUsbPlaybackSolution(still), true);
  assert.equal(context.canUsbPlaybackSolution({ ...still, missing: true }), false);
  assert.equal(context.canUsbPlaybackSolution({ id: 'reference' }), false);
});

test('a local image renders as an image with schedule-based playback details', () => {
  const stage = { innerHTML: '', querySelector() { return { addEventListener() {} }; } }, fields = { innerHTML: '' };
  context.esc = (value) => String(value).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/"/g, '&quot;');
  context.solutionThumbnail = () => '';
  const solution = { id: 'image-fixture', name: 'Welcome', width: 1920, height: 1080,
    source: { kind: 'localImage', fileName: 'Welcome.jpg', durationMs: 10000, bytes: 200, codec: 'jpeg' } };
  const detail = { durationMs: 10000, items: [{ type: 'image', fileName: 'Welcome.jpg', url: '/api/solutions/image-fixture/media/0' }] };
  context.paintSolutionMedia({ querySelector: (selector) => selector === '[data-media-stage]' ? stage : fields }, solution, detail, 0, '');
  assert.match(stage.innerHTML, /<img src="\/api\/solutions\/image-fixture\/media\/0"/);
  assert.doesNotMatch(stage.innerHTML, /<video/);
  assert.match(fields.innerHTML, /Holds for the scheduled block/);
  assert.doesNotMatch(fields.innerHTML, /<dt>Duration<\/dt>/);
});
