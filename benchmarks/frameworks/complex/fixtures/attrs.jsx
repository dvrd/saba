import { keyed, mount, signal } from '/__saba/dom.js';

function Row(record) {
  return <div class="card" data-id={record().id} data-key={record().id} data-score={record().score} title={record().label + ' · ' + record().score}>{record().label + ' · ' + record().score}</div>;
}

export function mountBand(host, records) {
  const rows = signal(records);
  const list = keyed(rows, record => record.id, Row);
  const dispose = mount(host, () => <>{list}</>);
  return { replace: rows.set, dispose };
}
