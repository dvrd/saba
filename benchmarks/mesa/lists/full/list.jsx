import {keyed} from "/__saba/dom.js";

function renderRow(record) {
  const id = record().id;
  return <li data-id={id}>{record().title}</li>;
}

export function List(props) {
  return <ol id={"list-" + props.view} aria-labelledby={"heading-" + props.view}>
    {keyed(() => props.resource.state().value || [], record => record.id, renderRow)}
  </ol>;
}
