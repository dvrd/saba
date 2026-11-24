<script>
  let records = $state.raw([]);
  export function replace(next) { records = next; }
</script>

{#each records as record (record.id)}
  <div class="cell" data-id={record.id}>{record.id} · {record.score}</div>
{/each}
