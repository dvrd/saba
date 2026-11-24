import { barHeight, counters, inspectorText } from './display.js';

export function bindDashboardChrome(host) {
  const board = host.querySelector('#board');
  const counts = counters.map(([key]) => [key, host.querySelector('#' + key)]);
  const bars = [...host.querySelectorAll('.rich-bar')];
  const undo = host.querySelector('#undo');
  const filter = host.querySelector('#filter');
  const inspector = host.querySelector('#inspector');
  let previous;
  return next => {
    if (previous?.revision !== next.revision) board.dataset.revision = next.revision;
    for (const [key, element] of counts) {
      if (previous?.[key] !== next[key]) element.textContent = next[key];
    }
    if (previous?.bins !== next.bins) {
      next.bins.forEach((value, i) => {
        if (bars[i].dataset.value !== String(value)) {
          bars[i].dataset.value = value;
          bars[i].style.setProperty('--value', String(value));
        }
        const height = barHeight(value, next.bins);
        if (bars[i].style.height !== height) bars[i].style.height = height;
      });
    }
    if (previous?.inspector !== next.inspector) {
      inspector.dataset.id = next.inspector.id;
      inspector.textContent = inspectorText(next.inspector);
    }
    if (previous?.canUndo !== next.canUndo) undo.disabled = !next.canUndo;
    if (previous?.filter !== next.filter) filter.setAttribute('aria-pressed', String(next.filter));
    previous = next;
  };
}

export function bindCardFields(node, initialCard, initiallySelected) {
  const [label, owner, priority, points] = node.children;
  let previous = initialCard;
  let wasSelected = initiallySelected;
  return (card, selected) => {
    if (previous !== card) {
      if (previous?.title !== card.title) label.textContent = card.title;
      if (previous?.owner !== card.owner) owner.textContent = card.owner;
      if (previous?.priority !== card.priority) priority.textContent = card.priority;
      if (previous?.points !== card.points) points.textContent = card.points;
      previous = card;
    }
    if (wasSelected !== selected) node.setAttribute('aria-pressed', String(selected));
    wasSelected = selected;
  };
}
