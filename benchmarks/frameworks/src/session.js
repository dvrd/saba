// Each view keeps its draft, confirmed record, lists and render milestones in
// native framework state. Share only the request and editor lifetime protocol.
import { fail, readViews, saveTitle } from './transport.js';

export function editorSession(view) {
  let active = false;
  let generation = 0;
  let editVersion = 0;
  let pending = false;
  let listsReady = false;

  function refresh(initial, submittedVersion) {
    const read = ++generation;
    return readViews(
      record => {
        if (read !== generation) return;
        view.detail(record, initial || editVersion === submittedVersion, initial);
      },
      (index, rows) => {
        if (read === generation) view.list(index, rows);
      },
      () => {
        if (read === generation && !listsReady) {
          listsReady = true;
          view.listsReady();
        }
      },
    );
  }

  return {
    start() {
      active = true;
      refresh(true, editVersion).catch(error => { if (active) fail(error); });
    },
    dispose() {
      active = false;
      generation++;
    },
    edit(value) {
      editVersion++;
      view.draft(value);
    },
    async submit(event, draft, confirmed) {
      event.preventDefault();
      if (!active || pending || !confirmed || draft === confirmed.title) return;
      performance.mark('mesa-save-start');
      pending = true;
      view.saving(true);
      const submittedVersion = editVersion;
      try {
        const reply = await saveTitle(draft, confirmed.revision);
        if (!active) return;
        if (reply.id !== confirmed.id || reply.revision !== confirmed.revision + 1) {
          throw Error('Unexpected save acknowledgement');
        }
        await refresh(false, submittedVersion);
        if (!active) return;
        pending = false;
        view.saving(false);
        view.saved(reply.revision);
      } catch (error) {
        if (active) fail(error);
      }
    },
  };
}
