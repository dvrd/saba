import { memo } from 'react';
import { flushSync } from 'react-dom';
import { createRoot } from 'react-dom/client';

export const kind = 'keyed';

const Tile = memo(function Tile({ record }) {
  return <div className="cell" data-id={record.id}>{record.id + ' · ' + record.score}</div>;
});

function Band({ records }) {
  return records.map(record => <Tile key={record.id} record={record} />);
}

export function mountBand(host, records) {
  const root = createRoot(host);
  const replace = next => flushSync(() => root.render(<Band records={next} />));
  replace(records);
  return { replace, dispose() { root.unmount(); } };
}
