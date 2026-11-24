export const views = ["all", "open", "marked"];
export const captions = ["All items", "Open", "Marked"];

// Both implementations receive identical snapshots, preserve rows by ID and
// change order only when the corresponding DOM order actually changes.
function listRenderer(list, createRow) {
  let previous = new Map();
  return {
    apply(records) {
      const next = new Map();
      for (const record of records) {
        if (typeof record.id !== "string" || next.has(record.id)) {
          throw new Error("Invalid or duplicate row key");
        }
        next.set(record.id, previous.get(record.id));
      }

      const initial = previous.size === 0 ? document.createDocumentFragment() : null;
      let cursor = list.firstElementChild;
      for (const record of records) {
        let row = next.get(record.id);
        if (!row) {
          row = createRow(record);
          next.set(record.id, row);
        } else {
          row.update(record);
        }
        if (initial) initial.append(row.node);
        else if (cursor !== row.node) list.insertBefore(row.node, cursor);
        cursor = row.node.nextElementSibling;
      }
      for (const [key, row] of previous) {
        if (!next.has(key)) {
          row.dispose();
          row.node.remove();
        }
      }
      if (initial) list.append(initial);
      previous = next;
    },
    dispose() {
      for (const row of previous.values()) row.dispose();
      previous.clear();
    },
  };
}

export function runEditor(api, target, controls, createRow, journal) {
  const owner = new AbortController();
  const lists = target.lists.map(list => listRenderer(list, createRow));
  let confirmed;
  let draft = "";
  let editVersion = 0;
  let saving = false;
  let generation = 0;

  function showControls() {
    controls.update(draft, Boolean(confirmed), Boolean(confirmed && !saving && draft !== confirmed.title));
  }

  function showMilestone(id, label) {
    const marker = document.createElement("span");
    marker.setAttribute("elementtiming", id);
    marker.textContent = label;
    target.status.replaceChildren(marker);
  }

  function failure(error) {
    if (owner.signal.aborted) return;
    target.status.textContent = error.message;
    document.documentElement.dataset.failure = error.message;
    console.error(error);
  }

  function readAll(initial, submittedVersion) {
    const read = ++generation;
    const options = { abort: owner.signal };
    const detail = api("/api/items/42", options).then(record => {
      if (generation !== read) return;
      confirmed = record;
      if (initial || editVersion === submittedVersion) draft = record.title;
      target.editor.dataset.revision = String(record.revision);
      showControls();
      if (initial) {
        showMilestone("mesa-ready", "Ready");
        performance.mark("mesa-editable");
      }
    });
    const collections = Promise.all(views.map(async (view, index) => {
      const rows = await api("/api/lists/" + view, options);
      if (generation === read) lists[index].apply(rows);
    })).then(() => {
      if (initial && generation === read) performance.mark("mesa-lists-ready");
    });
    return Promise.all([detail, collections]);
  }

  target.input.addEventListener("input", () => {
    draft = target.input.value;
    editVersion++;
    showControls();
  }, { signal: owner.signal });

  target.editor.addEventListener("submit", async event => {
    event.preventDefault();
    if (!confirmed || saving || confirmed.title === draft) return;
    performance.mark("mesa-save-start");
    saving = true;
    showControls();
    const submittedVersion = editVersion;
    const operationId = crypto.randomUUID();
    try {
      journal?.begin(operationId);
      const acknowledgement = await api("/api/items/42", {
        method: "PATCH", abort: owner.signal,
        body: { operationId, expectedRevision: confirmed.revision, title: draft },
      });
      if (acknowledgement.id !== "42" || acknowledgement.revision !== confirmed.revision + 1) {
        throw new Error("Unexpected save acknowledgement");
      }
      journal?.settle(operationId);
      await readAll(false, submittedVersion);
      if (owner.signal.aborted) return;
      saving = false;
      showControls();
      showMilestone("mesa-saved", "Saved");
      performance.mark("mesa-fresh");
    } catch (error) { failure(error); }
  }, { signal: owner.signal });

  readAll(true).catch(failure);
  return () => {
    owner.abort();
    controls.dispose();
    for (const list of lists) list.dispose();
  };
}
