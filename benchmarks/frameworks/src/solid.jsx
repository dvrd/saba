import { createEffect, createSignal, For, onSettled, Show } from 'solid-js';
import { render } from '@solidjs/web';
import { editorSession } from './session.js';
import { captions, views } from './transport.js';

function App() {
  const [confirmed, setConfirmed] = createSignal(null);
  const [draft, setDraft] = createSignal('');
  const [saving, setSaving] = createSignal(false);
  const [lists, setLists] = createSignal(views.map(() => []));
  const [loaded, setLoaded] = createSignal(false);
  const [notice, setNotice] = createSignal(null);

  const editor = editorSession({
    draft: setDraft,
    saving: setSaving,
    detail(record, adopt, initial) {
      setConfirmed(record);
      if (adopt) setDraft(record.title);
      if (initial) setNotice({ kind: 'ready', revision: record.revision });
    },
    list: (index, rows) => setLists(previous => previous.map((list, i) => i === index ? rows : list)),
    listsReady: () => setLoaded(true),
    saved: revision => setNotice({ kind: 'saved', revision }),
  });
  onSettled(() => {
    editor.start();
    return editor.dispose;
  });
  createEffect(notice, message => {
    if (message) performance.mark(message.kind === 'ready' ? 'mesa-editable' : 'mesa-fresh');
  });
  createEffect(loaded, ready => { if (ready) performance.mark('mesa-lists-ready'); });

  return <section class="screen">
    <h1>Items</h1>
    <form id="editor" data-revision={confirmed()?.revision}
      onSubmit={event => editor.submit(event, draft(), confirmed())}>
      <label for="title">Item 42</label>
      <div class="fields">
        <input id="title" name="title" disabled={!confirmed()} autocomplete="off" spellcheck="false"
          value={draft()} onInput={event => editor.edit(event.currentTarget.value)} />
        <button id="save" type="submit"
          disabled={!confirmed() || saving() || draft() === confirmed().title}>Save</button>
      </div>
      <output id="preview" for="title">{draft()}</output>
      <p id="status" role="status"><Show when={notice()} keyed fallback="Loading item…">
        {message => <span elementtiming={'mesa-' + message.kind}>
          {message.kind === 'ready' ? 'Ready' : 'Saved'}
        </span>}
      </Show></p>
    </form>
    <div class="lists"><For each={views}>{(name, index) =>
      <section>
        <h2>{captions[index()]}</h2>
        <ol id={'list-' + name}><For each={lists()[index()]} keyed={row => row.id}>
          {row => <li data-id={row().id}>{row().title}</li>}
        </For></ol>
      </section>
    }</For></div>
  </section>;
}

const dispose = render(App, document.querySelector('#app'));
addEventListener('pagehide', event => { if (!event.persisted) dispose(); });
