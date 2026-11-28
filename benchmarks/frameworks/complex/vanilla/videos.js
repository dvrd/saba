import { mountKeyed } from './list.js';

export const mountBand = mountKeyed(
  (row) => {
    const element = document.createElement('video');
    element.preload = 'none';
    element.setAttribute('src', row.src);
    element.setAttribute('data-id', row.id);
    return { element, record: row };
  },
  (cell, row) => {
    if (cell.element.getAttribute('src') !== row.src) cell.element.setAttribute('src', row.src);
  },
);
