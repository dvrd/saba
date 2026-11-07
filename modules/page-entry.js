import { mount } from '/__saba/dom.js';

const entry = document.querySelector('script[data-page]');
if (!entry) throw new Error('Missing page module.');
const { default: Page, title } = await import(entry.dataset.page);
if (typeof Page !== 'function' || typeof title !== 'string') throw new Error('Pages must export a default component and a title.');
document.title = title;
const dispose = mount(document.getElementById('app'), Page);
addEventListener('pagehide', (event) => { if (!event.persisted) dispose(); });
