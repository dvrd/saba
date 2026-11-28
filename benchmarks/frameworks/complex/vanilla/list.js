export function mountKeyed(create, write) {
  return function mountBand(host, records) {
    const cells = new Map();
    function replace(next) {
      const seen = new Set();
      for (let i = 0; i < next.length; i++) {
        const id = next[i].id;
        if (!Number.isFinite(id) || seen.has(id)) throw new Error('Bad row key ' + id);
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
        const row = next[i];
        let cell = cells.get(row.id);
        if (!cell) {
          cell = create(row);
          cells.set(row.id, cell);
        } else if (cell.record !== row) {
          write(cell, row);
          cell.record = row;
        }
        const element = cell.element;
        if (element.parentNode !== host) host.insertBefore(element, before);
        else if (element.nextSibling !== before) {
          if (typeof host.moveBefore === 'function') host.moveBefore(element, before);
          else host.insertBefore(element, before);
        }
        before = element;
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
  };
}
