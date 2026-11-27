// The checkout path builds its screen with Saba's real JSX runtime and mount.
import { api, jsx, mount, onCleanup, run } from "/__saba/dom.js";
import { captions, runEditor, views } from "./app.js";

function currentRow(record) {
  const node = jsx("li", { "data-id": record.id }, record.title);
  const text = node.firstChild;
  return {
    node,
    update(next) {
      if (text.data !== next.title) text.data = next.title;
    },
    dispose() {},
  };
}

function Page() {
  const input = jsx("input", {
    id: "title", name: "title", disabled: true, autocomplete: "off", spellcheck: "false",
  });
  const button = jsx("button", { id: "save", type: "submit", disabled: true }, "Save");
  const preview = jsx("output", { id: "preview", for: "title" }, " ");
  const status = jsx("p", { id: "status", role: "status" }, "Loading item…");
  const editor = jsx("form", { id: "editor" },
    jsx("label", { for: "title" }, "Item 42"),
    jsx("div", { class: "fields" }, input, button), preview, status);
  const lists = views.map(view => jsx("ol", { id: "list-" + view }));
  const panels = lists.map((list, index) => jsx("section", {}, jsx("h2", {}, captions[index]), list));

  const text = preview.firstChild;
  const controls = {
    update(title, ready, canSave) {
      if (input.value !== title) input.value = title;
      if (text.data !== title) text.data = title;
      if (input.disabled !== !ready) input.disabled = !ready;
      if (button.disabled !== !canSave) button.disabled = !canSave;
    },
    dispose() {},
  };
  let stop;
  run(() => { stop = runEditor(api, { input, editor, status, lists }, controls, currentRow); });
  onCleanup(() => stop?.());
  return jsx("section", { class: "screen" }, jsx("h1", {}, "Items"), editor,
    jsx("div", { class: "lists" }, panels));
}

const unmount = mount(document.querySelector("#app"), Page);
addEventListener("pagehide", event => { if (!event.persisted) unmount(); });
