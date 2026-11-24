// Keep upstream Desk, including its loader, route transitions, sort, filter,
// pagination and authorization behavior. Install a renderer only in live Operations.
export function withRenderer(original) {
  function replace(source, before, after) {
    if (source.split(before).length !== 2) {
      throw Error("Pinned Desk integration point changed: " + before);
    }
    return source.replace(before, after);
  }
  let source = 'import {mountOperations} from "/operations-renderer.js";\nlet operationsRenderer;\n' +
    original;
  source = replace(
    source,
    "  main.replaceChildren();",
    "  operationsRenderer?.dispose();\n  operationsRenderer = undefined;\n  main.replaceChildren();",
  );
  source = replace(
    source,
    "  appendLive();",
    `  if (current === "operaciones" && deskSnapshot === null && model.live) {
    const controls = document.createElement("section");
    controls.className = "card live-status";
    main.append(controls);
    operationsRenderer = mountOperations({
      body: document.getElementById("sheet-body"), controls, columns: model.columns,
      text: tx, activate,
      key(event, open) {
        if (event.key !== "Enter" && event.key !== " ") return;
        event.preventDefault(); open();
      },
      status(state) {
        if (state === "loading" || state === "idle") return t("Cargando…");
        if (state === "error") return t("No se pudo leer el libro.");
        return t("Datos guardados por el bot. Solo lectura.");
      },
      refresh: () => fetchLive(current, false, true),
      more: () => fetchLive(current, true)
    });
  } else appendLive();`,
  );
  source = replace(
    source,
    "  paintHead();\n  body.replaceChildren();",
    `  paintHead();
  if (operationsRenderer) {
    const visible = visibleRows();
    visiblePage = Math.min(visiblePage, Math.max(0, Math.ceil(visible.length / VISIBLE_ROWS_MAX) - 1));
    const first = visiblePage * VISIBLE_ROWS_MAX;
    const rows = visible.slice(first, first + VISIBLE_ROWS_MAX).map(source => ({
      source, selected: selected(source), cells: source.values.map(cell => tx(cell.text, cell.vars))
    }));
    operationsRenderer.update({rows, ...model.live});
    paintPager(visible.length);
    paintInspector();
    return;
  }
  body.replaceChildren();`,
  );
  source = replace(
    source,
    "  if (current === id) render();",
    `  const paintLive = () => {
    if (!operationsRenderer) { render(); return; }
    load(); searchText = new WeakMap(); visibleCache = null; paintSheet();
  };
  if (current === id) paintLive();`,
  );
  return replace(
    source,
    "  render();\n}\n\nfunction appendOrigin",
    "  paintLive();\n}\n\nfunction appendOrigin",
  );
}
