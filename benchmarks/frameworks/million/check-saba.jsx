import { keyed, mount, signal } from '/__saba/dom.js';

export const kind = 'checkbox';

function Box(record) {
  return <input type="checkbox" checked={record().on} data-id={record().id} />;
}

export function mountBand(host, records) {
  const rows = signal(records);
  const list = keyed(rows, record => record.id, Box);
  const dispose = mount(host, () => <>{list}</>);
  return { replace: rows.set, dispose };
}
