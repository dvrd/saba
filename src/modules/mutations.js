// AbortSignal.any (Safari 17.4, Firefox 124) and AbortSignal.timeout (Safari 16,
// Firefox 100) are recent. The fallback follows whichever source aborts first;
// release() detaches it from long-lived sources once the request has settled.
function deadlineSignal(signal, timeoutMs) {
  if (typeof AbortSignal.timeout === "function" && typeof AbortSignal.any === "function") {
    const deadline = AbortSignal.timeout(timeoutMs);
    return {signal: signal ? AbortSignal.any([signal, deadline]) : deadline, release() {}};
  }
  const controller = new AbortController();
  const expire = () => {
    const error = new Error("The operation timed out.");
    error.name = "TimeoutError";
    controller.abort(error);
  };
  const follow = () => controller.abort(signal.reason);
  const timer = setTimeout(expire, timeoutMs);
  if (signal?.aborted) follow();
  else signal?.addEventListener("abort", follow, {once: true});
  return {signal: controller.signal, release() {
    clearTimeout(timer);
    signal?.removeEventListener("abort", follow);
  }};
}

function anySignal(first, second) {
  if (typeof AbortSignal.any === "function") return AbortSignal.any([first, second]);
  const controller = new AbortController();
  const follow = event => {
    first.removeEventListener("abort", follow);
    second.removeEventListener("abort", follow);
    controller.abort(event.target.reason);
  };
  for (const signal of [first, second]) {
    if (signal.aborted) { follow({target: signal}); break; }
    signal.addEventListener("abort", follow, {once: true});
  }
  return controller.signal;
}

