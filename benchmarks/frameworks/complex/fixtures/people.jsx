import { keyed, mount, signal } from '/__saba/dom.js';

function Person(record) {
  return <div class="person" data-id={record().id}>{record().id + ' · ' + record().label}</div>;
}

export function mountPeople(host, records) {
  const rows = signal(records);
  const list = keyed(rows, record => record.id, Person);
  const dispose = mount(host, () => <>{list}</>);
  return { replace: rows.set, dispose };
}
