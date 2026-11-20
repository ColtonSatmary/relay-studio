'use strict';

(() => {
  let drag = null;
  let suppressClick = false;
  const rowSelector = '[data-lane-id]';
  const rowsOf = list => Array.from(list.querySelectorAll(':scope > [data-lane-id]'));
  const scrollBox = list => list.closest('#tracks, .nav-area');

  function showMarker(g, row, after = false) {
    if (row === g.target && after === g.after) return;
    g.target?.classList.remove('lane-insert-before', 'lane-insert-after');
    g.target = row;
    g.after = after;
    row?.classList.add(after ? 'lane-insert-after' : 'lane-insert-before');
  }

  function placement(g) {
    const box = g.scroller.getBoundingClientRect();
    const listBounds = g.list.getBoundingClientRect();
    const bottom = Math.min(box.top + g.scroller.clientHeight, g.ruler ? Infinity : listBounds.bottom);
    const listTop = Math.max(box.top, listBounds.top);
    if (g.x < Math.max(box.left, listBounds.left) || g.x >= Math.min(box.left + g.scroller.clientWidth, listBounds.right) ||
        g.y < listTop || g.y >= bottom) {
      showMarker(g, null);
      return 0;
    }
    const top = g.ruler ? g.ruler.getBoundingClientRect().bottom : listTop;
    const y = Math.max(top, g.y);
    const rows = g.rows;
    let index = rows.findIndex(row => y < row.getBoundingClientRect().bottom);
    if (index < 0) index = rows.length - 1;
    const row = rows[index];
    const bounds = row.getBoundingClientRect();
    const distance = y - (bounds.top + bounds.height / 2);
    // Dropping on the center of a neighboring name exchanges their positions in either direction.
    const after = Math.abs(distance) < bounds.height * 0.1 ? index > g.from : distance > 0;
    const slot = index + Number(after);
    const same = slot === g.from || slot === g.from + 1;
    showMarker(g, same ? null : row, after);

    const edge = 28;
    if (g.y < top + edge) return -Math.min(14, Math.ceil((top + edge - g.y) / 3));
    if (g.y > bottom - edge) return Math.min(14, Math.ceil((g.y - bottom + edge) / 3));
    return 0;
  }

  function preview(g) {
    const speed = placement(g);
    if (speed && !g.frame) {
      g.frame = requestAnimationFrame(() => {
        g.frame = 0;
        if (g !== drag) return;
        const before = g.scroller.scrollTop;
        g.scroller.scrollTop += placement(g);
        if (g.scroller.scrollTop !== before) preview(g);
      });
    }
  }

  function update(g, e) {
    g.x = e.clientX;
    g.y = e.clientY;
    if (!g.moved) {
      if (Math.hypot(g.x - g.startX, g.y - g.startY) < g.threshold) return;
      g.moved = true;
      g.row.classList.add('lane-reorder-source');
    }
    preview(g);
  }

  function finish(g, preventClick) {
    drag = null;
    suppressClick = preventClick;
    if (g.frame) cancelAnimationFrame(g.frame);
    showMarker(g, null);
    g.row.classList.remove('lane-reorder-source');
    if (g.button.hasPointerCapture(g.pointerId)) g.button.releasePointerCapture(g.pointerId);
    setTimeout(updateBrowserClock, 0);
  }

  function cancel() {
    if (drag) finish(drag, true);
  }

  window.LaneReorder = {get active() { return Boolean(drag); }, cancel};

  function focusGrip(surface, id) {
    const list = document.querySelector(`[data-lane-list="${surface}"]`);
    const row = list && rowsOf(list).find(el => el.dataset.laneId === id);
    if (!row) return;
    row.querySelector('[data-lane-grip]')?.focus({preventScroll: true});
    const scroller = scrollBox(list);
    const bounds = row.getBoundingClientRect();
    const box = scroller.getBoundingClientRect();
    const top = list.querySelector('.timeline-axis')?.getBoundingClientRect().bottom ?? box.top;
    const bottom = box.top + scroller.clientHeight;
    if (bounds.top < top) scroller.scrollTop += bounds.top - top;
    else if (bounds.bottom > bottom) scroller.scrollTop += bounds.bottom - bottom;
  }

  async function reorder(project, list, ids, moved, anchor, after, keyboard) {
    try {
      const rows = rowsOf(list);
      if (project !== Relay.project || !list.isConnected || rows.length !== ids.length ||
          ids.some((id, i) => rows[i].dataset.laneId !== id)) throw new Error('The schedule list changed. Try reordering again.');
      const candidate = M.reorderScreens(project, ids, moved, anchor, after);
      if (candidate === project) return;
      const name = getScreen(moved).name, neighbor = getScreen(anchor).name;
      await Relay.commit(candidate, `Moved ${name} ${after ? 'below' : 'above'} ${neighbor}.`);
      if (keyboard && document.activeElement === document.body) focusGrip(list.dataset.laneList, moved);
    } catch (error) {
      Relay.notice(error.message);
    }
  }

  document.addEventListener('pointerdown', (e) => {
    if (!e.isPrimary || e.button !== 0 || drag) return;
    suppressClick = false;
    const label = e.target.closest('[data-lane-label]');
    if (!label || writing || drawing || window.TimelineEdit?.active) return;
    const row = label.closest(rowSelector);
    const list = row?.closest('[data-lane-list]');
    if (!list) return;
    const rows = rowsOf(list);
    if (rows.length < 2) return;
    // Capture on the actual button so a simple click on a name still filters the board.
    const button = e.target.closest('button') || label;
    drag = {
      button, row, list, rows, scroller: scrollBox(list), ruler: list.querySelector('.timeline-axis'),
      project: Relay.project, ids: rows.map(item => item.dataset.laneId), from: rows.indexOf(row),
      pointerId: e.pointerId, startX: e.clientX, startY: e.clientY, threshold: e.pointerType === 'touch' ? 8 : 4,
    };
    button.setPointerCapture(e.pointerId);
  });

  document.addEventListener('pointermove', (e) => {
    if (drag?.pointerId === e.pointerId) update(drag, e);
  });
  document.addEventListener('pointerup', (e) => {
    const g = drag;
    if (g?.pointerId !== e.pointerId) return;
    update(g, e);
    const target = g.target, after = g.after;
    finish(g, Boolean(g.moved));
    if (target) reorder(g.project, g.list, g.ids, g.row.dataset.laneId, target.dataset.laneId, after, false);
  });

  document.addEventListener('click', (e) => {
    if (!suppressClick || e.detail === 0) return;
    suppressClick = false;
    e.preventDefault();
    e.stopImmediatePropagation();
  }, true);
  document.addEventListener('keydown', (e) => {
    if (drag && e.key === 'Escape') {
      e.preventDefault();
      cancel();
      return;
    }
    if (e.key !== 'ArrowUp' && e.key !== 'ArrowDown') return;
    const grip = e.target.closest('[data-lane-grip]');
    if (!grip || e.altKey || e.ctrlKey || e.metaKey || e.shiftKey) return;
    e.preventDefault();
    if (drag || writing || drawing || window.TimelineEdit?.active) return;
    const id = grip.closest(rowSelector).dataset.laneId;
    const list = grip.closest('[data-lane-list]');
    const ids = rowsOf(list).map(row => row.dataset.laneId);
    const index = ids.indexOf(id);
    const down = e.key === 'ArrowDown';
    const neighbor = ids[index + (down ? 1 : -1)];
    if (neighbor) reorder(Relay.project, list, ids, id, neighbor, down, true);
  });
  for (const name of ['pointercancel', 'lostpointercapture']) {
    document.addEventListener(name, (e) => { if (drag?.pointerId === e.pointerId) cancel(); });
  }
  document.addEventListener('visibilitychange', () => { if (document.hidden) cancel(); });
  window.addEventListener('blur', cancel);
})();
