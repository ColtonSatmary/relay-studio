'use strict';

function canUsbPlaybackSolution(solution) {
  return Boolean(solution && !solution.missing &&
    (solution.source?.playlistUuid || ['localVideo', 'localImage'].includes(solution.source?.kind)));
}

function usbProgramOptions() {
  const scheduled = new Set(project.cues.filter(M.cueHasOccurrences).map((c) => c.screenId));
  return project.screens
    .filter((screen) => scheduled.has(screen.id))
    .map((screen) => `<option value="${esc(screen.id)}">${esc(screen.name)}</option>`)
    .join('');
}

function openUsbPlayback(solutionId = '') {
  const solution = solutionId ? getSolution(solutionId) : null;
  if (solutionId && !canUsbPlaybackSolution(solution)) {
    openDialog({
      title: 'USB playback unavailable',
      body: '<p class="dialog-copy">This solution has no available media to export. Import its media or refresh the ViPlex library first.</p>',
    });
    return;
  }
  const programs = solution ? '' : usbProgramOptions();
  if (!solution && !programs) {
    openDialog({
      title: 'USB playback',
      body: '<p class="dialog-copy">Add a block to a schedule before exporting it. To play one solution, use its USB button in Solution library.</p>',
    });
    return;
  }
  let drives = [],
    busy = false,
    finding = false;
  const form = openDialog({
    title: 'USB playback',
    body: `<div class="usb-form">
      ${solution
        ? `<div class="field"><span>Solution</span><strong>${esc(solution.name)}</strong></div>`
        : `<label class="field"><span>Schedule</span><select name="program" required>${programs}</select></label>`}
      <fieldset class="usb-modes"><legend>Play mode</legend>
        <label><input type="radio" name="playMode" value="plug"> Plug and play</label>
        <label><input type="radio" name="playMode" value="copy" checked> Copy and play</label>
      </fieldset>
      <div class="field"><span>When the player already has this name</span>
        <label class="check-row"><input type="checkbox" name="overwriteExisting" checked aria-describedby="usb-duplicate-help"><span>Overwrite existing</span></label>
        <span class="field-help" id="usb-duplicate-help">Uncheck to keep both solutions or schedules on the player.</span></div>
      <div class="field"><label for="usb-destination">Destination</label><div class="usb-drive-row">
        <select id="usb-destination" name="destination" required><option value="">Finding USB drives…</option></select>
        <button type="button" class="btn btn-secondary" data-refresh>Refresh drives</button></div>
        <span class="field-help" data-drive-info></span></div>
      <div class="field"><label for="usb-player-password">Player password</label>
        <label class="check-row usb-reuse" hidden><input type="checkbox" name="reusePassword"><span data-reuse-label></span></label>
        <input id="usb-player-password" type="text" spellcheck="false" autocapitalize="none" name="playerPassword" autocomplete="off" placeholder="Enter player password" required>
        <span class="field-help">The player reads this password from the exported USB package.</span></div>
      <div class="usb-erase" data-erase-panel hidden><label class="check-row"><input type="checkbox" name="clearDrive" checked><span data-erase-label>Delete all files from this USB stick before export</span></label><p class="field-help" data-erase-help></p></div>
      <p class="field-help" data-usb-progress role="status"></p>
    </div>`,
    submitLabel: 'Export USB playback',
    async onSubmit() {
      const target = selectedDrive(),
        folder = form.elements.destination.value === 'folder';
      if (!folder && !target) throw new Error('Select a connected USB drive.');
      const clear = Boolean(target && form.elements.clearDrive.checked);
      if (clear && form.elements.clearDrive.dataset.volume !== target.id)
        throw new Error('Choose the erase checkbox again for this drive.');
      const reuse = Boolean(target?.hasPlayerPassword && form.elements.reusePassword.checked);
      if (!reuse && !form.elements.playerPassword.value) throw new Error('Enter the player password.');
      const payload = {
        project: { ...project, cues: project.cues.filter(M.cueHasOccurrences) },
        programType: solution ? 'solution' : 'schedule',
        programId: solution ? solution.id : form.elements.program.value,
        playMode: form.elements.playMode.value,
        duplicatePolicy: form.elements.playMode.value === 'copy' && form.elements.overwriteExisting.checked ? 'replace' : 'keep',
        destination: folder ? 'folder' : 'drive',
        clearDrive: clear,
        reuseDrivePassword: reuse,
      };
      if (!reuse) payload.playerPassword = form.elements.playerPassword.value;
      if (target) {
        payload.driveRoot = target.root;
        payload.volumeId = target.id;
      }
      if (clear) payload.eraseVolumeId = target.id;
      busy = true;
      status.textContent = 'Building and verifying the playback package…';
      const controls = [...form.querySelectorAll('button,input,select')];
      controls.forEach((c) => (c.disabled = true));
      const preventClose = (e) => e.preventDefault();
      dialog.addEventListener('cancel', preventClose);
      try {
        const session = await fetch('/api/session', { cache: 'no-store' });
        if (!session.ok) throw new Error('Open the Relay Studio launcher and try again.');
        const { exportToken } = await session.json();
        const response = await fetch('/api/export-usb', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'X-Studio-Token': exportToken },
          body: JSON.stringify(payload),
        });
        const result = await response.json().catch(() => ({}));
        if (!response.ok) throw new Error(result.error || 'USB export failed.');
        form.elements.playerPassword.value = '';
        const mode = payload.playMode === 'copy' ? 'Copy and play' : 'Plug and play';
        const policy = payload.duplicatePolicy === 'keep' ? 'Keep both' : 'Overwrite existing';
        const finish = folder
          ? 'Copy the <strong>nova</strong> folder to the root of the USB stick.'
          : 'Eject the drive before unplugging it.';
        const readyForm = openDialog({
          title: folder ? 'USB playback package created' : 'USB playback ready',
          body: `<p class="dialog-copy"><strong>${esc(result.name)}</strong> · ${mode}${payload.playMode === 'copy' ? ' · ' + policy : ''}</p><p class="success-path">${esc(result.path)}</p><p class="field-help">${finish}</p>${result.cleared ? '<p class="field-help">Previous user files on the selected stick were cleared.</p>' : ''}${result.backupPath ? `<p class="field-help">Previous package files that were replaced are backed up in ${esc(result.backupPath)}.</p>` : ''}${result.warning ? `<p class="form-error">${esc(result.warning)}</p>` : ''}`,
          submitLabel: folder ? undefined : 'Eject drive and close',
          async onSubmit(receiptForm) {
            if (folder) return;
            const buttons = [...receiptForm.querySelectorAll('button')];
            const ejectButton = receiptForm.querySelector('[type=submit]');
            const blockClose = (e) => e.preventDefault();
            buttons.forEach((button) => (button.disabled = true));
            ejectButton.textContent = `Ejecting ${target.root}…`;
            dialog.addEventListener('cancel', blockClose);
            try {
              const sessionResponse = await fetch('/api/session', { cache: 'no-store' });
              if (!sessionResponse.ok) throw new Error('Reopen the Studio launcher and try ejecting again.');
              const { exportToken } = await sessionResponse.json();
              const ejectResponse = await fetch('/api/eject-usb', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'X-Studio-Token': exportToken },
                body: JSON.stringify({ driveRoot: target.root, volumeId: target.id }),
              });
              const ejectResult = await ejectResponse.json().catch(() => ({}));
              if (!ejectResponse.ok || ejectResult.ejected !== true)
                throw new Error(ejectResult.error || 'Windows could not confirm that the drive was ejected. Try again or eject it using Windows.');
              notice(`${target.root} ejected. You can unplug the drive.`);
            } finally {
              dialog.removeEventListener('cancel', blockClose);
              buttons.forEach((button) => (button.disabled = false));
              ejectButton.textContent = 'Eject drive and close';
            }
          },
        });
        if (!folder) readyForm.querySelector('.modal-foot [data-close]').textContent = 'Close';
        return false;
      } finally {
        delete payload.playerPassword;
        busy = false;
        dialog.removeEventListener('cancel', preventClose);
        controls.forEach((c) => (c.disabled = false));
        const clearBox = form.elements.clearDrive;
        clearBox.checked = false;
        delete clearBox.dataset.volume;
        status.textContent = '';
        update();
      }
    },
  });
  const dialog = $('#dialog'),
    status = form.querySelector('[data-usb-progress]'),
    dest = form.elements.destination;
  const submit = form.querySelector('[type=submit]'),
    clearBox = form.elements.clearDrive,
    reuseBox = form.elements.reusePassword;
  let passwordReset = 0;
  function selectedDrive() {
    return drives.find((d) => d.id === dest.value);
  }
  function resetDriveOptions() {
    const target = selectedDrive();
    const reset = ++passwordReset;
    clearBox.checked = Boolean(target);
    if (target) clearBox.dataset.volume = target.id;
    else delete clearBox.dataset.volume;
    reuseBox.checked = false;
    form.elements.playerPassword.value = '';
    update();
    void applyDefaultPlayerPassword(form.elements.playerPassword).then((savedPassword) => {
      if (!form.isConnected || reset !== passwordReset || busy) return;
      if (!savedPassword && !form.elements.playerPassword.value) reuseBox.checked = Boolean(target?.hasPlayerPassword);
      update();
    }).catch(() => {
      if (!form.isConnected || reset !== passwordReset || busy) return;
      if (!form.elements.playerPassword.value) status.textContent = 'The saved default password could not be loaded. Enter the player password or use the one on this USB.';
      update();
    });
  }
  function update() {
    const target = selectedDrive(),
      reuse = target?.hasPlayerPassword,
      clear = !!target && clearBox.checked;
    const folder = dest.value === 'folder';
    form.querySelector('[data-erase-panel]').hidden = !target;
    form.querySelector('[data-erase-label]').textContent =
      `Delete all files from ${target?.root || 'this USB stick'} before export`;
    form.querySelector('[data-erase-help]').textContent = clear
      ? `All user files on ${target.root}${target.label ? ' (' + target.label + ')' : ''} will be permanently deleted when you export.`
      : 'Leave unchecked to keep the other files on this stick.';
    form.querySelector('[data-erase-panel]').classList.toggle('armed', clear);
    clearBox.disabled = !target || finding || busy;
    const info = form.querySelector('[data-drive-info]');
    info.textContent = target
      ? `${readableSize(target.freeBytes)} free of ${readableSize(target.totalBytes)}`
      : folder
        ? 'Creates a USB-ready folder in Documents / Relay Studio Exports.'
        : '';
    form.querySelector('.usb-reuse').hidden = !reuse;
    form.querySelector('[data-reuse-label]').textContent = target
      ? `Use the player password already on ${target.root}`
      : '';
    reuseBox.disabled = !reuse || busy;
    form.elements.playerPassword.disabled = !!(reuse && reuseBox.checked) || busy;
    form.elements.playerPassword.required = !form.elements.playerPassword.disabled;
    form.elements.playerPassword.placeholder =
      reuse && reuseBox.checked ? 'Using password on selected USB' : 'Enter player password';
    form.elements.overwriteExisting.disabled = form.elements.playMode.value === 'plug' || busy;
    submit.textContent = clear
      ? `Erase ${target.root} and export`
      : folder
        ? 'Create playback folder'
        : 'Export to USB';
    submit.classList.toggle('usb-destructive', clear);
    submit.disabled = busy || finding || (!target && !folder);
  }
  async function refresh() {
    if (finding || busy) return;
    const last = dest.value;
    finding = true;
    clearBox.checked = false;
    update();
    dest.disabled = true;
    form.querySelector('[data-refresh]').disabled = true;
    try {
      const response = await fetch('/api/usb-drives', { cache: 'no-store' });
      if (!response.ok) throw new Error('USB drives could not be read. Reopen the launcher and refresh.');
      const data = await response.json();
      if (!Array.isArray(data.drives)) throw new Error('Refresh to check connected USB drives.');
      drives = data.drives;
      status.textContent = drives.length
        ? ''
        : 'No removable USB drive detected. Connect the stick and refresh, or create a local playback folder.';
    } catch (error) {
      drives = [];
      status.textContent = error.message;
    }
    dest.innerHTML =
      drives
        .map(
          (d) => `<option value="${esc(d.id)}">${esc(d.root)}${d.label ? ' — ' + esc(d.label) : ''}</option>`,
        )
        .join('') + '<option value="folder">Create a local playback folder</option>';
    const preferred = drives.find((d) => d.root.toUpperCase() === 'E:\\') || drives[0];
    dest.value = last === 'folder' || drives.some((d) => d.id === last) ? last : preferred?.id || 'folder';
    finding = false;
    dest.disabled = false;
    form.querySelector('[data-refresh]').disabled = false;
    resetDriveOptions();
  }
  form.querySelector('[data-refresh]').onclick = refresh;
  dest.onchange = resetDriveOptions;
  form.addEventListener('change', (e) => {
    if (e.target === clearBox) {
      if (clearBox.checked && selectedDrive()) {
        clearBox.dataset.volume = selectedDrive().id;
      } else delete clearBox.dataset.volume;
    }
    if (e.target === reuseBox && reuseBox.checked) form.elements.playerPassword.value = '';
    update();
    if (e.target === reuseBox && !reuseBox.checked) {
      void applyDefaultPlayerPassword(form.elements.playerPassword).catch(() => {});
    }
  });
  void refresh();
}
