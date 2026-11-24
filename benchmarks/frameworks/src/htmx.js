// The server renders each view. htmx fetches and swaps its HTML; Idiomorph uses
// stable, list-local row IDs to retain nodes when the title or membership changes.
import 'htmx.org';
import 'idiomorph/htmx';

const form = document.getElementById('editor');
const status = document.getElementById('status');
let pendingViews = new Set(['record-fields', 'list-all', 'list-open', 'list-marked']);
let confirmed = '';
let draft = '';
let saving = false;
let editVersion = 0;
let submittedVersion = 0;
let operationId;
let initialListsReady = false;

function milestone(id, label) {
  const marker = document.createElement('span');
  marker.setAttribute('elementtiming', id);
  marker.textContent = label;
  status.replaceChildren(marker);
}

function applyDraft() {
  const input = document.getElementById('title');
  if (input.value !== draft) input.value = draft;
  document.getElementById('preview').textContent = draft;
  document.getElementById('save').disabled = saving || confirmed === draft;
}

form.addEventListener('input', event => {
  if (event.target.id === 'title') {
    draft = event.target.value;
    editVersion++;
    applyDraft();
  }
});

form.addEventListener('submit', event => {
  if (saving || !form.dataset.revision || confirmed === draft) {
    event.preventDefault();
    event.stopImmediatePropagation();
    return;
  }
  performance.mark('mesa-save-start');
  operationId = crypto.randomUUID();
  try {
    sessionStorage.setItem('mesa-perf:item:42:' + operationId, operationId);
  } catch (error) {
    event.preventDefault();
    event.stopImmediatePropagation();
    status.textContent = document.documentElement.dataset.failure = String(error);
    return;
  }
  saving = true;
  submittedVersion = editVersion;
  pendingViews = new Set(['record-fields', 'list-all', 'list-open', 'list-marked']);
  applyDraft();
}, true);

form.addEventListener('htmx:configRequest', event => {
  if (event.detail.elt === form && event.detail.verb === 'patch') {
    event.detail.parameters.operationId = operationId;
    event.detail.parameters.expectedRevision = form.dataset.revision;
  }
});

document.addEventListener('htmx:afterRequest', event => {
  const {elt, successful} = event.detail;
  if (successful && elt === form && event.detail.requestConfig.verb === 'patch') {
    sessionStorage.removeItem('mesa-perf:item:42:' + operationId);
  }
  if (!successful || !pendingViews.has(elt.id)) return;
  pendingViews.delete(elt.id);
  if (elt.id === 'record-fields') {
    const canonical = document.getElementById('canonical');
    const first = !form.dataset.revision;
    confirmed = canonical.textContent;
    form.dataset.revision = canonical.dataset.revision;
    if (first || editVersion === submittedVersion) draft = confirmed;
    applyDraft();
    if (first) {
      milestone('mesa-ready', 'Ready');
      performance.mark('mesa-editable');
    }
  }
  if (!initialListsReady && [...pendingViews].every(id => id === 'record-fields')) {
    initialListsReady = true;
    performance.mark('mesa-lists-ready');
  }
  if (saving && pendingViews.size === 0) {
    saving = false;
    applyDraft();
    milestone('mesa-saved', 'Saved');
    performance.mark('mesa-fresh');
  }
});

for (const eventName of ['htmx:responseError', 'htmx:sendError', 'htmx:swapError']) {
  document.addEventListener(eventName, event => {
    const error = event.detail.error || event.detail.xhr?.statusText || eventName;
    status.textContent = document.documentElement.dataset.failure = String(error);
  });
}
