// Position floor for a fixed window. Logical index owns the element.
// Overlapping indexes keep their node. Changed id or score is one attribute
// write and one text write. No snapshots and no mutation observer.
import { allocate, place } from './recycle.js';

export const kind = 'slot';

function textOf(record) {
  return record.id + ' · ' + record.score;
}

export function mountBand(host, records, first = 0) {
  let slots = [];
  let start = 0;
  function makeSlot() {
    const element = document.createElement('div');
    element.className = 'cell';
    const text = document.createTextNode('');
    element.append(text);
    return { element, text, id: NaN, score: NaN };
  }
  function replace(next, nextFirst = 0) {
    const plan = allocate(slots, start, nextFirst, next.length, makeSlot);
    for (const slot of plan.retired) slot.element.remove();
    for (let i = 0; i < next.length; i++) {
      const record = next[i];
      const slot = plan.next[i];
      if (slot.id === record.id && slot.score === record.score) continue;
      if (slot.id !== record.id) {
        slot.element.setAttribute('data-id', String(record.id));
        slot.id = record.id;
      }
      const value = textOf(record);
      if (slot.text.data !== value) slot.text.data = value;
      slot.score = record.score;
    }
    place(host, plan);
    slots = plan.next;
    start = nextFirst;
  }
  replace(records, first);
  return {
    replace,
    dispose() {
      for (const slot of slots) slot.element.remove();
      slots = [];
    },
  };
}
