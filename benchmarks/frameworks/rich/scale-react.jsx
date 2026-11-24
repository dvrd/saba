import { memo } from 'react';
import { flushSync } from 'react-dom';
import { createRoot } from 'react-dom/client';

const Tile = memo(function Tile({record}) {
  return <div className="cell" data-id={record.id}>{record.id + ' · ' + record.score}</div>;
});

function Band({records}) {
  return records.map(record => <Tile key={record.id} record={record}/>);
}

export function mountScaleBand(host, initialRecords) {
  const root = createRoot(host);
  const replace = records => flushSync(() => root.render(<Band records={records}/>));
  replace(initialRecords);
  return {replace, dispose:() => root.unmount()};
}
