import { barHeight, counters, inspectorText } from './display.js';

function escapeHTML(value) {
  return String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;').replaceAll("'", '&#39;');
}

export function cardHTML(card, selected) {
  const id = escapeHTML(card.id);
  return `<article class="rich-card" id="card-${id}" data-id="${id}" tabindex="0" role="button" aria-pressed="${selected}">
    <strong data-label>${escapeHTML(card.title)}</strong>
    <span data-owner>${escapeHTML(card.owner)}</span>
    <span data-priority>${escapeHTML(card.priority)}</span>
    <span data-points>${escapeHTML(card.points)}</span>
  </article>`;
}

// The same markup is safe to send as a server fragment or parse as a local template.
export function renderDashboardHTML(model, includeCards = true) {
  const stats = counters.map(([id, label]) =>
    `<div><span>${label}</span><strong id="${id}">${escapeHTML(model[id])}</strong></div>`).join('');
  const bars = model.bins.map((value, i) =>
    `<span class="rich-bar" id="bin-${i}" data-value="${value}" style="height:${barHeight(value, model.bins)};--value:${value}"></span>`).join('');
  const lanes = model.lanes.map(lane =>
    `<section class="rich-lane" id="lane-${lane.id}" data-lane="${lane.id}"><h2>${escapeHTML(lane.name)}</h2><div id="lane-items-${lane.id}">${includeCards ? lane.cards.map(card => cardHTML(card, card.id === model.selected)).join('') : ''}</div></section>`).join('');
  return `<section class="rich-dashboard" id="board" data-revision="${model.revision}">
    <header><h1>Workload board</h1><div class="rich-toolbar">
      <button type="button" id="bulk">Boost workload</button>
      <button type="button" id="undo"${model.canUndo ? '' : ' disabled'}>Undo</button>
      <button type="button" id="filter" aria-pressed="${model.filter}">High priority</button>
    </div></header>
    <div class="rich-summary">${stats}</div>
    <div class="rich-chart" role="img" aria-label="Workload by bucket">${bars}</div>
    <aside class="rich-inspector" id="inspector" data-id="${model.inspector.id}">${escapeHTML(inspectorText(model.inspector))}</aside>
    <div id="rich-board">${lanes}</div>
  </section>`;
}
