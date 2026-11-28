import { Component, render } from 'preact';

export const kind = 'keyed';

// Preact core bailout. preact/compat also exports memo, and that module pulls
// in the whole compatibility layer. This wrapper is the reconciler bailout
// itself: skip the tile when the record reference is unchanged.
function memo(Inner) {
  return class Memo extends Component {
    shouldComponentUpdate(next) {
      const prev = this.props;
      for (const key in prev) if (prev[key] !== next[key]) return true;
      for (const key in next) if (!(key in prev)) return true;
      return false;
    }
    render(props) {
      return <Inner {...props} />;
    }
  };
}

const Tile = memo(function Tile({ record }) {
  return <div class="cell" data-id={record.id}>{record.id + ' · ' + record.score}</div>;
});

function Band({ records }) {
  return records.map(record => <Tile key={record.id} record={record} />);
}

export function mountBand(host, records) {
  const replace = next => render(<Band records={next} />, host);
  replace(records);
  return { replace, dispose() { render(null, host); } };
}
