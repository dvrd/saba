// The JSON implementations share HTTP behavior. Each view owns its DOM and commit timing.
export const views = ['all', 'open', 'marked'];
export const captions = ['All items', 'Open', 'Marked'];

async function jsonRequest(url, options) {
  const response = await fetch(url, {cache: 'no-store', ...options});
  if (!response.ok) throw new Error(url + ' returned ' + response.status);
  return response.json();
}

export function readViews(onDetail, onList, onListsReady) {
  const detail = jsonRequest('/api/items/42').then(onDetail);
  const lists = Promise.all(views.map((view, index) =>
    jsonRequest('/api/lists/' + view).then(records => onList(index, records))));
  return Promise.all([detail, lists.then(onListsReady)]);
}

export async function saveTitle(title, expectedRevision) {
  const operationId = crypto.randomUUID();
  const key = 'mesa-perf:item:42:' + operationId;
  sessionStorage.setItem(key, operationId);
  const saved = await jsonRequest('/api/items/42', {
    method: 'PATCH',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({operationId, expectedRevision, title}),
  });
  if (saved.id !== '42' || saved.revision !== expectedRevision + 1) {
    throw new Error('Unexpected save acknowledgement');
  }
  sessionStorage.removeItem(key);
  return saved;
}

export function fail(error) {
  const message = error instanceof Error ? error.message : String(error);
  document.documentElement.dataset.failure = message;
  const status = document.querySelector('#status');
  if (status) status.textContent = message;
  console.error(error);
}
