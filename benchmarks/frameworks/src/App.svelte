<script>
  import { onMount } from 'svelte';
  import { editorSession } from './session.js';
  import { captions, views } from './transport.js';

  let confirmed = $state.raw(null);
  let draft = $state('');
  let saving = $state(false);
  let lists = $state.raw(views.map(() => []));
  let loaded = $state(false);
  let notice = $state.raw(null);

  const editor = editorSession({
    draft: value => { draft = value; },
    saving: value => { saving = value; },
    detail(record, adopt, initial) {
      confirmed = record;
      if (adopt) draft = record.title;
      if (initial) notice = { kind: 'ready', revision: record.revision };
    },
    list(index, rows) {
      lists = lists.map((list, i) => i === index ? rows : list);
    },
    listsReady: () => { loaded = true; },
    saved: revision => { notice = { kind: 'saved', revision }; },
  });
  onMount(() => {
    editor.start();
    return editor.dispose;
  });
  $effect(() => {
    if (notice) performance.mark(notice.kind === 'ready' ? 'mesa-editable' : 'mesa-fresh');
  });
  $effect(() => { if (loaded) performance.mark('mesa-lists-ready'); });
</script>

<section class="screen">
  <h1>Items</h1>
  <form id="editor" data-revision={confirmed?.revision}
    onsubmit={event => editor.submit(event, draft, confirmed)}>
    <label for="title">Item 42</label>
    <div class="fields">
      <input id="title" name="title" disabled={!confirmed} autocomplete="off" spellcheck="false"
        value={draft} oninput={event => editor.edit(event.currentTarget.value)} />
      <button id="save" type="submit"
        disabled={!confirmed || saving || draft === confirmed.title}>Save</button>
    </div>
    <output id="preview" for="title">{draft}</output>
    <p id="status" role="status">
      {#key notice}
        {#if notice}
          <span elementtiming={'mesa-' + notice.kind}>{notice.kind === 'ready' ? 'Ready' : 'Saved'}</span>
        {:else}
          Loading item…
        {/if}
      {/key}
    </p>
  </form>
  <div class="lists">
    {#each views as name, index (name)}
      <section>
        <h2>{captions[index]}</h2>
        <ol id={'list-' + name}>
          {#each lists[index] as row (row.id)}
            <li data-id={row.id}>{row.title}</li>
          {/each}
        </ol>
      </section>
    {/each}
  </div>
</section>
