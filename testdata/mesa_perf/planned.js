// Hand-authored output for the measured reactive design slice. The production
// compiler, generalized scheduler and operation recovery are outside this fixture.
import { api } from "/__saba/dom.js";
import { runEditor, views } from "./app.js";

let tracking = null;

function signal(initial) {
  let value = initial;
  const effects = new Set();
  return {
    read() {
      if (tracking) {
        effects.add(tracking);
        tracking.dependencies.add(effects);
      }
      return value;
    },
    write(next) {
      if (Object.is(value, next)) return;
      value = next;
      for (const effect of [...effects]) effect.run();
    },
  };
}

function effect(callback) {
  const owner = {
    dependencies: new Set(),
    dispose() {
      for (const subscribers of owner.dependencies) subscribers.delete(owner);
      owner.dependencies.clear();
    },
    run() {
      owner.dispose();
      const outer = tracking;
      tracking = owner;
      try { callback(); }
      finally { tracking = outer; }
    },
  };
  owner.run();
  return owner;
}

function plannedRow(record) {
  const item = signal(record);
  const node = document.createElement("li");
  node.dataset.id = record.id;
  const label = document.createTextNode("");
  node.append(document.createComment("title"), label, document.createComment("/title"));
  const binding = effect(() => {
    const title = item.read().title;
    if (label.data !== title) label.data = title;
  });
  return { node, update: item.write, dispose: binding.dispose };
}

function locate(scope, selector, tag) {
  const matches = scope.querySelectorAll(selector);
  if (matches.length !== 1 || matches[0].localName !== tag) {
    throw new Error("Invalid template target " + selector);
  }
  return matches[0];
}

function preflight() {
  const shell = locate(document, "#app > [data-template='editor-v1']", "section");
  const editor = locate(shell, "#editor", "form");
  const input = locate(editor, "#title", "input");
  const button = locate(editor, "#save", "button");
  const preview = locate(editor, "#preview", "output");
  const status = locate(editor, "#status", "p");
  const lists = views.map(view => locate(shell, "#list-" + view, "ol"));
  const [start, text, end] = preview.childNodes;
  if (preview.childNodes.length !== 3 || start?.nodeType !== Node.COMMENT_NODE ||
      start.data !== "draft" || text?.nodeType !== Node.TEXT_NODE ||
      end?.nodeType !== Node.COMMENT_NODE || end.data !== "/draft") {
    throw new Error("Invalid draft binding range");
  }
  return { input, button, text, status, editor, lists };
}

function editorControls({ input, button, text }) {
  const draft = signal("");
  const enabled = signal(false);
  const dirty = signal(false);
  const bindings = [
    effect(() => {
      const title = draft.read();
      if (input.value !== title) input.value = title;
    }),
    effect(() => {
      const title = draft.read();
      if (text.data !== title) text.data = title;
    }),
    effect(() => { input.disabled = !enabled.read(); }),
    effect(() => { button.disabled = !dirty.read(); }),
  ];
  return {
    update(title, ready, canSave) {
      draft.write(title);
      enabled.write(ready);
      dirty.write(canSave);
    },
    dispose() {
      for (const binding of bindings) binding.dispose();
    },
  };
}

const journal = {
  begin(id) { sessionStorage.setItem("mesa-perf:item:42:" + id, id); },
  settle(id) { sessionStorage.removeItem("mesa-perf:item:42:" + id); },
};
const targets = preflight();
const stop = runEditor(api, targets, editorControls(targets), plannedRow, journal);
addEventListener("pagehide", event => { if (!event.persisted) stop(); });
