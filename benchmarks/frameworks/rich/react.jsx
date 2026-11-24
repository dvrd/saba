import { memo, useLayoutEffect } from 'react';
import { createRoot } from 'react-dom/client';
import { startDashboard } from './dashboard.js';
import { barHeight, counters, inspectorText } from './display.js';

const Card = memo(function Card({card, selected}) {
  return <article className="rich-card" id={'card-' + card.id} data-id={card.id} role="button" tabIndex={0} aria-pressed={selected}>
    <strong data-label="">{card.title}</strong><span data-owner="">{card.owner}</span>
    <span data-priority="">{card.priority}</span><span data-points="">{card.points}</span>
  </article>;
});

function Lane({lane, selected}) {
  return <section className="rich-lane" id={'lane-' + lane.id} data-lane={lane.id}>
    <h2>{lane.name}</h2><div id={'lane-items-' + lane.id}>
      {lane.cards.map(card => <Card key={card.id} card={card} selected={selected === card.id} />)}
    </div>
  </section>;
}

function Toolbar({model}) {
  return <header><h1>Workload board</h1><div className="rich-toolbar">
    <button type="button" id="bulk">Boost workload</button>
    <button type="button" id="undo" disabled={!model.canUndo}>Undo</button>
    <button type="button" id="filter" aria-pressed={model.filter}>High priority</button>
  </div></header>;
}

function Summary({model}) {
  return <div className="rich-summary">{counters.map(([key, label]) =>
    <div key={key}><span>{label}</span><strong id={key}>{model[key]}</strong></div>)}</div>;
}

function Chart({bins}) {
  return <div className="rich-chart" role="img" aria-label="Workload by bucket">{bins.map((value, i) =>
    <span key={i} className="rich-bar" id={'bin-' + i} data-value={value}
      style={{height:barHeight(value, bins), '--value':value}} />)}</div>;
}

function Inspector({card}) {
  return <aside className="rich-inspector" id="inspector" data-id={card.id}>{inspectorText(card)}</aside>;
}

function Dashboard({model, committed}) {
  useLayoutEffect(() => { committed(); }, [committed]);
  return <section className="rich-dashboard" id="board" data-revision={model.revision}>
    <Toolbar model={model}/><Summary model={model}/><Chart bins={model.bins}/><Inspector card={model.inspector}/>
    <div id="rich-board">{model.lanes.map(lane => <Lane key={lane.id} lane={lane} selected={model.selected}/>)}</div>
  </section>;
}

startDashboard(async (host, initial) => {
  const root = createRoot(host);
  const update = model => new Promise(committed => root.render(<Dashboard model={model} committed={committed}/>));
  await update(initial);
  return update;
});
