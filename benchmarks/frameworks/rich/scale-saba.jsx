import { keyed, mount, signal } from '/__saba/dom.js';

function Tile(record) {
  const id = record().id;
  return <div class="cell" data-id={id}>{id + ' · ' + record().score}</div>;
}

export function mountScaleBand(host, initialRecords) {
  const records = signal(initialRecords);
  const rows = keyed(records, record => record.id, Tile);
  const dispose = mount(host, () => <>{rows}</>);
  return { replace: records.set, dispose };
}
