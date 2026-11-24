import { mount, tick } from 'svelte';
import { startDashboard } from './dashboard.js';
import Dashboard from './BoardDashboard.svelte';

startDashboard(async (host, initial) => {
  const view = mount(Dashboard, {target:host, props:{initial}});
  await tick();
  return async next => { view.update(next); await tick(); };
});
