import { startDashboard } from './dashboard.js';
import { renderDashboardHTML } from './dashboard-html.js';
import { bindCardFields, bindDashboardChrome } from './dom-bindings.js';

function mount(host, initial) {
  host.innerHTML = renderDashboardHTML(initial, false);
  const template = document.createElement('template');
  template.innerHTML = '<article class="rich-card" tabindex="0" role="button"><strong data-label></strong><span data-owner></span><span data-priority></span><span data-points></span></article>';
  const paintChrome = bindDashboardChrome(host);
  const lists = initial.lanes.map(lane => host.querySelector('#lane-items-' + lane.id));
  let cards = new Map();

  function paint(next) {
    paintChrome(next);
    const retained = new Map();
    next.lanes.forEach((lane, index) => {
      const list = lists[index];
      let cursor = list.firstElementChild;
      for (const card of lane.cards) {
        let view = cards.get(card.id);
        if (!view) {
          const node = template.content.firstElementChild.cloneNode(true);
          node.id = 'card-' + card.id;
          node.dataset.id = card.id;
          view = { node, update: bindCardFields(node) };
        }
        view.update(card, next.selected === card.id);
        if (cursor !== view.node) list.insertBefore(view.node, cursor);
        cursor = view.node.nextElementSibling;
        retained.set(card.id, view);
      }
    });
    for (const [id, view] of cards) if (!retained.has(id)) view.node.remove();
    cards = retained;
  }
  paint(initial);
  return paint;
}

startDashboard(mount);
