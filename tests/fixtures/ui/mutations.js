import { createMutationPartition, itemTransport } from "/__saba/mutations.js";
import { createEditor } from "/__saba/editor.js";

function check(condition, message) {
  if (!condition) throw new Error(message);
}
function deferred() { return Promise.withResolvers(); }
const item = "42";
const identity = {session: "ui-test-session", tenant: "demo"};
const read = record => ({status: 200, body: {...record}});
const record = (revision, title, note = "") => ({id: item, revision, title, note});
const terminal = body => ({status: 200, body: {state: "terminal", status: 200, body}});
function factory(partition, extra = {}) {
  return createEditor({partition, item, owner: new AbortController().signal, fields: ["title", "note"], ...extra});
}

async function exerciseDrafts(host) {
  let serverRecord = record(7, "Lamp");
  const writes = [], replies = [];
  const transport = {
    async read() { return read(serverRecord); },
    patch(id, bytes) {
      check(id === item, "wrong PATCH item");
      writes.push(JSON.parse(bytes));
      const reply = deferred();
      replies.push(reply);
      return reply.promise;
    },
    async receipt() { throw new Error("unexpected recovery during direct save"); }
  };
  const partition = createMutationPartition({...identity, transport, retryDelays: []});
  const editor = factory(partition);
  const second = factory(partition);
  const form = document.createElement("form");
  const otherForm = document.createElement("form");
  const otherInput = document.createElement("input");
  otherForm.append(otherInput); host.append(otherForm);
  const input = document.createElement("input"), note = document.createElement("input");
  input.name = "title"; note.name = "note"; form.append(input, note); host.append(form);
  const submit = () => editor.submit({currentTarget: form, preventDefault() {}});
  try {
    editor.edit("title", "premature"); submit();
    check(editor.field("title") === "" && writes.length === 0, "input before first read was admitted");
    await Promise.all([editor.open(), second.open()]);
    check(editor.field("title") === "Lamp" && !editor.canSave(), "authorized clean initialization failed");
    check(editor.fieldId("title") !== second.fieldId("title"), "form instances share field identifiers");
    editor.edit("title", "dark");
    const saved = submit();
    check(saved === submit() && writes.length === 1 && writes[0].expectedRevision === 7, "double-submit issued two PATCH requests");
    editor.edit("title", "darker");
    serverRecord = record(8, "Dark");
    replies[0].resolve(read(serverRecord));
    await saved;
    check(editor.field("title") === "darker" && editor.canSave(), "newer local edits were lost");
    check(second.field("title") === "Dark", "clean sibling did not receive canonical data");
    const rejected = submit();
    input.focus(); note.focus();
    editor.edit("note", "updated during validation");
    replies[1].resolve({status: 422, body: {fieldErrors: {title: "unavailable"}}});
    await rejected;
    check(!editor.error("title") && document.activeElement === note, "stale cross-field error changed focus or fields");
    const current = submit();
    replies[2].resolve({status: 422, body: {fieldErrors: {title: "unavailable"}}});
    await current;
    check(editor.error("title") === "unavailable" && document.activeElement === input,
      "applicable error did not focus the first invalid control");
    check(editor.describedBy("title", "help") === "help " + editor.errorId("title"), "the error replaced a pre-existing description");
    editor.edit("note", "");
    check(!editor.error("title") && editor.describedBy("title", "help") === "help", "editing a validation dependency retained an obsolete error");
    const moved = submit();
    otherInput.focus();
    replies.at(-1).resolve({status: 422, body: {fieldErrors: {title: "already used", group: "Current form error"}}});
    await moved;
    check(document.activeElement === otherInput && editor.message() === "Current form error" && editor.error("title") === "already used",
      "a current rejection moved focus out of another form or dropped a form-wide message");
    const conflict = submit();
    serverRecord = record(9, "Someone else", "remote note");
    replies.at(-1).resolve({status: 409, body: {revision: 9}});
    await conflict;
    check(!editor.canSave() && editor.review().base.revision === 8 && editor.review().latest.revision === 9,
      "conflict did not expose the original and current revisions");
    const count = writes.length;
    check(!editor.resolveReview(8, ["title"]), "accepted stale conflict review");
    check(editor.resolveReview(9, ["title"]) && writes.length === count, "resolving review issued a write");
    check(editor.field("note") === "remote note" && editor.field("title") === "darker", "merge lost selected or server fields");
  } finally {
    editor.dispose(); second.dispose(); partition.retire(true); form.remove(); otherForm.remove();
  }
}

