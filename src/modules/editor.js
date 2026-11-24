import { lifetime, signal } from "./dom.js";

const terminalFailures = new Set(["deleted", "unavailable", "closed", "update-required"]);
const unresolved = new Set(["unknown", "uncertain", "pending", "unsupported-journal"]);
let nextEditorId = 0;

function report(error) {
  try {
    if (typeof reportError === "function") reportError(error);
    else console.error(error);
  } catch {
    // Reporting is best effort.
  }
}

// A new editor opens blank. Applications provide the editable fields, their
// validation dependencies, and a fresh identity check for history restoration.
export function createEditor({
  partition, item, fields, validate = () => ({}), dependencies = {},
  verifyIdentity, onIdentityChanged, owner = lifetime().abort
}) {
  const names = [...new Set(fields)];
  if (!names.length || names.some(name => typeof name !== "string" || !name ||
      ["id", "revision", "operationId", "expectedRevision", "__proto__"].includes(name))) {
    throw new TypeError("Supply editable field names distinct from record metadata.");
  }
  const prefix = "saba-editor-" + (++nextEditorId) + "-";
  const blank = () => Object.fromEntries(names.map(name => [name, ""]));
  const changed = signal(0);
  // A binding that fails while rendering the new state is reported. It must
  // not interrupt the editor in the middle of a transition.
  const notify = () => {
    try { changed.set(++sequence); } catch (error) { report(error); }
  };
  let sequence = 0, generation = 0, version = 0, base, latest;
  let draft = blank(), versions = Object.create(null), errors = Object.create(null), status = "loading", openRequest;
  let formMessage = "";
  let visible = false, locked = true, needsReview = false, disposed = false, suspended = false;
  let attempt, submitting, restoring, recovering, recovery = [], refreshing = 0, reviewedAfterReceipt;
  let settledDuringRecovery;
  let minimumReviewRevision, readOnly = false;
  const valid = token => !disposed && !suspended && token === generation;
  const dirty = () => !!base && names.some(name => !Object.is(draft[name], base[name]));
  const touch = () => { changed(); };
  const eligible = () => visible && !locked && !needsReview && dirty() &&
    !Object.keys(validate({...draft})).length && !attempt && !submitting;
  const fieldId = name => prefix + encodeURIComponent(name);
  const errorId = name => fieldId(name) + "-error";
  function resetPrivate() {
    base = latest = undefined;
    draft = blank(); versions = Object.create(null); errors = Object.create(null); formMessage = "";
    visible = false; locked = true; needsReview = false;
    attempt = submitting = reviewedAfterReceipt = minimumReviewRevision = undefined; recovery = [];
  }

  function canEdit() {
    return visible && !readOnly && !disposed && !suspended && !terminalFailures.has(status);
  }

  function reveal(record) {
    if (!record || record.id !== item || !Number.isSafeInteger(record.revision) ||
        record.revision < 0 || names.some(name => !Object.hasOwn(record, name))) {
      throw new Error("Invalid authorized item response.");
    }
    // An older replica answer changes nothing, but it is still an authorized
    // answer: a restored editor may show the newer values it already holds.
    if (latest && record.revision < latest.revision) { visible = true; return; }
    if (latest && record.revision > latest.revision) { errors = Object.create(null); formMessage = ""; }
    latest = record;
    if (!base || (!dirty() && !attempt && !needsReview)) {
      adopt(record);
    } else if (record.revision > base.revision) {
      needsReview = true;
    }
    visible = true;
  }

  function adopt(record) {
    base = record;
    draft = Object.fromEntries(names.map(name => [name, record[name]]));
    needsReview = false;
    errors = Object.create(null);
    formMessage = "";
  }
  function retireView(kind) {
    generation++;
    refreshing++;
    openRequest?.abort();
    const keepDraft = visible && ((kind === "deleted" && dirty()) || kind === "update-required");
    if (keepDraft) {
      latest = undefined; errors = Object.create(null); formMessage = "";
      locked = true; visible = true; needsReview = false;
      attempt = submitting = undefined; recovery = [];
    } else resetPrivate();
    status = kind;
    notify();
  }

  const unsubscribe = partition.observe((id, result) => {
    if (disposed || suspended || (id !== null && id !== item)) return;
    if (attempt && result.operationId === attempt.id) {
      // A sibling's receipt lookup can finish an uncertain operation before
      // this editor retries. The submitting editor still owns its draft.
      if (!submitting && !recovering && !unresolved.has(result.kind)) {
        recovery = recovery.filter(outcome => outcome.operationId !== attempt.id);
        locked = recovery.length > 0;
        applyOutcome(result, attempt).catch(report);
      } else if (recovering && !unresolved.has(result.kind)) {
        // Recovery already holds its receipt answers. It applies this one
        // after its baseline read instead of losing it.
        settledDuringRecovery = result;
      }
      return;
    }
    if (result.kind === "saved") {
      if (visible && result.operationId !== attempt?.id) {
        try { reveal(result.body); }
        catch {
          // Another editor's reply lacked a field this one edits. The commit
          // still happened, so read the whole record instead of staying on
          // the old revision without saying so.
          status = "invalid-record";
          notify();
          void refresh();
          return;
        }
        status = needsReview ? "review" : "ready";
        notify();
      }
    } else if (terminalFailures.has(result.kind) && !result.operationId) {
      retireView(result.kind);
    }
  });

  async function refresh() {
    if (disposed || suspended) return false;
    const token = generation, request = ++refreshing;
    openRequest?.abort();
    const transport = new AbortController();
    openRequest = transport;
    try {
      const reply = await partition.read(item, transport.signal);
      if (!valid(token) || refreshing !== request || reply.kind) return false;
      if (reply.status !== 200) throw new Error("Read failed.");
      reveal(reply.body);
      if (minimumReviewRevision !== undefined && reply.body.revision >= minimumReviewRevision) minimumReviewRevision = undefined;
      status = needsReview ? "review" : ((Object.keys(errors).length || formMessage) ? "invalid" : "ready");
      return true;
    } catch {
      if (valid(token) && refreshing === request) status = "read-error";
      return false;
    } finally {
      if (valid(token) && refreshing === request) notify();
    }
  }

  function applicable(name, snapshot) {
    const inputs = Object.hasOwn(dependencies, name) ? dependencies[name] : names;
    return base?.revision === snapshot.revision && latest?.revision === snapshot.revision &&
      inputs.every(key => (versions[key] || 0) === (snapshot.versions[key] || 0));
  }
  function focusInvalid(form) {
    if (!form?.contains(form.ownerDocument.activeElement)) return;
    for (const input of form.elements) {
      if (Object.hasOwn(errors, input.name) && !input.disabled && input.getClientRects().length) {
        input.focus(); break;
      }
    }
  }
  async function applyOutcome(result, snapshot) {
    if (unresolved.has(result.kind)) {
      locked = true; status = result.kind;
      recovery = [result]; notify(); return;
    }
    attempt = undefined;
    if (terminalFailures.has(result.kind)) { retireView(result.kind); return; }
    if (result.kind === "saved") {
      const record = result.body;
      if (names.some(name => !Object.hasOwn(record, name))) {
        locked = true; status = "invalid-record"; notify(); return;
      }
      if (!latest || latest.revision < record.revision) latest = record;
      base = record;
      for (const name of names) {
        if ((versions[name] || 0) === (snapshot.versions[name] || 0)) draft[name] = record[name];
      }
      if (!dirty()) adopt(latest);
      else needsReview = latest.revision > base.revision;
      errors = Object.create(null); formMessage = ""; status = needsReview ? "review" : "saved";
    } else if (result.kind === "validation") {
      errors = Object.create(null);
      formMessage = "";
      for (const [field, message] of Object.entries(result.body.fieldErrors)) {
        if (typeof message !== "string" || !applicable(field, snapshot)) continue;
        if (names.includes(field)) errors[field] = message;
        else formMessage = message;
      }
      status = Object.keys(errors).length || formMessage ? "invalid" : (needsReview ? "review" : "ready");
      notify();
      focusInvalid(snapshot.form);
    } else if (result.kind === "conflict" || result.kind === "id-reused") {
      needsReview = true;
      minimumReviewRevision = result.kind === "id-reused" ? snapshot.revision :
        Math.max(snapshot.revision + 1, Number.isSafeInteger(result.body?.revision) ? result.body.revision : 0);
      status = result.kind;
      const token = generation;
      await refresh();
      if (!valid(token)) return;
      if (result.kind === "id-reused") status = result.kind;
    }
    notify();
  }

  function recover() {
    if (recovering) return recovering;
    const work = reconcileAndRead().finally(() => { if (recovering === work) recovering = undefined; });
    recovering = work;
    return work;
  }

  async function reconcileAndRead() {
    if (disposed || suspended) return false;
    const token = generation;
    reviewedAfterReceipt = settledDuringRecovery = undefined;
    locked = true; notify();
    try {
      const outcomes = await partition.reconcile(item);
      if (!valid(token)) return false;
      const previous = attempt;
      const own = previous && outcomes.find(o => o.operationId === previous.id);
      if (own && !unresolved.has(own.kind)) await applyOutcome(own, previous);
      if (!valid(token)) return false;
      recovery = outcomes.filter(o => unresolved.has(o.kind));
      if (outcomes.some(o => o.kind === "update-required")) { retireView("update-required"); return false; }
      if (outcomes.some(o => terminalFailures.has(o.kind))) return false;
      // Without its journal this document cannot know about, or record, a
      // save. The record can still be shown. It cannot be edited from here.
      readOnly = outcomes.some(o => o.kind === "journal-unavailable");
      // The baseline read begins after every observed receipt outcome. An old
      // pre-commit response can therefore never unlock this editor.
      const refreshed = await refresh();
      if (!valid(token)) return false;
      const settled = settledDuringRecovery;
      settledDuringRecovery = undefined;
      if (settled && attempt && settled.operationId === attempt.id) {
        recovery = recovery.filter(o => o.operationId !== attempt.id);
        await applyOutcome(settled, attempt);
        if (!valid(token)) return false;
      }
      if (refreshed) reviewedAfterReceipt = latest.revision;
      locked = Boolean(recovery.length) || !refreshed || readOnly;
      if (recovery.length) status = recovery[0].kind;
      else if (readOnly && refreshed) status = "read-only";
      return !locked;
    } catch {
      if (valid(token)) { status = "recovery-error"; locked = true; }
      return false;
    } finally {
      if (valid(token)) notify();
    }
  }

  function edit(name, value) {
    if (!canEdit() || !names.includes(name)) return;
    if (Object.is(draft[name], value)) return;
    draft[name] = value;
    versions[name] = ++version;
    formMessage = "";
    for (const field of Object.keys(errors)) {
      if ((Object.hasOwn(dependencies, field) ? dependencies[field] : names).includes(name)) delete errors[field];
    }
    Object.assign(errors, validate({...draft}));
    // Returning to the baseline makes the draft clean, and a clean draft can
    // adopt the latest record. It cannot do so while a conflict still points
    // at a revision this editor has not been shown: that review stays open.
    if (!dirty() && latest && !attempt && minimumReviewRevision === undefined) adopt(latest);
    if (["saved", "invalid"].includes(status)) status = needsReview ? "review" : "ready";
    notify();
  }

  function submit(event) {
    event?.preventDefault();
    if (submitting) return submitting;
    if (!eligible()) return;
    const token = generation;
    const snapshot = {revision: base.revision, versions: {...versions}, form: event?.currentTarget};
    let request;
    try { request = partition.submit(item, {...draft}, snapshot.revision); }
    catch { status = "journal-error"; notify(); return; }
    snapshot.id = request.operationId;
    attempt = snapshot; status = "saving";
    return settle(request.outcome, snapshot, token);
  }

  function settle(outcome, snapshot, token) {
    const promise = outcome.then(async result => {
      if (valid(token) && attempt === snapshot && !unresolved.has(result.kind)) {
        recovery = recovery.filter(pointer => pointer.operationId !== snapshot.id);
        locked = recovery.length > 0;
      }
      if (valid(token) && attempt === snapshot) await applyOutcome(result, snapshot);
      return result;
    }).finally(() => {
      if (submitting === promise) { submitting = undefined; if (valid(token)) notify(); }
    });
    submitting = promise;
    notify();
    return promise;
  }

  function retry() {
    if (submitting) return submitting;
    if (!canEdit() || !attempt || !recovery.length || !recovery.every(pointer => pointer.operationId === attempt.id)) return;
    // Partition checks the original bytes, identity, and the server's minimum
    // retention interval. A new document has only the operation identifier.
    // Outside that window the write is not sent again; refresh() rechecks its
    // receipt instead.
    let outcome;
    try { outcome = partition.retry(item, attempt.id); }
    catch { return Promise.resolve({kind: "retry-unavailable", operationId: attempt.id}); }
    status = "saving";
    return settle(outcome, attempt, generation);
  }

  // A review is tied to the revision actually shown. Selecting no fields adopts
  // the server's values; selecting a field retains its local draft.
  function resolveReview(revision, keep = []) {
    if (!canEdit() || !latest || minimumReviewRevision !== undefined || latest.revision !== revision ||
        keep.some(name => !names.includes(name))) return false;
    if (!needsReview && !recovery.length) return false;
    if (recovery.some(result => result.kind !== "unknown")) return false;
    if (recovery.length && reviewedAfterReceipt !== revision) return false;
    for (const result of recovery) if (!partition.releaseReviewed(item, result.operationId)) return false;
    const selected = new Map(keep.map(name => [name, draft[name]]));
    adopt(latest);
    for (const [name, value] of selected) draft[name] = value;
    attempt = undefined; recovery = []; locked = false;
    status = "ready"; notify();
    return true;
  }

  function suspend() {
    if (disposed || suspended) return;
    suspended = true; generation++; refreshing++; restoring = recovering = undefined;
    openRequest?.abort(); partition.suspend();
    submitting = undefined; visible = false; locked = true; errors = Object.create(null); formMessage = ""; status = "suspended";
    notify();
  }
  // The form stays hidden and locked until the current session is verified.
  // A failed check is reported as "unverified" and restore() can be called
  // again; it is not the same as an ordinary suspension still in progress.
  function unverified() {
    if (status !== "unverified") { status = "unverified"; notify(); }
    return false;
  }
  function restore() {
    if (restoring) return restoring;
    if (disposed || !suspended) return Promise.resolve(false);
    if (!verifyIdentity) return Promise.resolve(unverified());
    const token = ++generation;
    const work = (async () => {
      let identity;
      try { identity = await verifyIdentity(); }
      catch { return !disposed && token === generation ? unverified() : false; }
      if (disposed || token !== generation) return false;
      suspended = false;
      if (!partition.resume(identity)) {
        retireView("unavailable");
        onIdentityChanged?.(identity);
        return false;
      }
      return recover();
    })().finally(() => { if (restoring === work) restoring = undefined; });
    restoring = work;
    return work;
  }
  const hide = event => { if (event.persisted) suspend(); else dispose(); };
  const show = event => { if (event.persisted) void restore(); };
  function dispose() {
    if (disposed) return;
    disposed = true;
    unsubscribe();
    owner.removeEventListener("abort", dispose);
    window.removeEventListener("pagehide", hide);
    window.removeEventListener("pageshow", show);
    retireView("closed");
  }
  if (owner.aborted) dispose();
  else {
    owner.addEventListener("abort", dispose, {once: true});
    window.addEventListener("pagehide", hide);
    window.addEventListener("pageshow", show);
  }

  return {
    open: recover, refresh: () => locked ? recover() : refresh(),
    recover, edit, submit, retry, resolveReview, dispose, suspend, restore, fieldId, errorId,
    field(name) { touch(); return visible ? draft[name] : ""; },
    error(name) { touch(); return visible ? errors[name] || "" : ""; },
    describedBy(name, existing = "") {
      touch();
      const ids = new Set(existing.split(/\s+/).filter(Boolean));
      if (visible && errors[name]) ids.add(errorId(name));
      return [...ids].join(" ") || undefined;
    },
    message() { touch(); return (visible && formMessage) || status; },
    status() { touch(); return status; }, editable() { touch(); return canEdit(); },
    canSave() { touch(); return eligible(); },
    canRetry() {
      touch();
      return canEdit() && !submitting && Boolean(attempt) && recovery.length > 0 &&
        recovery.every(pointer => pointer.operationId === attempt.id) &&
        partition.retryable?.(item, attempt.id) === true;
    },
    review() { touch(); return visible && (needsReview || recovery.length) ? {
      base: base && {...base}, latest: latest && {...latest}, draft: {...draft}
    } : null; }
  };
}
