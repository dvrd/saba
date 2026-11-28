import React, { memo, useLayoutEffect, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { editorSession } from './session.js';
import { captions, views } from './transport.js';

const RecordList = memo(function RecordList({ name, caption, rows }) {
  return <section>
    <h2>{caption}</h2>
    <ol id={'list-' + name}>{rows.map(row =>
      <li key={row.id} data-id={row.id}>{row.title}</li>
    )}</ol>
  </section>;
});

function App() {
  const [confirmed, setConfirmed] = useState(null);
  const [draft, setDraft] = useState('');
  const [saving, setSaving] = useState(false);
  const [lists, setLists] = useState(() => views.map(() => []));
  const [loaded, setLoaded] = useState(false);
  const [notice, setNotice] = useState(null);

  const [editor] = useState(() => editorSession({
    draft: setDraft,
    saving: setSaving,
    detail(record, adopt, initial) {
      setConfirmed(record);
      if (adopt) setDraft(record.title);
      if (initial) setNotice({ kind: 'ready', revision: record.revision });
    },
    list(index, rows) {
      setLists(previous => previous.map((list, i) => i === index ? rows : list));
    },
    listsReady: () => setLoaded(true),
    saved: revision => setNotice({ kind: 'saved', revision }),
  }));

  useLayoutEffect(() => {
    editor.start();
    return editor.dispose;
  }, [editor]);
  useLayoutEffect(() => {
    if (notice) performance.mark(notice.kind === 'ready' ? 'mesa-editable' : 'mesa-fresh');
  }, [notice]);
  useLayoutEffect(() => {
    if (loaded) performance.mark('mesa-lists-ready');
  }, [loaded]);

  return <section className="screen">
    <h1>Items</h1>
    <form id="editor" data-revision={confirmed?.revision}
      onSubmit={event => editor.submit(event, draft, confirmed)}>
      <label htmlFor="title">Item 42</label>
      <div className="fields">
        <input id="title" name="title" disabled={!confirmed} autoComplete="off" spellCheck={false}
          value={draft} onChange={event => editor.edit(event.currentTarget.value)} />
        <button id="save" type="submit"
          disabled={!confirmed || saving || draft === confirmed.title}>Save</button>
      </div>
      <output id="preview" htmlFor="title">{draft}</output>
      <p id="status" role="status">{notice
        ? <span key={notice.kind + notice.revision} elementtiming={'mesa-' + notice.kind}>
            {notice.kind === 'ready' ? 'Ready' : 'Saved'}
          </span>
        : 'Loading item…'}</p>
    </form>
    <div className="lists">{views.map((name, i) =>
      <RecordList key={name} name={name} caption={captions[i]} rows={lists[i]} />
    )}</div>
  </section>;
}

const root = createRoot(document.querySelector('#app'));
root.render(<App />);
addEventListener('pagehide', event => { if (!event.persisted) root.unmount(); });
