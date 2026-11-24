import { keyed, mount, signal } from '/__saba/dom.js';

function Row(record) {
  return <div class="card" data-id={record().id}>{record().author.name + ' · ' + record().score}</div>;
}

export function mountBand(host, records) {
  const rows = signal(records);
  const list = keyed(rows, record => record.id, Row);
  const dispose = mount(host, () => <>{list}</>);
  return { replace: rows.set, dispose };
}