async function exerciseAccessAndSchema() {
  const transport = {read: async () => read(record(4, "private"))};
  let saves = 0, receipts = 0, commits = 0;
  transport.receipt = async () => { receipts++; return {status: 202}; };
  const config = {...identity, transport, retryDelays: [], onCommitted: () => commits++};
  const partition = createMutationPartition(config);
  let editor = factory(partition);
  try {
    await editor.open(); editor.edit("title", "unsent");
    transport.patch = async () => ({status: 409, body: {code: "client_update_required"}});
    await editor.submit();
    check(editor.status() === "update-required" && editor.field("title") === "unsent" && !editor.canSave(),
      "obsolete client discarded authorized edits or allowed a write");
    editor.dispose();

    editor = factory(partition);
    await editor.open(); editor.edit("title", "private draft");
    transport.read = async () => ({status: 503}); await editor.refresh();
    check(editor.status() === "read-error" && editor.canSave(), "transient refresh failure disabled an eligible draft");
    transport.read = async () => ({status: 404, body: {code: "item_deleted"}}); await editor.refresh();
    check(editor.status() === "deleted" && editor.field("title") === "private draft" && !editor.canSave(), "authorized deletion lost the draft or allowed a write");
    transport.read = async () => read(record(4, "private"));
    editor.dispose(); editor = factory(partition); await editor.open(); editor.edit("title", "outgoing");
    const late = deferred(); transport.patch = () => { saves++; return late.promise; };
    const old = editor.submit();
    transport.read = async () => ({status: 404}); await editor.refresh();
    late.resolve(read(record(5, "private outgoing"))); await old;
    check(editor.field("title") === "" && !editor.canSave() && !commits, "late success republished a revoked item");
    check(saves === 1, "access loss issued an extra mutation");
    editor.dispose();
    // Seed an unknown journal format using a real claim so the test does not
    // depend on the private key encoding.
    transport.read = async () => read(record(4, "private"));
    let gate = deferred(); transport.patch = () => gate.promise;
    const outstanding = partition.submit(item, {title: "value"}, 4);
    const key = Array.from({length: sessionStorage.length}, (_, i) => sessionStorage.key(i))
      .find(key => key.includes(outstanding.operationId));
    sessionStorage.setItem(key, "999");
    partition.retire(); gate.reject(new Error("disconnected"));
    await outstanding.outcome;
    const fresh = createMutationPartition(config);
    const freshEditor = factory(fresh);
    try {
      const count = receipts;
      await freshEditor.open(); freshEditor.edit("title", "new");
      check(!freshEditor.canSave() && !freshEditor.resolveReview(4) && sessionStorage.getItem(key) === "999",
        "unknown journal schema discarded a pointer or admitted a new write");
      check(receipts === count + 1, "fresh document looked up an unsupported operation or forgot its earlier unknown submission");
    } finally { freshEditor.dispose(); fresh.retire(true); }
  } finally { editor.dispose(); partition.retire(true); }
}

