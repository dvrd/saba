// Keyed floor. One map from id to element, reference cutoff, and the same
// backward placement Saba's keyed list uses. No signals and no per-row scope.
export const kind = 'keyed';

function textOf(record) {
  return record.id + ' · ' + record.score;
}

function create(record) {
  const element = document.createElement('div');
  element.className = 'cell';
  element.setAttribute('data-id', String(record.id));
  const text = document.createTextNode(textOf(record));
  element.append(text);
  return { element, text, record };
}

function move(host, element, before) {
  if (element.parentNode !== host) host.insertBefore(element, before);
  else if (element.nextSibling !== before) {
    if (typeof host.moveBefore === 'function') host.moveBefore(element, before);
    else host.insertBefore(element, before);
  }
}

export function mountBand(host, records) {
  const cells = new Map();
  function replace(next) {
    const seen = new Set();
    for (let i = 0; i < next.length; i++) {
      const id = next[i].id;
      if (typeof id !== 'number' || seen.has(id)) throw new Error('Bad row key ' + id);
      seen.add(id);
    }
    for (const [id, cell] of cells) {
      if (!seen.has(id)) {
        cell.element.remove();
        cells.delete(id);
      }
    }
    let before = null;
    for (let i = next.length - 1; i >= 0; i--) {
      const record = next[i];
      let cell = cells.get(record.id);
      if (!cell) {
        cell = create(record);
        cells.set(record.id, cell);
      } else if (cell.record !== record) {
        const value = textOf(record);
        if (cell.text.data !== value) cell.text.data = value;
        cell.record = record;
      }
      move(host, cell.element, before);
      before = cell.element;
    }
  }
  replace(records);
  return {
    replace,
    dispose() {
      for (const cell of cells.values()) cell.element.remove();
      cells.clear();
    },
  };
}
