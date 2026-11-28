import { createSignal, flush, For } from 'solid-js';
import { render } from '@solidjs/web';

export const kind = 'keyed';

export function mountBand(host, records) {
  let setRecords;
  const dispose = render(() => {
    const [rows, write] = createSignal(records);
    setRecords = write;
    return <For each={rows()} keyed={record => record.id}>{record =>
      <div class="cell" data-id={record().id}>{record().id + ' · ' + record().score}</div>
    }</For>;
  }, host);
  flush();
  return {
    replace(next) {
      setRecords(next);
      flush();
    },
    dispose,
  };
}
