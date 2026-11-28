import { mountSlotWindow, scalarRecord } from '/__saba/slot-window.js';

function Tile(record) {
  return <div class="cell" data-id={record().id}>{record().id + ' · ' + record().score}</div>;
}

export function mountScaleBand(host, initialRecords, first, markSnapshotsReady) {
  const view = mountSlotWindow(host, Tile);
  // All arms receive the same immutable model. Keep snapshots only for the
  // current band and include conversion in the timed renderer call.
  let previous = new Map();
  function replace(records, first) {
    const current = new Map();
    const snapshots = records.map(record => {
      const snapshot = previous.get(record) ?? scalarRecord(record);
      current.set(record, snapshot);
      return snapshot;
    });
    markSnapshotsReady?.();
    view.replace(first, snapshots);
    previous = current;
  }
  replace(initialRecords, first);
  return { replace, dispose: view.dispose };
}
