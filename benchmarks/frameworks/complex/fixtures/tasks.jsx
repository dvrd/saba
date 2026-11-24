import { keyed, mount, signal } from '/__saba/dom.js';

function Task(record) {
  return <div class="task" data-id={record().id}>{record().id + ' · ' + record().label}</div>;
}

export function mountTasks(host, records) {
  const rows = signal(records);
  const list = keyed(rows, record => record.id, Task);
  const dispose = mount(host, () => <>{list}</>);
  return { replace: rows.set, dispose };
}
