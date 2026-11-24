<script>
  let { record } = $props();
</script>

<div class="cell" data-id={record.id}>{record.id + ' · ' + record.score}</div>
