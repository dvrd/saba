import { createSignal, flush, For } from 'solid-js';
import { render } from '@solidjs/web';
import { startDashboard } from './dashboard.js';
import { barHeight, counters, inspectorText } from './display.js';

const buckets = Array.from({length:8}, (_, i) => i);

function Card(props) {
  return <article class="rich-card" id={'card-' + props.card.id} data-id={props.card.id}
    tabindex="0" role="button" aria-pressed={String(props.selected)}>
    <strong data-label="">{props.card.title}</strong><span data-owner="">{props.card.owner}</span>
    <span data-priority="">{props.card.priority}</span><span data-points="">{props.card.points}</span>
  </article>;
}

function Lane(props) {
  return <section class="rich-lane" id={'lane-' + props.lane.id} data-lane={props.lane.id}>
    <h2>{props.lane.name}</h2><div id={'lane-items-' + props.lane.id}>
      <For each={props.lane.cards} keyed={card => card.id}>{card =>
        <Card card={card()} selected={card().id === props.selected}/>}
      </For>
    </div>
  </section>;
}

function Toolbar(props) {
  return <header><h1>Workload board</h1><div class="rich-toolbar">
    <button type="button" id="bulk">Boost workload</button>
    <button type="button" id="undo" disabled={!props.model.canUndo}>Undo</button>
    <button type="button" id="filter" aria-pressed={String(props.model.filter)}>High priority</button>
  </div></header>;
}

function Summary(props) {
  return <div class="rich-summary"><For each={counters}>{([key,label]) =>
    <div><span>{label}</span><strong id={key}>{props.model[key]}</strong></div>}
  </For></div>;
}

function Chart(props) {
  return <div class="rich-chart" role="img" aria-label="Workload by bucket"><For each={buckets}>{i =>
    <span class="rich-bar" id={'bin-' + i} data-value={props.bins[i]}
      style={'height:' + barHeight(props.bins[i], props.bins) + ';--value:' + props.bins[i]}/>}
  </For></div>;
}

function Inspector(props) {
  return <aside class="rich-inspector" id="inspector" data-id={props.card.id}>{inspectorText(props.card)}</aside>;
}

function Dashboard(props) {
  return <section class="rich-dashboard" id="board" data-revision={props.model.revision}>
    <Toolbar model={props.model}/><Summary model={props.model}/><Chart bins={props.model.bins}/>
    <Inspector card={props.model.inspector}/>
    <div id="rich-board"><For each={props.model.lanes} keyed={lane => lane.id}>{lane =>
      <Lane lane={lane()} selected={props.model.selected}/>}
    </For></div>
  </section>;
}

startDashboard((host, initial) => {
  let update;
  render(() => {
    const [model, setModel] = createSignal(initial);
    update = next => { setModel(next); flush(); };
    return <Dashboard model={model()}/>;
  }, host);
  return update;
});
