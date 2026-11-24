import { keyed, mount, signal } from '/__saba/dom.js';

function Row(record) {
  return <div class="card" data-id={record().id}><img src={record().src} alt={record().label} /><span>{record().label + ' · ' + record().score}</span><input type="checkbox" checked={record().on} /></div>;
}

export function mountBand(host, records) {
  const rows = signal(records);
  const list = keyed(rows, record => record.id, Row);
  const dispose = mount(host, () => <>{list}</>);
  return { replace: rows.set, dispose };
}
