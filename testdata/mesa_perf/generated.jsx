import {api, effect, onCleanup, ref, run, signal} from "/__saba/dom.js";
import {createEditor} from "/__saba/editor.js";
import {createMutationPartition, itemTransport} from "/__saba/mutations.js";
import {createReadPartition} from "/__saba/reads.js";

import {List} from "./list.js";

export const title = "Mesa item editor";

export default function Page() {
  const status = ref("status");
  const revision = signal(0);
  const transport = itemTransport();
  const reads = createReadPartition(([kind, view], abort) => api("/api/lists/" + view, {abort}),
    {familyFor: () => "items"});
  const resources = ["all", "open", "marked"].map(view => reads.read(["list", view]));
  let listsAfterSave;
  const partition = createMutationPartition({
    session: "benchmark", tenant: "fixture", transport: {
      ...transport,
      async read(item, abort) {
        const result = await transport.read(item, abort);
        if (result.status === 200) revision.set(result.body.revision);
        return result;
      }
    },
    onCommitted(item, record) { listsAfterSave = reads.confirm(["item", item], record); }
  });
  const editor = createEditor({partition, item: "42", fields: ["title"]});
  onCleanup(() => { reads.dispose(); partition.retire(); });

  function failure(error) {
    document.documentElement.dataset.failure = String(error?.message || error);
  }
  function show(id, label) {
    const marker = document.createElement("span");
    marker.setAttribute("elementtiming", id);
    marker.textContent = label;
    status.current.replaceChildren(marker);
  }
  run(() => {
    let listsMeasured = false;
    effect(() => {
      const snapshots = resources.map(resource => resource.state());
      for (const state of snapshots) if (state.status === "error") failure(state.error);
      if (!listsMeasured && snapshots.every(state => state.status === "ready")) {
        listsMeasured = true;
        queueMicrotask(() => performance.mark("mesa-lists-ready"));
      }
    });
    editor.open().then(ready => {
      if (!ready) throw Error("Could not open editor: " + editor.status());
      show("mesa-ready", "Ready");
      performance.mark("mesa-editable");
    }).catch(failure);
  });
  async function submit(event) {
    performance.mark("mesa-save-start");
    try {
      const result = await editor.submit(event);
      if (result?.kind !== "saved") throw Error("Unexpected save outcome: " + result?.kind);
      const [detail] = await Promise.all([editor.refresh(), listsAfterSave]);
      if (!detail || !resources.every(resource => resource.state().status === "ready")) {
        throw Error("Confirmed detail or lists unavailable");
      }
      show("mesa-saved", "Saved");
      performance.mark("mesa-fresh");
    } catch (error) { failure(error); }
  }
  return <main>
    <link rel="stylesheet" href="/style.css"/>
    <section className="screen">
      <h1>Items</h1>
      <form id="editor" data-revision={revision()} onSubmit={submit}>
        <label htmlFor="title">Item 42</label>
        <div className="fields"><input id="title" name="title" disabled={!editor.editable()}
          autoComplete="off" spellCheck="false" value={editor.field("title")}
          onInput={event => editor.edit("title", event.currentTarget.value)}/>
          <button id="save" type="submit" disabled={!editor.canSave()}>Save</button></div>
        <output id="preview" htmlFor="title">{editor.field("title")}</output>
        <p id="status" role="status" ref={status}>Loading item…</p>
      </form>
      <div className="lists">
        <section><h2 id="heading-all">All items</h2><List view="all" resource={resources[0]}/></section>
        <section><h2 id="heading-open">Open</h2><List view="open" resource={resources[1]}/></section>
        <section><h2 id="heading-marked">Marked</h2><List view="marked" resource={resources[2]}/></section>
      </div>
    </section>
  </main>;
}
