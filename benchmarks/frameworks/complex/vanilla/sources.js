import { mountKeyed } from './list.js';

const textOf = (row) => row.id + ' · ' + row.label;

const band = (className) => mountKeyed(
  (row) => {
    const element = document.createElement('div');
    element.className = className;
    element.setAttribute('data-id', row.id);
    element.append(document.createTextNode(textOf(row)));
    return { element, record: row };
  },
  (cell, row) => {
    const value = textOf(row);
    if (cell.element.firstChild.data !== value) cell.element.firstChild.data = value;
  },
);

export function mountPage(host, people, tasks) {
  const peopleHost = document.createElement('div');
  const tasksHost = document.createElement('div');
  host.append(peopleHost, tasksHost);
  const peopleBand = band('person')(peopleHost, people);
  const tasksBand = band('task')(tasksHost, tasks);
  return {
    replace(nextPeople, nextTasks) {
      peopleBand.replace(nextPeople);
      tasksBand.replace(nextTasks);
    },
    dispose() {
      peopleBand.dispose();
      tasksBand.dispose();
      host.replaceChildren();
    },
  };
}