async function exerciseOutOfOrder() {
  let stored = record(7, "old");
  let readResult = () => read(stored);
  const writes = [], completions = [];
  const partition = createMutationPartition({...identity, retryDelays: [], transport: {
    read: async () => readResult(), receipt: async () => { throw new Error("unexpected receipt"); },
    patch(item, bytes) {
      const gate = deferred(); writes.push(JSON.parse(bytes)); completions.push(gate); return gate.promise;
    }
  }});
  const editor = factory(partition);
  try {
    await editor.open(); editor.edit("title", "submitted");
    const save = editor.submit();
    stored = record(9, "revision nine");
    await editor.refresh();
    editor.edit("title", "later");
    completions[0].resolve(read(record(8, "canonical eight"))); await save;
    check(editor.review().latest.revision === 9 && editor.review().base.revision === 8 && editor.field("title") === "later",
      "older acknowledgment replaced a newer revision or later draft");
    editor.resolveReview(9, ["title"]);
    const raced = editor.submit();
    readResult = () => ({status: 503});
    completions[1].resolve({status: 409, body: {revision: 10}}); await raced;
    check(!editor.resolveReview(9, ["title"]) && !editor.canSave(), "failed conflict refresh admitted a stale revision");
    readResult = () => read(record(10, "newer"));
    await editor.refresh();
    check(editor.resolveReview(10, ["title"]), "retry of the conflict refresh could not resolve");
    const collision = editor.submit();
    completions[2].resolve({status: 409, body: {code: "operation_id_reused"}}); await collision;
    check(editor.status() === "id-reused" && editor.field("title") === "later" && !editor.canSave() && writes.length === 3,
      "identifier collision acknowledged someone else's operation or retried");
  } finally { editor.dispose(); partition.retire(true); }
}

async function exerciseExplicitRetry() {
  const bytes = [];
  let receipt = {status: 202};
  const transport = {
    read: async () => read(record(7, "old")),
    async patch(_, body) {
      bytes.push(body);
      if (bytes.length === 1) throw new Error("reply lost");
      return read(record(8, "submitted"));
    },
    receipt: async () => receipt
  };
  const partition = createMutationPartition({...identity, transport, retryDelays: [], retentionMs: 60000});
  const editor = factory(partition);
  try {
    await editor.open(); editor.edit("title", "submitted");
    await editor.submit();
    editor.edit("title", "later");
    check(!editor.canSave() && bytes.length === 1, "uncertain save silently retried");
    await editor.retry();
    check(bytes.length === 2 && bytes[0] === bytes[1] && editor.field("title") === "later" && editor.canSave(),
      "explicit retry changed the operation or lost later edits");
    transport.patch = async () => { throw new Error("lost again"); };
    await editor.submit();
    receipt = terminal(record(9, "later"));
    await partition.reconcile(item);
    check(editor.status() === "saved" && editor.field("title") === "later" && !editor.canSave(),
      "a sibling receipt left the originating editor locked or dirty");
  } finally { editor.dispose(); partition.retire(true); }
}

async function exerciseJournal() {
  const requests = [], pendingReceipts = new Map(), observed = [];
  let current = record(1, "Lamp");
  const transport = {
    async read() { return read(current); },
    patch(item, bytes) {
      const reply = deferred();
      requests.push({reply, bytes, parsed: JSON.parse(bytes)});
      return reply.promise;
    },
    async receipt(item, id) { return pendingReceipts.get(id) || {status: 202, body: {state: "pending"}}; }
  };
  const config = {...identity, transport, retryDelays: [], onCommitted: (_, value) => observed.push(value.revision)};
  const original = createMutationPartition(config), a = factory(original), b = factory(original);
  await Promise.all([a.open(), b.open()]);
  a.edit("title", "A"); b.edit("title", "B");
  const first = a.submit(), second = b.submit();
  const aId = requests[0].parsed.operationId, bId = requests[1].parsed.operationId;
  check(aId !== bId && sessionStorage.length >= 2, "independent editors overwrote an operation pointer");
  for (let n = 0; n < sessionStorage.length; n++) {
    const key = sessionStorage.key(n);
    if (key.startsWith("saba:mutation:")) check(sessionStorage.getItem(key) === "1", "journal stored a draft");
  }
  a.dispose(); b.dispose(); original.retire();
  requests[0].reply.reject(new Error("response lost")); requests[1].reply.reject(new Error("response lost"));
  await Promise.all([first, second]);

  const restored = createMutationPartition(config), editor = factory(restored);
  try {
    current = record(2, "B");
    pendingReceipts.set(bId, terminal(current));
    await editor.open();
    editor.edit("title", "next");
    check(editor.status() === "pending" && !editor.canSave() && requests.length === 2, "reload enabled an uncertain write");
    pendingReceipts.set(aId, {status: 200, body: {state: "unknown"}});
    await editor.recover();
    check(!editor.canSave() && editor.review()?.latest.revision === 2, "unknown receipt skipped review");
    check(editor.resolveReview(2, ["title"]) && editor.canSave() && requests.length === 2, "unknown outcome auto-retried a PATCH");
    check(observed.join(",") === "2", "receipt replay invalidated more than once");
    const third = editor.submit();
    current = record(3, "next");
    pendingReceipts.set(requests[2].parsed.operationId, terminal(current));
    editor.dispose();
    requests[2].reply.reject(new Error("commit reply lost"));
    await third;
    check(observed.join(",") === "2,3" && requests.length === 3, "detached save failed to invalidate surviving readers");
  } finally { editor.dispose(); restored.retire(true); }

  const inaccessible = {
    get length() { return 0; }, getItem() { return null; },
    setItem() { throw new Error("quota"); }
  };
  const blocked = createMutationPartition({...config, storage: inaccessible}), form = factory(blocked);
  try {
    await form.open(); form.edit("title", "cannot send"); form.submit();
    check(form.status() === "journal-error" && form.field("title") === "cannot send" && requests.length === 3,
      "storage failure sent the mutation or discarded its draft");
  } finally { form.dispose(); blocked.retire(); }
}

