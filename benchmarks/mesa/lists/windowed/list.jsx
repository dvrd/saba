import {effect, keyed, onCleanup, ref, run, signal} from "/__saba/dom.js";
import {observeRowWindow} from "/__saba/sliding-window.js";

const rowHeight = 33;
const viewportStyle = {maxHeight: "45vh", overflow: "auto", margin: ".5rem 0"};
const listStyle = {position: "relative", maxHeight: "none", overflow: "visible", margin: 0};

function renderRow(item) {
  return <li data-id={item().record.id} aria-posinset={item().index + 1} aria-setsize={item().total}
    style={{position: "absolute", top: item().index * rowHeight + "px", width: "100%",
      height: rowHeight + "px", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis"}}>
    {item().record.title}
  </li>;
}

export function List(props) {
  const viewport = ref("viewport"), list = ref("list");
  const band = signal([0, 0]);
  run(() => {
    const window = observeRowWindow(viewport.current, {rowCount: 0, rowHeight}, (first, end) => {
      band.set([first, end]);
    });
    onCleanup(() => window.dispose());
    effect(() => {
      const count = props.resource.state().value?.length || 0;
      list.current.style.height = count * rowHeight + "px";
      window.setRowCount(count);
    });
  });

  function recordsInBand() {
    const records = props.resource.state().value || [];
    const [first, end] = band();
    return records.slice(first, end).map((record, offset) => ({
      record, index: first + offset, total: records.length
    }));
  }
  return <div id={"viewport-" + props.view} ref={viewport} tabIndex={0} role="region"
              aria-labelledby={"heading-" + props.view} style={viewportStyle}>
    <ol id={"list-" + props.view} ref={list} aria-labelledby={"heading-" + props.view} style={listStyle}>
      {keyed(recordsInBand, item => item.record.id, renderRow)}
    </ol>
  </div>;
}
