<script>
  import ScaleTile from './ScaleTile.svelte';

  let records = $state.raw([]);
  export function replace(next) { records = next; }
</script>

{#each records as record (record.id)}<ScaleTile {record}/>{/each}
