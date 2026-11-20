'use strict';

// Load this before styles so a saved dark theme is applied before the first paint.
const studioThemeStorageKey = 'relay-studio-theme';

function studioThemeIcon(dark) {
  const drawing = dark
    ? '<circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M2 12h2m16 0h2M4.9 4.9l1.4 1.4m11.4 11.4 1.4 1.4M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>'
    : '<path d="M20.2 14.1A8.6 8.6 0 0 1 9.9 3.8 8.6 8.6 0 1 0 20.2 14.1Z"/>';
  return `<svg aria-hidden="true" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round">${drawing}</svg>`;
}

function studioThemeButton() {
  const dark = document.documentElement.dataset.theme === 'dark';
  const label = dark ? 'Light mode' : 'Dark mode';
  return `<button type="button" class="btn btn-secondary compact studio-theme-toggle" data-action="toggle-theme" data-studio-theme-toggle title="Switch to ${dark ? 'light' : 'dark'} mode" aria-label="${label}">${studioThemeIcon(dark)}<span>${label}</span></button>`;
}

function applyStudioTheme(value) {
  const dark = value === 'dark';
  document.documentElement.dataset.theme = dark ? 'dark' : 'light';
  for (const button of document.querySelectorAll('[data-studio-theme-toggle]')) {
    const label = dark ? 'Light mode' : 'Dark mode';
    button.title = `Switch to ${dark ? 'light' : 'dark'} mode`;
    button.setAttribute('aria-label', label);
    button.innerHTML = `${studioThemeIcon(dark)}<span>${label}</span>`;
  }
  const meta = document.querySelector('meta[name="theme-color"]');
  if (meta) meta.content = dark ? '#121a17' : '#172622';
}

function toggleStudioTheme() {
  const value = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
  applyStudioTheme(value);
  try { localStorage.setItem(studioThemeStorageKey, value); } catch { /* The theme still works when browser storage is unavailable. */ }
}

let initialStudioTheme = 'light';
try { initialStudioTheme = localStorage.getItem(studioThemeStorageKey) || 'light'; } catch { }
applyStudioTheme(initialStudioTheme);
window.addEventListener('storage', (event) => {
  if (event.key === studioThemeStorageKey) applyStudioTheme(event.newValue);
});
