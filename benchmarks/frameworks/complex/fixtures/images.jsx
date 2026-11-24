import { keyed, mount, signal } from '/__saba/dom.js';

function Row(record) {
  return <img src={record().src} alt={record().label} data-id={record().id} />;
}

export function mountBand(host, records) {
  const rows = signal(records);
  const list = keyed(rows, record => record.id, Row);
  const dispose = mount(host, () => <>{list}</>);
  return { replace: rows.set, dispose };
}
