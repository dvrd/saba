import { jsx, mount as mountComponent } from '/__saba/dom.js';
import { startDashboard } from './dashboard.js';
import { barHeight, counters, inspectorText } from './display.js';
import { bindCardFields, bindDashboardChrome } from './dom-bindings.js';
import { keyedBoard } from './saba-keys.js';

function Toolbar({model}) {
  return jsx('header', {}, jsx('h1', {}, 'Workload board'),
    jsx('div', {class: 'rich-toolbar'},
      jsx('button', {type:'button', id:'bulk'}, 'Boost workload'),
      jsx('button', {type:'button', id:'undo', disabled:!model.canUndo}, 'Undo'),
      jsx('button', {type:'button', id:'filter', 'aria-pressed':model.filter}, 'High priority')));
}
function Summary({model}) {
  return jsx('div', {class:'rich-summary'}, counters.map(([id, label]) =>
    jsx('div', {}, jsx('span', {}, label), jsx('strong', {id}, model[id]))));
}
function Chart({model}) {
  return jsx('div', {class:'rich-chart', role:'img', 'aria-label':'Workload by bucket'},
    model.bins.map((value, i) => jsx('span', {class:'rich-bar', id:'bin-' + i,
      'data-value':value, style:{height:barHeight(value, model.bins), '--value':value}})));
}
function Inspector({card}) {
  return jsx('aside', {class:'rich-inspector', id:'inspector', 'data-id':card.id}, inspectorText(card));
}
function Lane({lane}) {
  return jsx('section', {class:'rich-lane', id:'lane-' + lane.id, 'data-lane':lane.id},
    jsx('h2', {}, lane.name), jsx('div', {id:'lane-items-' + lane.id}));
}
function Dashboard({model}) {
  return jsx('section', {class:'rich-dashboard', id:'board', 'data-revision':model.revision},
    jsx(Toolbar, {model}), jsx(Summary, {model}), jsx(Chart, {model}), jsx(Inspector, {card:model.inspector}),
    jsx('div', {id:'rich-board'}, model.lanes.map(lane => jsx(Lane, {lane}))));
}

function mountCard(list, card, selected) {
  let node;
  const dispose = mountComponent(list, function Card() {
    node = jsx('article', {id:'card-' + card.id, class:'rich-card', 'data-id':card.id,
      role:'button', tabindex:0, 'aria-pressed':selected},
      jsx('strong', {'data-label':''}, card.title), jsx('span', {'data-owner':''}, card.owner),
      jsx('span', {'data-priority':''}, card.priority), jsx('span', {'data-points':''}, card.points));
    return node;
  });
  return {node, update:bindCardFields(node, card, selected), dispose};
}

startDashboard((host, initial) => {
  mountComponent(host, Dashboard, {model:initial});
  const lists = initial.lanes.map(lane => host.querySelector('#lane-items-' + lane.id));
  const paintCards = keyedBoard(lists, mountCard);
  const paintChrome = bindDashboardChrome(host);
  function paint(next) {
    paintChrome(next);
    paintCards(next.lanes, next.selected);
  }
  paint(initial);
  return paint;
});
