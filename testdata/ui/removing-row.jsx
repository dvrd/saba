import { keyed, mount, onCleanup, run, signal } from "/__saba/dom.js";
import { createReadPartition } from "/__saba/reads.js";
import { createMutationPartition, itemTransport } from "/__saba/mutations.js";
import { createEditor } from "/__saba/editor.js";

function check(test, message) { if (!test) throw new Error(message); }

export async function verifyDetachedSave(host) {
  const http = itemTransport();
  const initial = (await http.read("42")).body;
  const newTitle = "visible only after commit";
  const oldTitle = initial.title;
  const handles = [], ids = signal(["42"]), rowReady = Promise.withResolvers();
  const oldReadsReady = Promise.withResolvers(), sendFinished = Promise.withResolvers();
  const releaseOldReads = Promise.withResolvers(), loseReply = Promise.withResolvers();
  let holdReads = false, delayed = 0, patches = 0, receipts = 0, cleanups = 0, statusReads = 0;
  let refreshAfterCommit, submitted;
  const reads = createReadPartition(async (key, abort) => {
    const oldRead = holdReads;
    const reply = await http.read("42", abort);
    if (reply.status !== 200) throw new Error("list projection lost its authorized record");
    if (oldRead) {
      if (++delayed === 2) oldReadsReady.resolve();
      await releaseOldReads.promise; // Both decoded responses can still finish after invalidation.
    }
    return key[1] === reply.body.title ? [reply.body] : [];
  }, {familyFor: () => "items"});
  const partition = createMutationPartition({
    session: "detached-row", tenant: "demo", retryDelays: [],
    transport: {
      read: http.read,
      async patch(id, bytes, abort) {
        patches++;
        const reply = await http.patch(id, bytes, abort);
        check(reply.status === 200, "real save did not commit");
        sendFinished.resolve();
        await loseReply.promise;
        throw new Error("connection lost after commit");
      },
      receipt(id, operation, abort) { receipts++; return http.receipt(id, operation, abort); }
    },
    onCommitted(id, value) { refreshAfterCommit = reads.confirm(["item", id], value); }
  });

  function Search(props) {
    const resource = reads.read(["search", props.term]);
    handles.push(resource);
    return <ol id={props.listId}>{(resource.state().value || []).map(row => <li>{row.title}</li>)}</ol>;
  }
  function Row() {
    const editor = createEditor({partition, item: "42", fields: ["title"]});
    run(() => { editor.open().then(rowReady.resolve, rowReady.reject); });
    onCleanup(() => cleanups++);
    function status() { statusReads++; return editor.status(); }
    return <form id="removable-row" onSubmit={event => { submitted = editor.submit(event); }}>
      <input value={editor.field("title")} onInput={e => editor.edit("title", e.currentTarget.value)}/>
      <output>{status()}</output>
    </form>;
  }
  const dispose = mount(host, () => <section>
    <Search term={oldTitle} listId="old-members"/><Search term={newTitle} listId="new-members"/>
    {keyed(ids(), id => id, () => <Row/>)}
  </section>);
  try {
    await rowReady.promise;
    await Promise.all(handles.map(view => view.refresh()));
    const oldList = host.querySelector("#old-members"), newList = host.querySelector("#new-members");
    check(oldList.textContent === oldTitle && !newList.children.length, "unexpected initial query membership");
    holdReads = true;
    const stale = Promise.all(handles.map(view => view.refresh()));
    await oldReadsReady.promise;
    holdReads = false;
    const row = host.querySelector("#removable-row"), input = row.querySelector("input");
    input.value = newTitle;
    input.dispatchEvent(new Event("input", {bubbles: true}));
    row.requestSubmit();
    await sendFinished.promise;
    ids.set([]);
    const previousReads = statusReads, previousText = row.textContent;
    check(!row.isConnected && cleanups === 1, "submitting row did not dispose");
    loseReply.resolve();
    const result = await submitted;
    await refreshAfterCommit;
    releaseOldReads.resolve();
    await stale;
    check(result.kind === "saved" && patches === 1 && receipts === 1, "lost response did not settle exactly one operation by receipt");
    check(!oldList.children.length && newList.textContent === newTitle && newList.children.length === 1,
      "surviving search membership was stale after receipt revalidation");
    check(host.querySelector("#new-members") === newList && host.querySelector("#old-members") === oldList &&
      statusReads === previousReads && row.textContent === previousText && input.value === newTitle,
      "invalidating shared data rebuilt a surviving list or updated the disposed row");
    const final = (await http.read("42")).body;
    check(final.revision === initial.revision + 1 && final.title === newTitle, "unexpected durable effect count");
    return true;
  } finally {
    loseReply.resolve(); releaseOldReads.resolve();
    dispose(); reads.dispose(); partition.retire(true);
  }
}
