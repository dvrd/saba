import { mountKeyed } from './list.js';

const textOf = (row) => row.label + ' · ' + row.score;

export const mountBand = mountKeyed(
  (row) => {
    const element = document.createElement('div');
    element.className = 'card';
    element.setAttribute('data-id', row.id);
    const image = document.createElement('img');
    image.alt = row.label;
    image.setAttribute('src', row.src);
    const span = document.createElement('span');
    const text = document.createTextNode(textOf(row));
    span.append(text);
    const box = document.createElement('input');
    box.type = 'checkbox';
    box.checked = row.on;
    element.append(image, span, box);
    return { element, image, text, box, record: row };
  },
  (cell, row) => {
    if (cell.image.getAttribute('src') !== row.src) cell.image.setAttribute('src', row.src);
    if (cell.image.alt !== row.label) cell.image.alt = row.label;
    const value = textOf(row);
    if (cell.text.data !== value) cell.text.data = value;
    if (cell.box.checked !== row.on) cell.box.checked = row.on;
  },
);
