'use strict';

(() => {
  let gesture = null;
  let suppressClick = false;

  const clamp = (number, low, high) => Math.max(low, Math.min(high, number));
  const quarter = (minute) => Math.round(minute / M.blockMinutes) * M.blockMinutes;

  function minuteUnderPointer(lane, x, from, to) {
    const row = lane.getBoundingClientRect();
    return from + ((x - row.left) / row.width) * (to - from);
  }

  function quarterInRange(minute, low, high) {
    return clamp(quarter(minute), Math.ceil(low / M.blockMinutes) * M.blockMinutes,
      Math.floor(high / M.blockMinutes) * M.blockMinutes);
  }

  function proposedTimes(g, rawMinute) {
    const start = g.bounds.startMinute, end = g.bounds.endMinute;
    const delta = rawMinute - g.grabMinute;
    // A direct lane change and a drag back to the starting point retain imported minute values.
    const absolutePixels = Math.abs(delta) * g.lane.getBoundingClientRect().width / (g.to - g.from);
    const laneChangeJitter = g.mode === 'move' && g.target !== g.lane && absolutePixels < g.slop;
    if (laneChangeJitter || Math.abs(delta) < M.blockMinutes / 2) return g.bounds;
    if (g.mode === 'start') {
      const startMinute = quarterInRange(start + delta, Math.max(g.from, end - 1440), Math.min(g.to, end - 1));
      return {startMinute, endMinute: end};
    }
    if (g.mode === 'end') {
      const endMinute = quarterInRange(end + delta, Math.max(g.from, start + 1, 1), Math.min(g.to, start + 1440));
      return {startMinute: start, endMinute};
    }
    const length = end - start;
    // Ordinary blocks stay on the displayed date. An overnight airing may straddle either boundary.
    const overnight = start < 0 || end > 1440;
    const startMinute = quarterInRange(start + delta, overnight ? 1 - length : 0,
      overnight ? 1439 : 1440 - length);
    return {startMinute, endMinute: startMinute + length};
  }

  function displayMinute(minute) {
    if (minute === 1440) return '24:00';
    const time = Relay.clock(((minute % 1440) + 1440) % 1440);
    return minute < 0 ? `${time} (previous day)` : minute > 1440 ? `${time} (next day)` : time;
  }

  function createPreview(g) {
    g.button.classList.add('cue-edit-source');
    g.ghost = document.createElement('div');
    g.ghost.className = 'cue-edit-ghost';
    g.ghost.setAttribute('aria-hidden', 'true');
    g.ghost.textContent = g.name;
    g.caption = document.createElement('div');
    g.caption.className = 'cue-edit-caption';
    const title = document.createElement('strong');
    title.textContent = g.name;
    g.timeLabel = document.createElement('span');
    g.errorLabel = document.createElement('small');
    g.caption.append(title, g.timeLabel, g.errorLabel);
    g.caption.setAttribute('aria-hidden', 'true');
    document.body.append(g.caption);
  }

  function positionCaption(g) {
    const {width, height} = g.caption.getBoundingClientRect();
    g.caption.style.left = `${clamp(g.x + 14, 6, window.innerWidth - width - 6)}px`;
    const top = g.y + height + 20 > window.innerHeight ? g.y - height - 12 : g.y + 16;
    g.caption.style.top = `${clamp(top, 6, window.innerHeight - height - 6)}px`;
  }

  function showPlacement(g) {
    const underPointer = document.elementFromPoint(g.x, g.y)?.closest('[data-track]');
    const lane = underPointer && g.tracks.contains(underPointer)
      ? (g.mode === 'move' ? underPointer : g.lane) : null;
    if (g.target !== lane) {
      g.target?.classList.remove('cue-edit-target');
      g.target = lane;
      g.target?.classList.add('cue-edit-target');
    }
    if (!lane) {
      g.ghost.remove();
      g.proposal = null;
      g.timeLabel.textContent = 'Drop on a visible schedule lane';
      g.errorLabel.textContent = '';
      g.errorLabel.hidden = true;
      g.caption.classList.add('invalid');
      positionCaption(g);
      return;
    }
    const minute = minuteUnderPointer(lane, g.x, g.from, g.to);
    const {startMinute, endMinute} = proposedTimes(g, minute);
    const screenId = lane.dataset.track;
    const cached = g.proposal;
    if (!cached || cached.screenId !== screenId || cached.startMinute !== startMinute || cached.endMinute !== endMinute) {
      const edit = {cueId: g.cue.id, continued: g.continued, screenId, startMinute, endMinute};
      let candidate, error = '';
      try {
        candidate = M.editOccurrence(g.project, g.date, edit);
      } catch (failure) {
        error = failure.message;
      }
      g.proposal = {...edit, candidate, error};
      const left = clamp((startMinute - g.from) / (g.to - g.from), 0, 1);
      const right = clamp((endMinute - g.from) / (g.to - g.from), 0, 1);
      g.ghost.style.left = `${left * 100}%`;
      g.ghost.style.width = `${(right - left) * 100}%`;
      lane.append(g.ghost);
      g.timeLabel.textContent = `${getScreen(screenId).name} · ${displayMinute(startMinute)}–${displayMinute(endMinute)}`;
      g.errorLabel.textContent = error;
      g.errorLabel.hidden = !error;
      g.ghost.classList.toggle('invalid', Boolean(error));
      g.caption.classList.toggle('invalid', Boolean(error));
    }
    positionCaption(g);
  }

  function edgeSpeed(value, low, high) {
    const edge = 24;
    if (value < low + edge) return -Math.ceil((low + edge - value) / 3);
    if (value > high - edge) return Math.ceil((value - high + edge) / 3);
    return 0;
  }

  function scrollWhileNearEdge(g) {
    if (gesture !== g || !g.dragged) return;
    g.frame = 0;
    const box = g.tracks.getBoundingClientRect();
    if (g.x < box.left || g.x > box.right || g.y < box.top || g.y > box.bottom) return;
    const dx = edgeSpeed(g.x, box.left, box.right);
    const dy = g.mode === 'move' ? edgeSpeed(g.y, box.top + g.headerHeight, box.bottom) : 0;
    const oldLeft = g.tracks.scrollLeft, oldTop = g.tracks.scrollTop;
    if (dx) g.tracks.scrollLeft += clamp(dx, -16, 16);
    if (dy) g.tracks.scrollTop += clamp(dy, -16, 16);
    if (oldLeft === g.tracks.scrollLeft && oldTop === g.tracks.scrollTop) return;
    showPlacement(g);
    g.frame = requestAnimationFrame(() => scrollWhileNearEdge(g));
  }

  function endGesture(g, stopClick) {
    gesture = null;
    if (g.frame) cancelAnimationFrame(g.frame);
    g.ghost?.remove();
    g.caption?.remove();
    g.target?.classList.remove('cue-edit-target');
    g.button.classList.remove('cue-edit-source');
    if (g.button.hasPointerCapture(g.id)) g.button.releasePointerCapture(g.id);
    if (stopClick) suppressClick = true;
    // Let an ordinary click finish opening its editor before a deferred midnight rollover.
    setTimeout(updateBrowserClock, 0);
  }

  function cancel() {
    if (gesture) endGesture(gesture, true);
  }
  window.TimelineEdit = { get active() { return Boolean(gesture); }, cancel };

  function gestureMode(button, event) {
    const handle = event.target.closest('[data-resize]');
    if (handle) return handle.dataset.resize;
    // The button itself receives hits on its border, outside its absolute-positioned handles.
    const rect = button.getBoundingClientRect();
    const edge = Math.min(3, rect.width / 4);
    if (event.clientX - rect.left <= edge && button.querySelector('[data-resize="start"]')) return 'start';
    if (rect.right - event.clientX <= edge && button.querySelector('[data-resize="end"]')) return 'end';
    return 'move';
  }

  document.addEventListener('pointerdown', (e) => {
    if (gesture || !e.isPrimary || e.button !== 0) return;
    suppressClick = false;
    const button = e.target.closest('.cue[data-cue]');
    if (!button) return;
    const lane = button.closest('[data-track]'), tracks = button.closest('#tracks');
    if (!lane || !tracks || writing || drawing || window.LaneReorder?.active) return;
    const continued = button.dataset.continued === 'true';
    const occurrence = M.occurrences(Relay.project, Relay.date, lane.dataset.track)
      .find((o) => o.cue.id === button.dataset.cue && o.continued === continued);
    if (!occurrence) return;
    const [from, to] = timeRange();
    const mode = gestureMode(button, e);
    gesture = {
      id: e.pointerId, button, lane, tracks, continued, mode, from, to,
      cue: occurrence.cue, bounds: M.occurrenceBounds(occurrence), project: Relay.project, date: Relay.date,
      name: getSolution(occurrence.cue.solutionId).name,
      headerHeight: tracks.querySelector('.timeline-axis').getBoundingClientRect().height,
      startX: e.clientX, startY: e.clientY, grabMinute: minuteUnderPointer(lane, e.clientX, from, to),
      slop: e.pointerType === 'touch' ? 8 : 4, dragged: false,
    };
    button.setPointerCapture(e.pointerId);
  });

  function updateGesture(g, e) {
    g.x = e.clientX;
    g.y = e.clientY;
    if (!g.dragged) {
      if (Math.hypot(g.x - g.startX, g.y - g.startY) < g.slop) return;
      g.dragged = true;
      createPreview(g);
    }
    showPlacement(g);
  }

  document.addEventListener('pointermove', (e) => {
    const g = gesture;
    if (g?.id !== e.pointerId) return;
    updateGesture(g, e);
    if (g.dragged && !g.frame) g.frame = requestAnimationFrame(() => scrollWhileNearEdge(g));
  });

  document.addEventListener('pointerup', async (e) => {
    const g = gesture;
    if (g?.id !== e.pointerId) return;
    updateGesture(g, e);
    endGesture(g, g.dragged);
    if (!g.dragged) return;
    if (!g.proposal) return Relay.notice('Block edit canceled.');
    if (g.proposal.error) return Relay.notice(g.proposal.error);
    if (g.project !== Relay.project || g.date !== Relay.date) return Relay.notice('The board changed. Try dragging again.');
    if (g.proposal.candidate === g.project) return;
    try {
      const verb = g.mode === 'move' ? 'Moved' : 'Resized';
      await Relay.commit(g.proposal.candidate, `${verb} ${g.name} · ${g.timeLabel.textContent}`);
    } catch (error) {
      Relay.notice(error.message);
    }
  });

  // A browser emits a click after pointerup even when the pointer was dragged.
  document.addEventListener('click', (e) => {
    if (!suppressClick || e.detail === 0) return;
    suppressClick = false;
    e.preventDefault();
    e.stopImmediatePropagation();
  }, true);
  for (const event of ['pointercancel', 'lostpointercapture']) {
    document.addEventListener(event, (e) => { if (gesture?.id === e.pointerId) cancel(); });
  }
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && gesture) { e.preventDefault(); cancel(); }
  });
  document.addEventListener('visibilitychange', () => { if (document.hidden) cancel(); });
  window.addEventListener('blur', cancel);
})();