async function exerciseRestoration() {
  let who = identity;
  let readRecord = async () => read(record(1, "private"));
  const partition = createMutationPartition({...identity, transport: {read: () => readRecord()}});
  const editor = factory(partition, {verifyIdentity: async () => who});
  try {
    await editor.open(); editor.edit("title", "draft"); editor.suspend();
    check(editor.field("title") === "" && !editor.canSave(), "suspension exposed a private draft");
    await editor.restore();
    check(editor.field("title") === "draft" && editor.canSave(), "same-identity restoration lost the draft");
    const late = deferred(); readRecord = () => late.promise;
    const stale = editor.refresh();
    editor.suspend(); who = {...identity, tenant: "other"};
    await editor.restore();
    late.resolve(read(record(2, "old user's data"))); await stale;
    check(editor.field("title") === "" && !editor.canSave(), "an old partition exposed a previous draft");
  } finally { editor.dispose(); partition.retire(true); }
}

export async function observeMutations(host) {
  await exerciseDrafts(host);
  await exerciseJournal();
  await exerciseRestoration();
  await exerciseAccessAndSchema();
  await exerciseOutOfOrder();
  await exerciseExplicitRetry();
  const http = itemTransport();
  const start = await http.read(item);
  check(start.status === 200 && start.body.id === item, "could not read the durable item endpoint");
  const id = crypto.randomUUID();
  const bytes = JSON.stringify({operationId: id, expectedRevision: start.body.revision, title: "browser fixture"});
  const saved = await http.patch(item, bytes);
  check(saved.status === 200 && saved.body.revision === start.body.revision + 1, "durable PATCH did not advance the revision");
  const duplicate = await http.patch(item, bytes), receipt = await http.receipt(item, id);
  check(duplicate.body.revision === saved.body.revision && receipt.body.state === "terminal" &&
    receipt.body.status === saved.status && receipt.body.body.title === saved.body.title, "duplicate delivery or receipt diverged");
  const collision = await http.patch(item, bytes.replace("browser fixture", "different submission"));
  check(collision.status === 409 && collision.body.code === "operation_id_reused", "same identifier accepted different bytes");
  const stale = await http.patch(item, JSON.stringify({operationId: crypto.randomUUID(), expectedRevision: start.body.revision, title: "old"}));
  const invalid = await http.patch(item, JSON.stringify({operationId: crypto.randomUUID(), expectedRevision: saved.body.revision, title: ""}));
  check(stale.status === 409 && invalid.status === 422 && invalid.body.fieldErrors.title, "server conflict or validation contract differed");
  return true;
}
