import { mountSlotWindow } from '/__saba/slot-window.js';

export const kind = 'slot';

function Tile(record) {
  return <div class="cell" data-id={record().id}>{record().id + ' · ' + record().score}</div>;
}

export function mountBand(host, records, first = 0) {
  const view = mountSlotWindow(host, Tile);
  const replace = (next, nextFirst = 0) => view.replace(nextFirst, next);
  replace(records, first);
  return { replace, dispose: view.dispose };
}
