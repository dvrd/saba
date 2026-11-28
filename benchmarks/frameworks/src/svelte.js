import { mount, unmount } from 'svelte';
import App from './App.svelte';

const app = mount(App, { target: document.querySelector('#app') });
addEventListener('pagehide', event => { if (!event.persisted) unmount(app); });
