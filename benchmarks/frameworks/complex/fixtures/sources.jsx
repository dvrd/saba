import { keyed, mount, signal } from '/__saba/dom.js';

function Person(record) {
  return <div class="person" data-id={record().id}>{record().id + ' · ' + record().label}</div>;
}

function Task(record) {
  return <div class="task" data-id={record().id}>{record().id + ' · ' + record().label}</div>;
}

export function mountPeople(host, records) {
  const rows = signal(records);
  const list = keyed(rows, record => record.id, Person);
  const dispose = mount(host, () => <>{list}</>);
  return { replace: rows.set, dispose };
}

export function mountTasks(host, records) {
  const rows = signal(records);
  const list = keyed(rows, record => record.id, Task);
  const dispose = mount(host, () => <>{list}</>);
  return { replace: rows.set, dispose };
}

export function mountPage(host, people, tasks) {
  const peopleHost = document.createElement('div');
  const tasksHost = document.createElement('div');
  host.append(peopleHost, tasksHost);
  const peopleBand = mountPeople(peopleHost, people);
  const tasksBand = mountTasks(tasksHost, tasks);
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
