// Compiler experiment for a keyed list of immutable, normalized records.
// Each item owns one div and one nonempty text child. The band owns the host.
function cellText(record) {
  return record.id + ' · ' + record.score;
}

function createCell(record) {
  const element = document.createElement('div');
  element.className = 'cell';
  element.setAttribute('data-id', String(record.id));
  element.textContent = cellText(record);
  return element;
}

function mountBand(host, records, labels) {
  for (const record of records) {
    const element = createCell(record);
    host.append(element);
    if (labels) labels.push(element.firstChild);
  }

  // Only structural edits build an index. Retained keys keep their div and Text.
  function reconcileSuffix(next, start) {
    let cursor = host.children[start] ?? null;
    let element = cursor;
    const retained = new Map();
    for (let i = start; i < records.length; i++) {
      retained.set(records[i].id, {element, record: records[i]});
      element = element.nextElementSibling;
    }

    if (labels) labels.length = start;
    for (let i = start; i < next.length; i++) {
      const record = next[i];
      const old = retained.get(record.id);
      const node = old ? old.element : createCell(record);
      if (old) {
        retained.delete(record.id);
        if (old.record.score !== record.score) node.firstChild.data = cellText(record);
      }
      if (node !== cursor) host.insertBefore(node, cursor);
      cursor = node.nextElementSibling;
      if (labels) labels.push(node.firstChild);
    }
    for (const {element} of retained.values()) element.remove();
  }

  return {
    replace(next) {
      if (!records) return;
      const common = Math.min(records.length, next.length);
      let i = 0;
      for (; i < common; i++) {
        const old = records[i];
        const record = next[i];
        if (old === record) continue;
        if (old.id !== record.id) break;
        if (old.score !== record.score) {
          const text = labels ? labels[i] : host.children[i].firstChild;
          text.data = cellText(record);
        }
      }
      if (i < records.length || i < next.length) reconcileSuffix(next, i);
      records = next;
    },
    dispose() {
      if (!records) return;
      host.replaceChildren();
      records = null;
      if (labels) labels.length = 0;
    },
  };
}

export function mountTextBand(host, records) {
  return mountBand(host, records, []);
}

export function mountDomBand(host, records) {
  return mountBand(host, records, null);
}
