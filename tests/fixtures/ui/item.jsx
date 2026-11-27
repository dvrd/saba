import { effect, lifetime, onCleanup, ref, run, signal } from "/__saba/dom.js";
import { createEditor } from "/__saba/editor.js";
import { createMutationPartition, itemTransport } from "/__saba/mutations.js";
import { driveHistory, initialIdentity, reportFailure, testIdentity, historyTransport } from "./history-helper.js";

export const title = "Edit item";

export default function ItemPage(props) {
  const item = props.params.id;
  const controls = ref("controls");
  const owner = lifetime().abort;
  const editor = signal(null);
  let partition;
  onCleanup(() => partition?.retire());
  run(() => {
    effect(() => { controls.current.disabled = !editor()?.editable(); });
    async function start() {
      const identity = await initialIdentity();
      if (owner.aborted) return;
      partition = createMutationPartition({...identity, transport: historyTransport(itemTransport())});
      const instance = createEditor({partition, item, fields: ["title"], verifyIdentity: testIdentity, owner});
      editor.set(instance);
      await driveHistory(instance, item);
    }
    start().catch(reportFailure);
  });

  return <form onSubmit={event => { event.preventDefault(); editor()?.submit(event); }}>
    <h1>Edit item</h1>
    <fieldset disabled ref={controls}>
      <legend>Item details</legend>
      <label htmlFor={editor()?.fieldId("title")}>Title</label>
      <input name="title" id={editor()?.fieldId("title")} value={editor()?.field("title")}
        onInput={event => editor()?.edit("title", event.currentTarget.value)}
        aria-invalid={Boolean(editor()?.error("title"))}
        aria-describedby={editor()?.describedBy("title", "title-help")}/>
      <small id="title-help">Use the item name.</small>
      <span id={editor()?.errorId("title")}>{editor()?.error("title")}</span>
      <button type="submit" disabled={!editor()?.canSave()}>Save</button>
    </fieldset>
    <output aria-live="polite">{editor()?.message()}</output>
  </form>;
}
