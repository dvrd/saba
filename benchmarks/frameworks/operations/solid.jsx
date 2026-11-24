import { createSignal, For, Show } from "solid-js";
import { render } from "@solidjs/web";

export function mountOperations(api) {
  const [model, update] = createSignal({ rows: [], state: "idle", more: false });
  const rows = () => model().rows, status = () => model().state, more = () => model().more;
  function Row(props) {
    const open = () => api.activate(props.record().source);
    return (
      <tr
        class={props.record().selected ? "row-link is-selected" : "row-link"}
        tabindex="0"
        aria-selected={String(props.record().selected)}
        onClick={open}
        onKeyDown={(event) => api.key(event, open)}
      >
        {api.columns.map((_, i) => <td>{props.record().cells[i]}</td>)}
      </tr>
    );
  }
  function Rows() {
    return (
      <For
        each={rows()}
        keyed={(r) => r.source.id}
        fallback={
          <tr>
            <td colspan={api.columns.length}>{api.text("table.empty")}</td>
          </tr>
        }
      >
        {(record) => <Row record={record} />}
      </For>
    );
  }
  function Controls() {
    return (
      <>
        <p role="status">{api.status(status())}</p>
        <Show when={status() === "ready" || status() === "error"}>
          <button type="button" onClick={api.refresh}>
            {api.text(status() === "error" ? "Reintentar" : "Recargar")}
          </button>
        </Show>
        <Show when={status() === "ready" && more()}>
          <button type="button" onClick={api.more}>{api.text("Cargar más")}</button>
        </Show>
      </>
    );
  }
  const disposeRows = render(Rows, api.body), disposeControls = render(Controls, api.controls);
  return {
    update,
    dispose() {
      disposeRows();
      disposeControls();
    },
  };
}
