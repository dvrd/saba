// Hand-written floor for a stable list of checkboxes. Mount builds one
// fragment. Later replaces of the same length write the checked property.
export const kind = 'checkbox';

function create(row) {
  const element = document.createElement('input');
  element.setAttribute('type', 'checkbox');
  element.checked = row.on;
  element.setAttribute('data-id', row.id);
  return element;
}

export function mountBand(host, records) {
  let boxes = [];
  function replace(next) {
    if (boxes.length !== next.length) {
      const fragment = document.createDocumentFragment();
      const created = new Array(next.length);
      for (let i = 0; i < next.length; i++) {
        const element = create(next[i]);
        created[i] = element;
        fragment.append(element);
      }
      host.replaceChildren(fragment);
      boxes = created;
      return;
    }
    for (let i = 0; i < next.length; i++) {
      const row = next[i];
      const element = boxes[i];
      const on = row.on;
      if (element.checked !== on) element.checked = on;
    }
  }
  replace(records);
  return {
    replace,
    dispose() {
      host.replaceChildren();
      boxes = [];
    },
  };
}
