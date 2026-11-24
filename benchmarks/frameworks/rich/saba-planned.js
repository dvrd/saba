// Hand-authored stand-in for compiler output: clone a template, resolve its
// targets once, then drive owned bindings and keyed ranges from local signals.
import { startDashboard } from './dashboard.js';
import { renderDashboardHTML } from './dashboard-html.js';
import { bindCardFields, bindDashboardChrome } from './dom-bindings.js';
import { keyedBoard } from './saba-keys.js';
import { signal, effect } from './reactivity.js';

function mount(host, initial) {
  const surface = document.createElement('template');
  surface.innerHTML = renderDashboardHTML(initial, false);
  host.append(surface.content.cloneNode(true));
  const cardTemplate = document.createElement('template');
  cardTemplate.innerHTML = '<article class="rich-card" tabindex="0" role="button"><strong data-label></strong><span data-owner></span><span data-priority></span><span data-points></span></article>';
  const lists = initial.lanes.map(lane => {
    const matches = host.querySelectorAll('#lane-items-' + lane.id);
    if (matches.length !== 1) throw Error('Invalid lane target ' + lane.id);
    return matches[0];
  });
  function createCard(list, initialCard, initiallySelected) {
    const node = cardTemplate.content.firstElementChild.cloneNode(true);
    node.dataset.id = initialCard.id;
    node.id = 'card-' + initialCard.id;
    const record = signal(initialCard);
    const selected = signal(initiallySelected);
    const paint = bindCardFields(node);
    const binding = effect(() => paint(record.read(), selected.read()));
    return {node,
      update(next, isSelected) { record.write(next); selected.write(isSelected); },
      dispose() { binding.dispose(); node.remove(); }};
  }
  const snapshot = signal(initial);
  const updateChrome = bindDashboardChrome(host);
  const updateCards = keyedBoard(lists, createCard);
  effect(() => updateChrome(snapshot.read()));
  effect(() => {
    const next = snapshot.read();
    updateCards(next.lanes, next.selected);
  });
  return next => snapshot.write(next);
}

startDashboard(mount);