// crypto.randomUUID exists only in secure contexts. getRandomValues is
// available everywhere and has the same source of randomness.
function randomId() {
  const source = globalThis.crypto;
  if (typeof source?.randomUUID === "function") return source.randomUUID();
  if (typeof source?.getRandomValues !== "function") {
    throw new Error("No cryptographic random source is available for operation identifiers.");
  }
  const bytes = source.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function report(error) {
  try {
    if (typeof reportError === "function") reportError(error);
    else console.error(error);
  } catch {
    // Reporting is best effort.
  }
}

// Mutation outcomes belong to the signed-in document even after an editor unmounts.
export function itemTransport(baseURL = "/api/items", timeoutMs = 10000) {
  function path(item) { return baseURL + "/" + encodeURIComponent(item); }
  async function request(url, signal, serialized) {
    const deadline = deadlineSignal(signal, timeoutMs);
    const options = {method: "GET", credentials: "same-origin", cache: "no-store", signal: deadline.signal};
    if (serialized !== undefined) {
      options.method = "PATCH";
      options.headers = {"Content-Type": "application/json"};
      options.body = serialized;
    }
    try {
      const response = await fetch(url, options);
      // Revocation must still take effect if the server sends an empty or HTML error page.
      let body;
      try { body = await response.json(); }
      catch (error) {
        if (![401, 403, 404].includes(response.status)) throw error;
      }
      return {status: response.status, body};
    } finally { deadline.release(); }
  }
  return {
    read: (item, signal) => request(path(item), signal),
    patch: (item, bytes, signal) => request(path(item), signal, bytes),
    receipt: (item, id, signal) => request(path(item) + "/operations/" + encodeURIComponent(id), signal)
  };
}

const VERSION = "1";
const NAMESPACE = "saba:mutation:";
const closed = Object.freeze({kind: "closed"});

// The session label a journal key was written for, or undefined for a key this
// module did not write. The label is JSON, so it can itself contain "]:".
function keySession(key) {
  for (let end = key.indexOf("]:", NAMESPACE.length); end >= 0; end = key.indexOf("]:", end + 1)) {
    try {
      const identity = JSON.parse(key.slice(NAMESPACE.length, end + 1));
      if (Array.isArray(identity) && identity.length === 2) return identity[0];
    } catch {
      // Keep looking for the end of the identity.
    }
  }
}

export function createMutationPartition({
  session, tenant, transport = itemTransport(), storage, newId = randomId,
  retryDelays = [100, 400], onCommitted, onAccessLost, onJournalError, retentionMs = 0,
  purgeOtherSessions = true
}) {
  if (typeof session !== "string" || !session || typeof tenant !== "string" || !tenant) {
    throw new TypeError("Expected verified session and tenant identifiers.");
  }
  // session is an opaque, non-secret identity label, never an authentication credential.
  const prefix = NAMESPACE + JSON.stringify([session, tenant]) + ":";
  const pending = new Map();
  const listeners = new Set();
  const permissionEpochs = new Map();
  let owner = new AbortController();
  let retired = false;
  const journal = () => storage ?? sessionStorage;
  const itemPrefix = item => prefix + encodeURIComponent(item) + ":";
  const keyOf = (item, id) => itemPrefix(item) + encodeURIComponent(id);
  const live = token => token === owner && !token.signal.aborted;
  const allowed = (op, token) => live(token) && op.epoch === permissionEpochs.get(op.item);
  const info = (kind, id, extra) => ({kind, operationId: id, ...extra});

  // A verified session that differs from the one that wrote an entry cannot
  // reconcile it: receipts are scoped to the caller. Its identifiers must not
  // stay readable in this tab. Other tenants of the same session keep theirs.
  if (purgeOtherSessions) {
    try {
      const store = journal();
      for (let n = store.length - 1; n >= 0; n--) {
        const key = store.key(n);
        if (!key?.startsWith(NAMESPACE) || key.startsWith(prefix)) continue;
        const writer = keySession(key);
        if (writer !== undefined && writer !== session) store.removeItem(key);
      }
    } catch (error) {
      try { onJournalError?.(error); } catch (failure) { report(failure); }
    }
  }

  function pointers(item) {
    const result = [];
    const store = journal();
    const start = itemPrefix(item);
    for (let n = 0; n < store.length; n++) {
      const key = store.key(n);
      if (key?.startsWith(start)) result.push({id: decodeURIComponent(key.slice(start.length)), version: store.getItem(key)});
    }
    return result;
  }

  // One failing observer must not hide an outcome from the others.
  function emit(item, event) {
    for (const listener of [...listeners]) {
      try { listener(item, event); } catch (error) { report(error); }
    }
  }

  function suspend() {
    owner.abort();
    pending.clear();
  }
  function retire(purge = false) {
    retired = true;
    suspend();
    try {
      if (purge) {
        const store = journal();
        for (let n = store.length - 1; n >= 0; n--) {
          const key = store.key(n);
          if (key?.startsWith(prefix)) store.removeItem(key);
        }
      }
    } catch (error) {
      onJournalError?.(error);
    } finally {
      try { emit(null, closed); } finally { listeners.clear(); }
    }
  }
  function resume(identity) {
    if (retired) return false;
    if (identity?.session !== session || identity?.tenant !== tenant) {
      retire(true);
      return false;
    }
    if (owner.signal.aborted) owner = new AbortController();
    return true;
  }

  function access(item, response) {
    const {status, body} = response;
    if (status !== 401 && status !== 403 && status !== 404) return;
    const kind = status === 404 && body?.code === "item_deleted" ? "deleted" : "unavailable";
    if (status === 401) retire(true);
    else {
      permissionEpochs.set(item, (permissionEpochs.get(item) || 0) + 1);
      for (const [key, op] of pending) if (op.item === item) pending.delete(key);
      emit(item, {kind, status});
    }
    try { onAccessLost?.(item, status, kind); } catch (error) { report(error); }
    return {kind, status};
  }

  function complete(op, token, response) {
    if (!allowed(op, token)) return closed;
    if (op.result) return op.result;
    const {status, body} = response;
    let kind;
    if (status === 200 && body?.id === op.item && Number.isSafeInteger(body.revision) &&
        body.revision >= 0 && (op.revision === undefined || body.revision > op.revision)) kind = "saved";
    else if (status === 422 && body?.fieldErrors && typeof body.fieldErrors === "object") kind = "validation";
    else if (status === 409) kind = body?.code === "operation_id_reused" ? "id-reused" : "conflict";
    if (body?.code === "client_update_required") kind = "update-required";
    if (!kind && [401, 403, 404].includes(status)) {
      kind = status === 404 && body?.code === "item_deleted" ? "deleted" : "unavailable";
    }
    if (!kind) return info("uncertain", op.id);
    op.result = info(kind, op.id, {status, body});
    clearPointer(op);
    if (kind === "saved") {
      // The application's reader may reject the record. Observers of this
      // partition still have to learn that the operation committed.
      try { onCommitted?.(op.item, body); } catch (error) { report(error); }
      emit(op.item, op.result);
    } else if (kind === "deleted" || kind === "unavailable") {
      access(op.item, response);
    } else emit(op.item, op.result);
    return op.result;
  }

  function clearPointer(op) {
    // Failure to update browser storage cannot suppress delivery of revocation.
    // Retain the known outcome for a later cleanup attempt in this document.
    try {
      if (journal().getItem(op.key) === VERSION) journal().removeItem(op.key);
      if (pending.get(op.key) === op) pending.delete(op.key);
    } catch (error) { onJournalError?.(error); }
  }

  function wait(ms, token) {
    return new Promise(resolve => {
      if (!live(token) || ms <= 0) { resolve(); return; }
      const done = () => {
        clearTimeout(timer);
        token.signal.removeEventListener("abort", done);
        resolve();
      };
      const timer = setTimeout(done, ms);
      token.signal.addEventListener("abort", done, {once: true});
    });
  }

  // An internal failure while applying a reply is not a transport failure and
  // must not be mistaken for one. Report it. The recorded outcome stands if
  // there is one; otherwise the operation is uncertain and its receipt decides.
  function settle(op, token, response) {
    try { return complete(op, token, response); }
    catch (error) {
      report(error);
      return op.result || info("uncertain", op.id, {error});
    }
  }

  function lookup(op) {
    if (op.lookup) return op.lookup;
    const token = owner;
    op.lookup = (async () => {
      let last = info("uncertain", op.id);
      for (let attempt = 0; attempt <= retryDelays.length; attempt++) {
        if (attempt) await wait(retryDelays[attempt - 1], token);
        if (!allowed(op, token)) return closed;
        if (op.result) return op.result;
        let reply;
        try { reply = await transport.receipt(op.item, op.id, token.signal); }
        catch {
          if (!allowed(op, token)) return closed;
          continue;
        }
        if (!allowed(op, token)) return closed;
        if (op.result) return op.result;
        if ([401, 403, 404].includes(reply.status)) return settle(op, token, reply);
        if (reply.status === 200 && reply.body?.state === "terminal") return settle(op, token, reply.body);
        if (reply.status === 200 && reply.body?.state === "unknown") last = info("unknown", op.id);
        else if (reply.status === 202) last = info("pending", op.id);
        else last = info("uncertain", op.id);
      }
      op.reviewable = last.kind === "unknown";
      // The attempt budget is spent and nobody may be waiting on this promise:
      // the submitting editor can be gone. Tell every observer the operation
      // is still open so a surviving view can offer recheck().
      emit(op.item, last);
      return last;
    })().finally(() => { op.lookup = undefined; });
    return op.lookup;
  }

  function dispatch(op) {
    const token = owner;
    if (op.sending) return op.sending;
    op.sending = (async () => {
      let reply;
      try { reply = await transport.patch(op.item, op.bytes, token.signal); }
      catch {
        if (!allowed(op, token)) return closed;
        return lookup(op);
      }
      if (!allowed(op, token)) return closed;
      const outcome = settle(op, token, reply);
      return outcome.kind === "uncertain" ? lookup(op) : outcome;
    })().finally(() => { op.sending = undefined; });
    return op.sending;
  }

  function submit(item, fields, revision) {
    if (!live(owner)) throw new Error("The mutation partition is inactive.");
    if (typeof item !== "string" || !item || !Number.isSafeInteger(revision) || revision < 0) {
      throw new TypeError("Expected an item identifier and a nonnegative safe revision.");
    }
    const store = journal();
    for (let n = 0; n < 32; n++) {
      const id = newId();
      if (typeof id !== "string" || !id) throw new TypeError("Invalid operation identifier.");
      const key = keyOf(item, id);
      if (store.getItem(key) !== null || pending.has(key)) continue;
      const bytes = JSON.stringify({...fields, operationId: id, expectedRevision: revision});
      const op = {key, item, id, revision, bytes, epoch: permissionEpochs.get(item), dispatched: performance.now()};
      store.setItem(key, VERSION);
      pending.set(key, op);
      return {operationId: id, outcome: dispatch(op)};
    }
    throw new Error("Could not claim a fresh operation identifier.");
  }

  // The operation recorded for one journal pointer, created on first sight.
  function recorded(item, id) {
    const key = keyOf(item, id);
    let op = pending.get(key);
    if (!op) { op = {key, item, id, epoch: permissionEpochs.get(item)}; pending.set(key, op); }
    return op;
  }

  async function reconcile(item) {
    if (!live(owner)) return [closed];
    let known;
    try { known = pointers(item); }
    catch (error) {
      // Without the journal nobody can tell whether a save is outstanding.
      // The record can still be read; it cannot be saved from this document.
      try { onJournalError?.(error); } catch (failure) { report(failure); }
      return [{kind: "journal-unavailable"}];
    }
    return Promise.all(known.map(({id, version}) => {
      if (version !== VERSION) return info("unsupported-journal", id);
      const op = recorded(item, id);
      if (op.result) { clearPointer(op); return op.result; }
      // A live PATCH carries the server's payload-collision check. Its pending
      // receipt alone cannot establish which submission used that identifier.
      return op.sending || lookup(op);
    }));
  }

  // Ask the server again about one open operation. This only reads its
  // receipt; it never sends the write again.
  async function recheck(item, id) {
    if (!live(owner)) return closed;
    let version;
    try { version = journal().getItem(keyOf(item, id)); }
    catch (error) {
      try { onJournalError?.(error); } catch (failure) { report(failure); }
      return {kind: "journal-unavailable", operationId: id};
    }
    const existing = pending.get(keyOf(item, id));
    if (existing?.result) return existing.result;
    if (version === null && !existing) return info("unknown", id);
    if (version !== null && version !== VERSION) return info("unsupported-journal", id);
    const op = existing || recorded(item, id);
    return op.sending || lookup(op);
  }

  // True while an uninterrupted submission may be sent again unchanged.
  function retryable(item, id) {
    const op = pending.get(keyOf(item, id));
    return live(owner) && Boolean(op?.bytes) && performance.now() - op.dispatched < retentionMs;
  }

  function retry(item, id) {
    if (!retryable(item, id)) {
      throw new Error("Original submission is unavailable or outside the retry window.");
    }
    return dispatch(pending.get(keyOf(item, id)));
  }

  function releaseReviewed(item, id) {
    const key = keyOf(item, id);
    const op = pending.get(key);
    if (!live(owner) || !op?.reviewable || journal().getItem(key) !== VERSION) return false;
    journal().removeItem(key);
    // Keep the direct delivery alive. If the original commit wins its completion
    // still invalidates other readers.
    op.reviewable = false;
    if (!op.sending) pending.delete(key);
    return true;
  }

  async function read(item, signal) {
    const token = owner;
    const epoch = permissionEpochs.get(item);
    if (!live(token)) return closed;
    const lifetime = signal ? anySignal(signal, token.signal) : token.signal;
    const reply = await transport.read(item, lifetime);
    if (!live(token) || lifetime.aborted || epoch !== permissionEpochs.get(item)) return closed;
    return access(item, reply) || reply;
  }

  return {session, tenant, submit, reconcile, recheck, retry, retryable, read, releaseReviewed, suspend, resume, retire,
    observe(listener) { listeners.add(listener); return () => listeners.delete(listener); }};
}
