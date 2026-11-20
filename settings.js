'use strict';

const studioPasswordState = { saved: '', draft: '', loaded: false, loading: null, saving: null, dirty: false, busy: false, error: '' };

function studioPasswordControls() {
  return `<div class="studio-password-control" role="group" aria-label="Default player password">
    <label class="studio-password-label" for="default-player-password">Player password</label>
    <input id="default-player-password" type="text" spellcheck="false" autocapitalize="none" autocomplete="off" maxlength="256" placeholder="Default player password" aria-label="Default player password">
    <button type="button" class="studio-password-save" data-password-save title="Save default player password" aria-label="Save default player password">Save</button>
    <button type="button" class="icon-btn studio-password-clear" data-password-clear title="Clear saved player password" aria-label="Clear saved player password">${icon('x', 14)}</button>
  </div>`;
}

async function studioSettingsPost(path, payload) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 15000);
  try {
    const sessionResponse = await fetch('/api/session', { cache: 'no-store', signal: controller.signal });
    if (!sessionResponse.ok) throw new Error('Reopen the Relay Studio launcher to use saved player passwords.');
    const session = await sessionResponse.json();
    const response = await fetch(path, {
      method: 'POST', cache: 'no-store', signal: controller.signal,
      headers: { 'Content-Type': 'application/json', 'X-Studio-Token': session.exportToken },
      body: JSON.stringify(payload),
    });
    const result = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(result.error || 'The default player password could not be saved or loaded.');
    return result;
  } catch (error) {
    if (error.name === 'AbortError') throw new Error('Player password settings timed out. Check the Relay Studio launcher and try again.');
    throw error;
  } finally { clearTimeout(timer); }
}

function paintStudioPasswordControls() {
  const control = document.querySelector('.studio-password-control');
  if (!control) return;
  const input = control.querySelector('input');
  if (input.value !== studioPasswordState.draft) input.value = studioPasswordState.draft;
  input.disabled = studioPasswordState.busy;
  control.classList.toggle('is-dirty', studioPasswordState.dirty);
  control.classList.toggle('has-error', Boolean(studioPasswordState.error));
  input.title = studioPasswordState.error || (studioPasswordState.dirty ? 'Not saved yet. Click Save to use this password for future USB and network playback.'
    : studioPasswordState.saved ? 'Saved for USB and network playback on this user account. Change it here when working for another company.'
      : 'Save a default password to fill USB and network playback dialogs.');
  const save = control.querySelector('[data-password-save]');
  save.disabled = studioPasswordState.busy || !studioPasswordState.dirty;
  save.textContent = studioPasswordState.busy ? 'Saving…' : 'Save';
  control.querySelector('[data-password-clear]').disabled = studioPasswordState.busy || (!studioPasswordState.saved && !studioPasswordState.error);
}

function mountStudioPasswordControls() {
  const control = document.querySelector('.studio-password-control');
  if (!control) return;
  const input = control.querySelector('input');
  input.oninput = () => {
    studioPasswordState.draft = input.value;
    studioPasswordState.dirty = input.value !== studioPasswordState.saved;
    studioPasswordState.error = '';
    paintStudioPasswordControls();
  };
  input.onkeydown = (event) => {
    if (event.key === 'Enter') { event.preventDefault(); void saveStudioDefaultPlayerPassword(); }
  };
  control.querySelector('[data-password-save]').onclick = () => void saveStudioDefaultPlayerPassword();
  control.querySelector('[data-password-clear]').onclick = () => void saveStudioDefaultPlayerPassword('');
  paintStudioPasswordControls();
}

async function loadStudioDefaultPlayerPassword(force = false) {
  if (studioPasswordState.saving) {
    await studioPasswordState.saving;
    if (studioPasswordState.error) throw new Error(studioPasswordState.error);
    return studioPasswordState.saved;
  }
  if (studioPasswordState.loading) return studioPasswordState.loading;
  if (studioPasswordState.loaded && !force) return studioPasswordState.saved;
  studioPasswordState.loading = (async () => {
    const result = await studioSettingsPost('/api/settings/player-password/read', {});
    if (typeof result.password !== 'string') throw new Error('The saved player password could not be read.');
    studioPasswordState.saved = result.password;
    studioPasswordState.loaded = true;
    studioPasswordState.error = '';
    if (!studioPasswordState.dirty) studioPasswordState.draft = result.password;
    else studioPasswordState.dirty = studioPasswordState.draft !== result.password;
    paintStudioPasswordControls();
    return result.password;
  })();
  try { return await studioPasswordState.loading; }
  catch (error) { studioPasswordState.error = error.message; paintStudioPasswordControls(); throw error; }
  finally { studioPasswordState.loading = null; }
}

async function saveStudioDefaultPlayerPassword(value = studioPasswordState.draft) {
  if (studioPasswordState.busy || (value === studioPasswordState.saved && !studioPasswordState.dirty && !studioPasswordState.error)) return;
  studioPasswordState.busy = true;
  paintStudioPasswordControls();
  const payload = { password: value };
  studioPasswordState.saving = (async () => { try {
    // Finish an in-flight read so it cannot overwrite a newly saved company password.
    if (studioPasswordState.loading) await studioPasswordState.loading.catch(() => {});
    await studioSettingsPost('/api/settings/player-password', payload);
    studioPasswordState.saved = value;
    studioPasswordState.draft = value;
    studioPasswordState.loaded = true;
    studioPasswordState.dirty = false;
    studioPasswordState.error = '';
    notice(value ? 'Default player password saved for USB and network playback' : 'Default player password cleared');
    document.dispatchEvent(new Event('studio-player-password-saved'));
  } catch (error) {
    studioPasswordState.error = error.message;
    notice(error.message);
  } finally {
    delete payload.password;
    studioPasswordState.busy = false;
    paintStudioPasswordControls();
  } })();
  try { await studioPasswordState.saving; } finally { studioPasswordState.saving = null; }
}

async function applyDefaultPlayerPassword(input, { refresh = true } = {}) {
  const initial = input.value;
  const password = await loadStudioDefaultPlayerPassword(refresh);
  // Never replace a password the operator typed while the settings request ran.
  if (input.isConnected && !input.disabled && !initial && input.value === initial) {
    input.value = password;
    input.dispatchEvent(new Event('input', { bubbles: true }));
  }
  return password;
}

document.addEventListener('DOMContentLoaded', () => { void loadStudioDefaultPlayerPassword().catch(() => {}); });
