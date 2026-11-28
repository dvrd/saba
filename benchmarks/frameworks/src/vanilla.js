// Dependency-free browser implementation of the same static-form editor.
import {readViews, saveTitle, views, fail} from './transport.js';

const editor = document.querySelector('#editor');
const title = editor.querySelector('#title');
const preview = editor.querySelector('#preview');
const save = editor.querySelector('#save');
const status = editor.querySelector('#status');
const lists = views.map(view => ({
  host: document.getElementById('list-' + view),
  rows: new Map(),
}));
let confirmed;
let dirtyVersion = 0;
let saving = false;

function showStatus(identifier, text) {
  const marker = document.createElement('span');
  marker.setAttribute('elementtiming', identifier);
  marker.textContent = text;
  status.replaceChildren(marker);
}

function updateDraft() {
  if (preview.textContent !== title.value) preview.textContent = title.value;
  save.disabled = !confirmed || saving || title.value === confirmed.title;
}

function renderList(index, records) {
  const {host, rows} = lists[index];
  const next = new Map();
  const initial = rows.size === 0 ? document.createDocumentFragment() : null;
  let cursor = host.firstElementChild;
  for (const record of records) {
    if (next.has(record.id)) throw new Error('Duplicate row key');
    let row = rows.get(record.id);
    if (!row) {
      row = document.createElement('li');
      row.dataset.id = record.id;
      row.append(document.createTextNode(record.title));
    } else if (row.firstChild.data !== record.title) {
      row.firstChild.data = record.title;
    }
    if (initial) initial.append(row);
    else if (row !== cursor) host.insertBefore(row, cursor);
    cursor = row.nextElementSibling;
    next.set(record.id, row);
  }
  for (const [id, row] of rows) if (!next.has(id)) row.remove();
  if (initial) host.append(initial);
  lists[index].rows = next;
}

function refresh(initial, submittedVersion) {
  return readViews(record => {
    confirmed = record;
    editor.dataset.revision = String(record.revision);
    if (initial || dirtyVersion === submittedVersion) title.value = record.title;
    title.disabled = false;
    updateDraft();
    if (initial) {
      showStatus('mesa-ready', 'Ready');
      performance.mark('mesa-editable');
    }
  }, renderList, () => { if (initial) performance.mark('mesa-lists-ready'); });
}

title.addEventListener('input', () => {
  dirtyVersion++;
  updateDraft();
});
editor.addEventListener('submit', async event => {
  event.preventDefault();
  if (!confirmed || saving || title.value === confirmed.title) return;
  performance.mark('mesa-save-start');
  saving = true;
  updateDraft();
  const version = dirtyVersion;
  try {
    await saveTitle(title.value, confirmed.revision);
    await refresh(false, version);
    saving = false;
    updateDraft();
    showStatus('mesa-saved', 'Saved');
    performance.mark('mesa-fresh');
  } catch (error) { fail(error); }
});
refresh(true).catch(fail);
