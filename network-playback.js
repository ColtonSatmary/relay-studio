'use strict';

function openNetworkPlayback(solutionId = '') {
  if (typeof isAutomaticPlayerReconnectBusy === 'function' && isAutomaticPlayerReconnectBusy()) {
    notice('Relay is reconnecting saved players. Wait for the connection checks to finish before uploading.'); return;
  }
  if (typeof isBulkBoardControlBusy === 'function' && isBulkBoardControlBusy()) {
    notice('Wait for the board controls to finish before uploading.'); return;
  }
  const solution = solutionId ? getSolution(solutionId) : null;
  if (solutionId && !canUsbPlaybackSolution(solution)) {
    openDialog({ title: 'Network playback unavailable', body: '<p class="dialog-copy">This solution has no available media to send. Import its media or refresh the ViPlex library first.</p>' });
    return;
  }
  const programs = solution ? '' : usbProgramOptions();
  if (!solution && !programs) {
    openDialog({ title: 'Network playback', body: '<p class="dialog-copy">Add a block to a schedule before sending it. To send one solution, use its Send button in Solution library.</p>' });
    return;
  }
  let players = [], connection = null, busy = '', pendingJobId = '', available = true;
  const lifetime = new AbortController();
  const form = openDialog({
    title: 'Network playback',
    body: `<div class="network-form">
      ${solution
        ? `<div class="field"><span>Solution</span><strong>${esc(solution.name)}</strong></div>`
        : `<label class="field"><span>Schedule</span><select name="program" required>${programs}</select></label>`}
      <label class="field"><span>Player</span><select name="player" disabled><option value="">Enter an IP address manually</option></select><span class="field-help" data-network-list-help>Loading remembered players…</span></label>
      <div class="form-grid">
        <label class="field"><span>Player IP address</span><input name="ip" type="text" inputmode="decimal" autocomplete="off" placeholder="192.168.1.100" required spellcheck="false"></label>
        <label class="field"><span>Player password</span><input name="playerPassword" type="text" spellcheck="false" autocapitalize="none" autocomplete="off" placeholder="Enter player password" required></label>
      </div>
      <div class="network-check-row"><button type="button" class="btn btn-secondary" data-network-check>${icon('network', 16)} Check connection</button><span class="field-help">The computer must be connected to the player’s network.</span></div>
      <div class="network-device" data-network-device hidden></div>
      <p class="field-help network-effect">Upload and play starts this content on the selected player, replacing its active playback.</p>
      <div class="network-progress" data-network-progress hidden><progress max="100" aria-label="Network upload progress"></progress><p class="field-help" role="status" data-network-status></p></div>
    </div>`,
    submitLabel: 'Upload and play',
    extra: '<button type="button" class="btn btn-secondary" data-network-multiple>Send to multiple boards</button>',
  });
  const dialog = $('#dialog'), submit = form.querySelector('[type=submit]');
  const errorBox = form.querySelector(':scope > .form-error');
  const playerSelect = form.elements.player, ipInput = form.elements.ip, passwordInput = form.elements.playerPassword;
  const checkButton = form.querySelector('[data-network-check]');
  const devicePanel = form.querySelector('[data-network-device]');
  const progressPanel = form.querySelector('[data-network-progress]');
  const progress = progressPanel.querySelector('progress'), status = form.querySelector('[data-network-status]');
  const listHelp = form.querySelector('[data-network-list-help]');
  const closeButtons = [...form.querySelectorAll('[data-close]')];
  const multipleButton = form.querySelector('[data-network-multiple]');
  multipleButton.onclick = () => {
    if (busy || pendingJobId) return;
    openNetworkBatch([], { programType: solution ? 'solution' : 'schedule', programId: currentProgram()?.id });
  };

  function currentProgram() { return solution || getScreen(form.elements.program.value); }
  function active() { return !lifetime.signal.aborted && dialog.open && dialog.contains(form); }
  function matchingSize() {
    const program = currentProgram(), device = connection?.device;
    return Boolean(device && program && Number(device.width) > 0 && Number(device.height) > 0 &&
      Number(program.width) === Number(device.width) && Number(program.height) === Number(device.height));
  }
  function setError(message) { errorBox.textContent = message; errorBox.hidden = !message; }
  function update() {
    const locked = Boolean(busy || pendingJobId);
    multipleButton.disabled = locked;
    for (const input of form.querySelectorAll('input,select')) input.disabled = locked;
    checkButton.disabled = locked || !available || !ipInput.value.trim() || !passwordInput.value;
    checkButton.textContent = busy === 'check' ? 'Checking…' : 'Check connection';
    submit.disabled = Boolean(busy) || (!pendingJobId && (!available || !connection || !passwordInput.value));
    submit.textContent = busy === 'publish' ? 'Uploading…' : pendingJobId ? 'Check upload status' : 'Upload and play';
    closeButtons.forEach((button) => (button.disabled = busy === 'publish'));
    devicePanel.hidden = !connection;
    if (connection) {
      const device = connection.device, program = currentProgram();
      const size = Number(device.width) > 0 && Number(device.height) > 0 ? `${device.width} × ${device.height}` : 'Not reported';
      devicePanel.innerHTML = `<div class="network-device-heading">${icon('check', 17)}<strong>${esc(device.name || device.sn)}</strong><span>Connected</span></div>
        <p>${esc(device.model || 'Player')} · ${esc(device.ip)}</p><p>Serial ${esc(device.sn)}</p>
        <p>Content canvas: ${esc(program?.width)} × ${esc(program?.height)} · Player output: ${esc(size)}</p>
        ${matchingSize() ? '' : `<p class="network-mismatch" role="note">${Number(device.width) > 0 && Number(device.height) > 0
          ? 'Different sizes can be expected for a mosaic tile. Relay sends the original canvas and does not change the player’s mosaic configuration.'
          : 'The player did not report its output size. Relay will send the original content canvas.'}</p>`}`;
    }
  }
  function clearConnection() {
    connection = null;
    setError('');
    progressPanel.hidden = true;
    update();
  }
  function fillDefaultPassword() {
    return applyDefaultPlayerPassword(passwordInput).then((password) => {
      if (active()) update();
      return password;
    }).catch(() => {
      if (active() && !passwordInput.value) setError('The saved default password could not be loaded. Enter the player password here.');
    });
  }
  function cleanup() {
    if (dialog.open && dialog.contains(form)) return;
    lifetime.abort();
    passwordInput.value = '';
    dialog.removeEventListener('close', cleanup);
    dialog.removeEventListener('cancel', preventClose);
  }
  function preventClose(event) { if (busy === 'publish') event.preventDefault(); }
  dialog.addEventListener('close', cleanup);
  dialog.addEventListener('cancel', preventClose);

  async function jsonRequest(url, options = {}) {
    const request = new AbortController();
    const abort = () => request.abort();
    lifetime.signal.addEventListener('abort', abort, { once: true });
    const timer = setTimeout(abort, 20000);
    try {
      const response = await fetch(url, { ...options, cache: 'no-store', signal: request.signal });
      const body = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(body.error || 'Relay could not complete the network request. Reopen the launcher and try again.');
      return body;
    } finally {
      clearTimeout(timer);
      lifetime.signal.removeEventListener('abort', abort);
    }
  }
  async function post(url, payload) {
    try {
      const session = await jsonRequest('/api/session');
      return await jsonRequest(url, {
        method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Studio-Token': session.exportToken },
        body: JSON.stringify(payload),
      });
    } finally { delete payload.playerPassword; }
  }
  async function waitJob(jobId, timeoutMs) {
    if (typeof jobId !== 'string' || !jobId) throw new Error('Relay did not return an upload status. Reopen the launcher and try again.');
    const deadline = Date.now() + timeoutMs;
    let failures = 0;
    while (active() && Date.now() < deadline) {
      let job;
      try { job = await jsonRequest(`/api/network/jobs/${encodeURIComponent(jobId)}`); failures = 0; }
      catch (error) {
        if (!active()) throw error;
        if (++failures >= 3) throw new Error(busy === 'check'
          ? 'Connection status is unavailable. Check the player’s network and try again.'
          : 'Upload status is unavailable. Use Check upload status to reconnect before starting another transfer.');
        status.textContent = busy === 'check' ? 'Reconnecting to connection status…' : 'Reconnecting to upload status…';
      }
      if (job) {
        const amount = Number(job.progress);
        if (job.progress !== null && job.progress !== undefined && Number.isFinite(amount)) progress.value = Math.max(0, Math.min(100, amount));
        else progress.removeAttribute('value');
        status.textContent = job.message || job.stage || (busy === 'check' ? 'Checking player…' : 'Preparing upload…');
        if (job.status === 'complete') return job;
        if (job.status === 'failed') {
          const failure = new Error(job.error || job.message || 'The player could not complete this request.');
          failure.jobFailed = true;
          throw failure;
        }
      }
      await new Promise((resolve) => setTimeout(resolve, 700));
    }
    throw new Error(busy === 'check' ? 'The connection check timed out. Check the player IP and network, then try again.' : 'The upload is taking longer than expected. Use Check upload status before starting another transfer.');
  }

  checkButton.onclick = async () => {
    if (busy || pendingJobId || !available) return;
    const ip = ipInput.value.trim();
    if (!/^(?:\d{1,3}\.){3}\d{1,3}$/.test(ip) || ip.split('.').some((part) => Number(part) > 255)) {
      setError('Enter the player’s IPv4 address, for example 192.168.1.100.');
      ipInput.focus();
      return;
    }
    if (!passwordInput.value) { setError('Enter the player password.'); passwordInput.focus(); return; }
    const remembered = players.find((player) => player.id === playerSelect.value && player.ip === ip);
    const expectedSn = remembered?.sn;
    busy = 'check'; connection = null; setError('');
    progressPanel.hidden = false; progress.removeAttribute('value'); status.textContent = 'Checking player…'; update();
    try {
      const started = await post('/api/network/check', { ip, playerPassword: passwordInput.value, ...(expectedSn ? { expectedSn } : {}) });
      const checked = await waitJob(started.jobId, 90000);
      if (!active()) return;
      if (!checked.connectionId || !checked.device?.sn || checked.device.ip !== ip || (expectedSn && checked.device.sn !== expectedSn))
        throw new Error('The player identity could not be confirmed. Check its address and try again.');
      connection = { id: checked.connectionId, device: checked.device };
      if (remembered?.name) connection.device.name = remembered.name;
      void refreshPlayerManagement().catch(() => {});
      progressPanel.hidden = true;
    } catch (error) {
      if (active()) { setError(error.name === 'AbortError' ? 'The connection check timed out. Check the player’s network and try again.' : error.message); progressPanel.hidden = true; }
    } finally { busy = ''; if (active()) update(); }
  };

  form.onsubmit = async (event) => {
    event.preventDefault();
    if (busy || (!pendingJobId && !connection)) return;
    const program = currentProgram();
    busy = 'publish'; setError(''); progressPanel.hidden = false;
    progress.removeAttribute('value'); status.textContent = pendingJobId ? 'Checking upload status…' : 'Preparing content…'; update();
    try {
      if (!pendingJobId) {
        const started = await post('/api/network/publish', {
          project: { ...project, cues: project.cues.filter(M.cueHasOccurrences) },
          programType: solution ? 'solution' : 'schedule', programId: program.id,
          connectionId: connection.id, playerPassword: passwordInput.value,
        });
        pendingJobId = started.jobId;
      }
      const result = await waitJob(pendingJobId, 2 * 60 * 60 * 1000);
      if (!active()) return;
      const device = result.device || connection.device;
      pendingJobId = ''; passwordInput.value = '';
      openDialog({
        title: 'Network playback ready',
        body: `<p class="dialog-copy"><strong>${esc(result.name || program.name)}</strong> was sent to <strong>${esc(device.name || device.sn)}</strong>.</p><p class="success-path">${esc(device.ip)} · ${esc(device.sn)}</p><p class="field-help">${esc(result.message || 'The player accepted the upload and playback request.')}</p>`,
      });
      notice('Network upload complete');
      return;
    } catch (error) {
      if (error.jobFailed) pendingJobId = '';
      if (active()) setError(error.name === 'AbortError' ? 'Relay could not confirm the upload status. Check the player before retrying.' : error.message);
    } finally { busy = ''; if (active()) update(); }
  };
  playerSelect.onchange = async () => {
    const player = players.find((item) => item.id === playerSelect.value);
    ipInput.value = player?.ip || '';
    passwordInput.value = '';
    clearConnection();
    const selectedId = playerSelect.value, selectedIp = ipInput.value;
    // Autofill emits an input event, which deliberately clears the previous
    // connection. Restore this selected board only after that event finishes.
    const filledPassword = await fillDefaultPassword();
    if (!active() || playerSelect.value !== selectedId || ipInput.value.trim() !== selectedIp) return;
    if (passwordInput.value && passwordInput.value !== filledPassword) return;
    connection = relayPlayerConnection(player);
    update();
  };
  ipInput.oninput = () => {
    const player = players.find((item) => item.id === playerSelect.value);
    if (player?.ip !== ipInput.value.trim()) playerSelect.value = '';
    clearConnection();
  };
  passwordInput.oninput = clearConnection;
  if (form.elements.program) form.elements.program.onchange = () => { setError(''); update(); };
  update();
  fillDefaultPassword();
  void (async () => {
    try {
      const data = await jsonRequest('/api/network/players');
      if (!active()) return;
      available = data.supported !== false;
      players = Array.isArray(data.players) ? data.players.filter((player) => player.id && player.ip) : [];
      playerSelect.innerHTML = '<option value="">Enter an IP address manually</option>' + players.map((player) =>
        `<option value="${esc(player.id)}">${esc(player.name || player.sn)} — ${esc(player.ip)}${player.sn ? ' · ' + esc(player.sn.slice(-8)) : ''}${relayPlayerConnection(player) ? ' · Connected' : ''}</option>`).join('');
      listHelp.textContent = available
        ? players.length ? 'Connected boards are ready to use. Other addresses need a connection check before uploading.' : 'No remembered players. Discover boards on the Players page or enter an IP address.'
        : 'Network publishing is unavailable. Restart the Relay Studio launcher and try again.';
    } catch (error) {
      if (active()) listHelp.textContent = 'Remembered players could not be loaded. Enter the player’s IP address manually.';
    } finally { if (active()) update(); }
  })();
}
