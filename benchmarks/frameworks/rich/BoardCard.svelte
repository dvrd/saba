<script>
  let { card, selected } = $props();
</script>

<article class="rich-card" id={'card-' + card.id} data-id={card.id} role="button" tabindex="0" aria-pressed={selected}>
  <strong data-label>{card.title}</strong><span data-owner>{card.owner}</span>
  <span data-priority>{card.priority}</span><span data-points>{card.points}</span>
</article>
