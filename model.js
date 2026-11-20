(function (root, factory) {
  'use strict';
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.StudioModel = api;
})(globalThis, function () {
  'use strict';

  const dayMs = 86400000;
  const dayMinutes = 1440;
  const blockMinutes = 15;
  const pad = (value) => String(value).padStart(2, '0');

  // Dates are calendar labels in the screen's local time. Use UTC arithmetic
  // on those labels so a clock change never adds or removes a schedule day.
  function dayNumber(date) {
    if (typeof date !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(date)) {
      throw new Error('Enter a date in YYYY-MM-DD format.');
    }
    const [year, month, day] = date.split('-').map(Number);
    const value = new Date(0);
    value.setUTCFullYear(year, month - 1, day);
    if (
      !year ||
      value.getUTCFullYear() !== year ||
      value.getUTCMonth() !== month - 1 ||
      value.getUTCDate() !== day
    ) {
      throw new Error(`Invalid calendar date: ${date}.`);
    }
    return value.getTime() / dayMs;
  }

  function dateString(serial) {
    const date = new Date(serial * dayMs);
    const year = date.getUTCFullYear();
    if (!(year >= 1 && year <= 9999)) throw new Error('Date is outside the supported range.');
    return `${String(year).padStart(4, '0')}-${pad(date.getUTCMonth() + 1)}-${pad(date.getUTCDate())}`;
  }

  function localDate(value = new Date()) {
    const year = value.getFullYear();
    if (!(year >= 1 && year <= 9999)) throw new Error('Invalid local date.');
    return `${String(year).padStart(4, '0')}-${pad(value.getMonth() + 1)}-${pad(value.getDate())}`;
  }

  function addDays(date, delta) {
    if (!Number.isSafeInteger(delta)) throw new Error('Day offset must be a whole number.');
    return dateString(dayNumber(date) + delta);
  }

  function weekdayNumber(serial) {
    // The Unix epoch fell on a Thursday (4).
    return (((serial + 4) % 7) + 7) % 7;
  }

  function weekday(date) {
    return weekdayNumber(dayNumber(date));
  }

  function timeMinutes(time) {
    if (time === '24:00') return dayMinutes;
    if (typeof time !== 'string' || !/^([01]\d|2[0-3]):[0-5]\d$/.test(time)) {
      throw new Error('Enter a clock time in HH:MM format.');
    }
    return Number(time.slice(0, 2)) * 60 + Number(time.slice(3));
  }

  function firstMatchingDate(firstDay, lastDay, mask, excluded, otherExcluded) {
    if (!mask || firstDay > lastDay) return null;
    // Offset to the next selected weekday, starting with this one. Reuse
    // the offsets for each successive week if all candidates are excluded.
    const offsets = [];
    for (let offset = 0; offset < 7; offset++) {
      if (mask & (1 << weekdayNumber(firstDay + offset))) offsets.push(offset);
    }
    for (let week = firstDay; week <= lastDay; week += 7) {
      for (const offset of offsets) {
        const day = week + offset;
        if (day > lastDay) return null;
        if (!excluded?.has(day) && !otherExcluded?.has(day)) return day;
      }
    }
    return null;
  }

  function segments(cue) {
    const start = timeMinutes(cue.start);
    const end = timeMinutes(cue.end);
    const firstDay = dayNumber(cue.startDate);
    const lastDay = cue.endDate === '' ? Infinity : dayNumber(cue.endDate);
    const mask = cue.days.reduce((bits, day) => bits | (1 << day), 0);
    const excluded = (cue.excludedDates || []).map(dayNumber);
    const overnight = end < start;
    const parts = [
      {
        firstDay,
        lastDay,
        mask,
        excluded: new Set(excluded),
        startMinute: start,
        endMinute: overnight ? dayMinutes : end,
        continued: false,
        continues: overnight && end > 0,
      },
    ];
    if (overnight && end > 0) {
      // The second part belongs to the next calendar day, including after
      // the last start date of a series. Rotate Saturday into Sunday.
      parts.push({
        firstDay: firstDay + 1,
        lastDay: lastDay + 1,
        mask: ((mask << 1) & 127) | (mask >> 6),
        excluded: new Set(excluded.map((day) => day + 1)),
        startMinute: 0,
        endMinute: end,
        continued: true,
        continues: false,
      });
    }
    return parts;
  }

  function occurrences(project, date, screenId) {
    const day = dayNumber(date);
    const bit = 1 << weekdayNumber(day);
    const result = [];
    for (const cue of project.cues) {
      if (screenId != null && cue.screenId !== screenId) continue;
      for (const part of segments(cue)) {
        if (day < part.firstDay || day > part.lastDay || !(part.mask & bit) || part.excluded.has(day))
          continue;
        const { startMinute, endMinute, continued, continues } = part;
        result.push({ cue, startMinute, endMinute, continued, continues });
      }
    }
    return result.sort(
      (a, b) =>
        a.startMinute - b.startMinute || a.endMinute - b.endMinute || a.cue.id.localeCompare(b.cue.id),
    );
  }

  function nextQuarterStart(minute) {
    return Math.max(0, Math.min(dayMinutes - blockMinutes, Math.ceil(minute / blockMinutes) * blockMinutes));
  }

  function suggestBlockStart(project, date, screenId, minute) {
    const preferred = nextQuarterStart(minute);
    const bookings = occurrences(project, date, screenId);
    function findSpace(start) {
      for (const { startMinute, endMinute } of bookings) {
        if (start + blockMinutes <= startMinute) break;
        if (start < endMinute) start = Math.ceil(endMinute / blockMinutes) * blockMinutes;
      }
      return start + blockMinutes <= dayMinutes ? start : null;
    }
    return findSpace(preferred) ?? findSpace(0) ?? preferred;
  }

  function cueHasOccurrences(cue) {
    const { firstDay, lastDay, mask, excluded } = segments(cue)[0];
    return firstMatchingDate(firstDay, lastDay, mask, excluded) !== null;
  }

  function isText(value) {
    return typeof value === 'string' && value.trim().length > 0;
  }

  function keyedList(list, label) {
    if (!Array.isArray(list)) throw new Error(`The project needs a ${label} list.`);
    const result = new Map();
    for (const item of list) {
      if (!item || !isText(item.id)) throw new Error(`Each ${label} needs an ID.`);
      if (result.has(item.id)) throw new Error(`Duplicate ${label} ID: ${item.id}.`);
      result.set(item.id, item);
    }
    return result;
  }

  function validateDisplay(item, label) {
    if (!isText(item.name)) throw new Error(`Each ${label} needs a name.`);
    if (![item.width, item.height].every((value) => Number.isSafeInteger(value) && value > 0)) {
      throw new Error(`Set a positive pixel width and height for “${item.name}”.`);
    }
  }

  function validateCue(cue, screens, solutions) {
    if (!screens.has(cue.screenId)) throw new Error('Choose an existing schedule for each cue.');
    if (!solutions.has(cue.solutionId)) throw new Error('Choose an existing solution for each cue.');
    if (
      !Array.isArray(cue.days) ||
      !cue.days.length ||
      !cue.days.every((day) => Number.isInteger(day) && day >= 0 && day < 7) ||
      new Set(cue.days).size !== cue.days.length
    ) {
      throw new Error('Select one or more distinct days of the week.');
    }
    if (cue.excludedDates !== undefined && !Array.isArray(cue.excludedDates)) {
      throw new Error('Excluded dates must be a list of calendar dates.');
    }
    const start = timeMinutes(cue.start);
    const end = timeMinutes(cue.end);
    if (start === dayMinutes) throw new Error('Start time must be earlier than 24:00.');
    if (start === end) throw new Error('Set different start and end times. For all day, use 00:00 to 24:00.');
    const parts = segments(cue);
    const { firstDay, lastDay, mask } = parts[0];
    if (firstDay > lastDay) throw new Error('The last date must be on or after the first date.');
    if (firstMatchingDate(firstDay, lastDay, mask) === null) {
      throw new Error('The selected weekdays do not occur in this date range.');
    }
    return parts;
  }

  function overlapDay(part, other) {
    if (other.startMinute >= part.endMinute || part.startMinute >= other.endMinute) return null;
    return firstMatchingDate(
      Math.max(part.firstDay, other.firstDay),
      Math.min(part.lastDay, other.lastDay),
      part.mask & other.mask,
      part.excluded,
      other.excluded,
    );
  }

  function validateProject(project) {
    if (!project || project.version !== 1) throw new Error('Open a version 1 Studio project.');
    const screens = keyedList(project.screens, 'schedule');
    const solutions = keyedList(project.solutions, 'solution');
    const cues = keyedList(project.cues, 'cue');
    for (const item of screens.values()) validateDisplay(item, 'schedule');
    for (const item of solutions.values()) {
      validateDisplay(item, 'solution');
      if (!isText(item.color)) throw new Error(`Choose a color for “${item.name}”.`);
    }

    const byScreen = new Map();
    for (const cue of cues.values()) {
      const parts = validateCue(cue, screens, solutions);
      const earlier = byScreen.get(cue.screenId) || [];
      for (const part of parts) {
        for (const other of earlier) {
          const day = overlapDay(part, other);
          if (day === null) continue;
          const minute = Math.max(part.startMinute, other.startMinute);
          const time = `${pad(Math.floor(minute / 60))}:${pad(minute % 60)}`;
          const name = solutions.get(cue.solutionId).name;
          const otherName = solutions.get(other.cue.solutionId).name;
          const screen = screens.get(cue.screenId).name;
          throw new Error(`“${name}” overlaps “${otherName}” on ${screen} on ${dateString(day)} at ${time}.`);
        }
      }
      for (const part of parts) earlier.push({ ...part, cue });
      byScreen.set(cue.screenId, earlier);
    }
    return project;
  }

  function clock(minute) {
    return `${pad(Math.floor(minute / 60))}:${pad(minute % 60)}`;
  }

  function reorderScreens(project, visibleIds, movedId, anchorId, after) {
    if (!Array.isArray(visibleIds) || typeof after !== 'boolean') {
      throw new Error('Choose a position in the visible schedule lanes.');
    }
    const visible = new Set(visibleIds);
    const lanes = project.screens.filter((screen) => visible.has(screen.id));
    if (visible.size !== visibleIds.length || lanes.length !== visible.size ||
        !visible.has(movedId) || !visible.has(anchorId)) {
      throw new Error('The visible schedules changed. Choose a lane and try again.');
    }
    if (movedId === anchorId) return project;
    const from = lanes.findIndex((screen) => screen.id === movedId);
    const [moved] = lanes.splice(from, 1);
    const to = lanes.findIndex((screen) => screen.id === anchorId) + (after ? 1 : 0);
    if (from === to) return project;
    lanes.splice(to, 0, moved);

    // In a filtered timeline only visible slots participate in the reorder.
    let next = 0;
    const screens = project.screens.map((screen) => visible.has(screen.id) ? lanes[next++] : screen);
    return { ...project, screens };
  }

  // Coordinates use the displayed day's midnight, including the hidden part
  // of a block that crosses midnight in either direction.
  function occurrenceBounds(item) {
    return {
      startMinute: timeMinutes(item.cue.start) - (item.continued ? dayMinutes : 0),
      endMinute: item.endMinute + (item.continues ? timeMinutes(item.cue.end) : 0),
    };
  }

  function allocateCueId(ids) {
    let id;
    do {
      id = globalThis.crypto?.randomUUID?.() ||
        `cue-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
    } while (ids.has(id));
    ids.add(id);
    return id;
  }

  function datedCue(template, id, date, from, to) {
    const firstDate = addDays(date, Math.floor(from / dayMinutes));
    const start = ((from % dayMinutes) + dayMinutes) % dayMinutes;
    const end = ((to % dayMinutes) + dayMinutes) % dayMinutes || dayMinutes;
    const cue = {
      ...template,
      id,
      startDate: firstDate,
      endDate: firstDate,
      start: clock(start),
      end: clock(end),
      days: [weekday(firstDate)],
    };
    delete cue.excludedDates;
    return cue;
  }

  function withoutStarts(cue, removedDates) {
    if (cue.startDate === cue.endDate) return null;
    const remaining = {
      ...cue,
      excludedDates: [...new Set([...(cue.excludedDates || []), ...removedDates])].sort(),
    };
    return cueHasOccurrences(remaining) ? remaining : null;
  }

  function editOccurrence(project, date, { cueId, continued = false, screenId, startMinute, endMinute }) {
    const source = project.cues.find((cue) => cue.id === cueId);
    const item = source && occurrences({ cues: [source] }, date).find((part) => part.continued === continued);
    if (!item) throw new Error('This block is no longer scheduled here.');
    if (!Number.isSafeInteger(startMinute) || !Number.isSafeInteger(endMinute) ||
        endMinute <= startMinute || startMinute >= dayMinutes || endMinute <= 0) {
      throw new Error('Choose a time range on the displayed day with the end after the start.');
    }
    const length = endMinute - startMinute;
    if (length > dayMinutes || (length === dayMinutes && startMinute !== 0)) {
      throw new Error('A block can run up to 24 hours. A full-day block runs from midnight to midnight.');
    }
    const before = occurrenceBounds(item);
    if (source.screenId === screenId && startMinute === before.startMinute && endMinute === before.endMinute)
      return project;

    const sourceDate = continued ? addDays(date, -1) : date;
    const remaining = withoutStarts(source, [sourceDate]);
    const id = remaining ? allocateCueId(new Set(project.cues.map((cue) => cue.id))) : source.id;
    const changed = datedCue({ ...source, screenId }, id, date, startMinute, endMinute);
    const cues = project.cues.slice();
    cues.splice(cues.indexOf(source), 1, ...(remaining ? [remaining, changed] : [changed]));
    return validateProject({ ...project, cues });
  }

  function overlayDay(project, date, changes) {
    validateProject(project);
    dayNumber(date);
    if (!Array.isArray(changes) || !changes.length) throw new Error('Choose at least one screen to change.');
    const touched = new Set();
    const removedStarts = new Map();
    const additions = [];
    const ids = new Set(project.cues.map((cue) => cue.id));

    // Fragment bounds are measured from midnight of the edited day. A
    // preexisting overnight cue can start yesterday or finish tomorrow.
    function addFragment(template, from, to) {
      if (from >= to) return;
      additions.push(datedCue(template, allocateCueId(ids), date, from, to));
    }

    for (const change of changes) {
      if (!change || !project.screens.some((screen) => screen.id === change.screenId))
        throw new Error('Choose an existing screen.');
      if (touched.has(change.screenId)) throw new Error('Choose each screen only once per change.');
      touched.add(change.screenId);
      if (!project.solutions.some((solution) => solution.id === change.solutionId))
        throw new Error('Choose an existing solution for each screen.');
      const start = timeMinutes(change.start);
      if (start >= dayMinutes) throw new Error('Start time must be earlier than midnight.');
      const schedule = occurrences(project, date, change.screenId);
      const next = schedule.find((item) => item.startMinute > start);
      const end = change.end === '' ? (next?.startMinute ?? dayMinutes) : timeMinutes(change.end);
      if (end <= start) throw new Error('Set the end after the start on the selected day.');

      for (const item of schedule) {
        if (end <= item.startMinute || start >= item.endMinute) continue;
        const source = item.cue;
        const origin = item.continued ? addDays(date, -1) : date;
        if (!removedStarts.has(source.id)) removedStarts.set(source.id, new Set());
        removedStarts.get(source.id).add(origin);
        const bounds = occurrenceBounds(item);
        addFragment(source, bounds.startMinute, start);
        addFragment(source, end, bounds.endMinute);
      }
      addFragment({ screenId: change.screenId, solutionId: change.solutionId }, start, end);
    }

    const cues = [];
    for (const cue of project.cues) {
      const removed = removedStarts.get(cue.id);
      if (!removed) cues.push(cue);
      else {
        const remaining = withoutStarts(cue, removed);
        if (remaining) cues.push(remaining);
      }
    }
    return validateProject({ ...project, cues: [...cues, ...additions] });
  }

  function reconcileCatalog(project, liveSolutions) {
    validateProject(project);
    const liveById = keyedList(liveSolutions, 'solution');
    const used = new Set(project.cues.map((cue) => cue.solutionId));
    const remap = new Map(),
      solutions = new Map(),
      byName = new Map(),
      byAlias = new Map();
    const nameKey = (s) => JSON.stringify([s.name, s.width, s.height]);
    const uuidKey = (value) => (typeof value === 'string' ? value.toLowerCase().replace(/^viplex-/, '') : '');
    const fingerprint = (s) =>
      typeof s.source?.mediaFingerprint === 'string' ? s.source.mediaFingerprint.trim().toLowerCase() : '';
    function index(map, key, value) {
      if (!key) return;
      if (!map.has(key)) map.set(key, new Set());
      map.get(key).add(value);
    }
    for (const live of liveById.values()) {
      if (!live.source?.playlistUuid) continue;
      index(byName, nameKey(live), live);
      if (Array.isArray(live.source.aliases)) {
        for (const alias of live.source.aliases) index(byAlias, uuidKey(alias), live);
      }
    }
    for (const old of project.solutions) {
      let current = liveById.get(old.id);
      if (!current && old.source?.playlistUuid) {
        const aliasMatches = byAlias.get(uuidKey(old.source.playlistUuid));
        const hash = fingerprint(old);
        if (aliasMatches) {
          if (aliasMatches.size === 1) {
            const [candidate] = aliasMatches;
            if (!hash || !fingerprint(candidate) || fingerprint(candidate) === hash) current = candidate;
          }
        } else if (hash) {
          const candidates = [...(byName.get(nameKey(old)) || [])].filter((s) => fingerprint(s) === hash);
          if (candidates.length === 1) current = candidates[0];
        }
        // Imported projects predate fingerprints. A server-verified old UUID
        // can still relink them; a familiar display name alone cannot.
        if (!current && !used.has(old.id)) continue;
      }
      if (current) {
        const entry =
          ['localVideo', 'localImage'].includes(current.source?.kind) && typeof old.importPath === 'string'
            ? { ...current, importPath: old.importPath }
            : current;
        solutions.set(current.id, entry);
        if (old.id !== current.id) remap.set(old.id, current.id);
      } else {
        solutions.set(old.id, old.source?.playlistUuid ? { ...old, missing: true } : old);
      }
    }
    for (const live of liveById.values()) if (!solutions.has(live.id)) solutions.set(live.id, live);
    const cues = project.cues.map((cue) =>
      remap.has(cue.solutionId) ? { ...cue, solutionId: remap.get(cue.solutionId) } : cue,
    );
    return validateProject({ ...project, solutions: [...solutions.values()], cues });
  }

  return {
    blockMinutes,
    nextQuarterStart,
    suggestBlockStart,
    reorderScreens,
    validateProject,
    occurrences,
    occurrenceBounds,
    editOccurrence,
    cueHasOccurrences,
    addDays,
    localDate,
    weekday,
    timeMinutes,
    overlayDay,
    reconcileCatalog,
  };
});
