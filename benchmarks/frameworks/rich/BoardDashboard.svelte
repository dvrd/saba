<script>
  import BoardCard from './BoardCard.svelte';
  import { barHeight, counters, inspectorText } from './display.js';

  let { initial } = $props();
  let model = $state.raw(initial);
  export function update(next) { model = next; }
</script>

{#snippet toolbar()}
  <header><h1>Workload board</h1><div class="rich-toolbar">
    <button type="button" id="bulk">Boost workload</button>
    <button type="button" id="undo" disabled={!model.canUndo}>Undo</button>
    <button type="button" id="filter" aria-pressed={model.filter}>High priority</button>
  </div></header>
{/snippet}

{#snippet summary()}
  <div class="rich-summary">
    {#each counters as [key, label] (key)}
      <div><span>{label}</span><strong id={key}>{model[key]}</strong></div>
    {/each}
  </div>
{/snippet}

{#snippet chart()}
  <div class="rich-chart" role="img" aria-label="Workload by bucket">
    {#each model.bins as value, i (i)}
      <span class="rich-bar" id={'bin-' + i} data-value={value}
        style:height={barHeight(value, model.bins)} style:--value={value}></span>
    {/each}
  </div>
{/snippet}

{#snippet inspector(card)}
  <aside class="rich-inspector" id="inspector" data-id={card.id}>{inspectorText(card)}</aside>
{/snippet}

{#snippet lanePanel(lane)}
  <section class="rich-lane" id={'lane-' + lane.id} data-lane={lane.id}>
    <h2>{lane.name}</h2><div id={'lane-items-' + lane.id}>
      {#each lane.cards as card (card.id)}<BoardCard {card} selected={card.id === model.selected}/>{/each}
    </div>
  </section>
{/snippet}

<section class="rich-dashboard" id="board" data-revision={model.revision}>
  {@render toolbar()}{@render summary()}{@render chart()}{@render inspector(model.inspector)}
  <div id="rich-board">{#each model.lanes as lane (lane.id)}{@render lanePanel(lane)}{/each}</div>
</section>
