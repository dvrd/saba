import { mount } from '/__saba/dom.js';

const entry = document.querySelector('script[data-page]');

// A page module can fail to load (an expired deployment, a dropped
// connection) or reject its own URL. Leave the reader a native way out instead
// of an empty document, then let the error reach the console and reporters.
function unavailable(error) {
  const recovery = document.querySelector('[data-saba-recover]');
  const app = document.getElementById('app');
  if (recovery) recovery.hidden = false;
  else if (app && !app.childNodes.length) {
    const link = document.createElement('a');
    link.href = '';
    link.setAttribute('data-saba-recover', '');
    link.textContent = entry?.dataset.recoveryLabel || 'Reload';
    app.append(link);
  }
  throw error;
}

try {
  if (!entry) throw new Error('Missing page module.');
  const params = Object.create(null);
  if (entry.dataset.route) {
    const pattern = entry.dataset.route.slice(1).split('/');
    const parts = location.pathname.slice(1).split('/').map(decodeURIComponent);
    if (parts.length !== pattern.length) throw new Error('Unexpected page path.');
    for (const [index, segment] of pattern.entries()) {
      const value = parts[index];
      if (!value || value.includes('/') || value.includes('\\')) throw new Error('Invalid page segment.');
      if (segment.startsWith(':')) params[segment.slice(1)] = value;
      else if (segment !== value) throw new Error('Unexpected page path.');
    }
  }
  const { default: Page, title } = await import(entry.dataset.page);
  if (typeof Page !== 'function' || typeof title !== 'string') throw new Error('Pages must export a default component and a title.');
  document.title = title;
  const dispose = mount(document.getElementById('app'), Page, {params: Object.freeze(params)});
  addEventListener('pagehide', (event) => { if (!event.persisted) dispose(); });
} catch (error) {
  unavailable(error);
}
