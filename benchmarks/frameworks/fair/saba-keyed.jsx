import { keyed, mount, signal } from '/__saba/dom.js';

export const kind = 'keyed';

function Tile(record) {
  return <div class="cell" data-id={record().id}>{record().id + ' · ' + record().score}</div>;
}

export function mountBand(host, records) {
  const rows = signal(records);
  const list = keyed(rows, record => record.id, Tile);
  const dispose = mount(host, () => <>{list}</>);
  return { replace: rows.set, dispose };
}
