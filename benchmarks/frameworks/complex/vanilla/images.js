import { mountKeyed } from './list.js';

export const mountBand = mountKeyed(
  (row) => {
    const element = document.createElement('img');
    element.alt = row.label;
    element.setAttribute('src', row.src);
    element.setAttribute('data-id', row.id);
    return { element, record: row };
  },
  (cell, row) => {
    if (cell.element.getAttribute('src') !== row.src) cell.element.setAttribute('src', row.src);
    if (cell.element.alt !== row.label) cell.element.alt = row.label;
  },
);
