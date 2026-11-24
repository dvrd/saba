import { batch, keyed, mount, signal } from "/__saba/dom.js";

export function mountOperations(api) {
  const rows = signal([]), status = signal("idle"), more = signal(false);
  function Row({ record }) {
    const open = () => api.activate(record().source);
    return (
      <tr
        class={record().selected ? "row-link is-selected" : "row-link"}
        tabindex="0"
        aria-selected={record().selected}
        onClick={open}
        onKeyDown={(event) => api.key(event, open)}
      >
        {api.columns.map((_, i) => <td>{record().cells[i]}</td>)}
      </tr>
    );
  }
  function Rows() {
    return (
      <>
        {keyed(rows, (r) => r.source.id, (record) => <Row record={record} />)}
        {rows().length === 0 && (
          <tr>
            <td colspan={api.columns.length}>{api.text("table.empty")}</td>
          </tr>
        )}
      </>
    );
  }
  function Controls() {
    return (
      <>
        <p role="status">{api.status(status())}</p>
        {(status() === "ready" || status() === "error") &&
          (
            <button type="button" onClick={api.refresh}>
              {api.text(status() === "error" ? "Reintentar" : "Recargar")}
            </button>
          )}
        {status() === "ready" && more() && (
          <button type="button" onClick={api.more}>{api.text("Cargar más")}</button>
        )}
      </>
    );
  }
  const disposeRows = mount(api.body, Rows), disposeControls = mount(api.controls, Controls);
  return {
    update(model) {
      batch(() => {
        rows.set(model.rows);
        status.set(model.state);
        more.set(model.more);
      });
    },
    dispose() {
      disposeRows();
      disposeControls();
    },
  };
}
