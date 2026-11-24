import { mountKeyed } from './list.js';

const textOf = (row) => row.label + ' · ' + row.score;

export const mountBand = mountKeyed(
  (row) => {
    const element = document.createElement('div');
    element.className = 'card';
    element.setAttribute('data-id', row.id);
    element.setAttribute('data-key', row.id);
    element.setAttribute('data-score', row.score);
    element.setAttribute('title', textOf(row));
    element.append(document.createTextNode(textOf(row)));
    return { element, record: row };
  },
  (cell, row) => {
    const value = textOf(row);
    cell.element.setAttribute('data-score', row.score);
    cell.element.setAttribute('title', value);
    if (cell.element.firstChild.data !== value) cell.element.firstChild.data = value;
  },
);
