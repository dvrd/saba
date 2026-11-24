import { createSignal, flush, For } from 'solid-js';
import { render } from '@solidjs/web';

function Tile(props) {
  return <div class="cell" data-id={props.record.id}>{props.record.id + ' · ' + props.record.score}</div>;
}

export function mountScaleBand(host, initialRecords) {
  let setRecords;
  const dispose = render(() => {
    const [records, write] = createSignal(initialRecords);
    setRecords = write;
    return <For each={records()} keyed={record => record.id}>{record => <Tile record={record()}/>}</For>;
  }, host);
  flush();
  return {replace(records) { setRecords(records); flush(); }, dispose};
}
