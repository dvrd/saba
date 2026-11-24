import { mountKeyed } from './list.js';

const textOf = (row) => row.author.name + ' · ' + row.score;

export const mountBand = mountKeyed(
  (row) => {
    const element = document.createElement('div');
    element.className = 'card';
    element.setAttribute('data-id', row.id);
    element.append(document.createTextNode(textOf(row)));
    return { element, record: row };
  },
  (cell, row) => {
    const value = textOf(row);
    if (cell.element.firstChild.data !== value) cell.element.firstChild.data = value;
  },
);
