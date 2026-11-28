import { batch, lifetime, signal, untrack } from "./dom.js";

const closed = Object.freeze({status: "closed"});
const pending = Object.freeze({status: "pending"});
const suspended = Object.freeze({status: "suspended"});
const REVISION_LIMIT = 1024;

function snapshotKey(input) {
  if (!Array.isArray(input) || typeof input[0] !== "string" || !input[0].length) {
    throw new TypeError("A resource key must begin with an operation name.");
  }
  const key = [];
  for (let i = 0; i < input.length; i++) {
    const value = input[i];
    if (!Object.hasOwn(input, i) || (value !== null && typeof value !== "string"
      && typeof value !== "boolean" && !Number.isSafeInteger(value))) {
      throw new TypeError("Resource key parts must be strings, safe integers, booleans or null.");
    }
    key.push(value === 0 ? 0 : value);
  }
  return Object.freeze(key);
}

function report(error) {
  try {
    if (typeof reportError === "function") reportError(error);
    else console.error(error);
  } catch {
    // Reporting is best effort.
  }
}

// Create one partition for a verified session and tenant. The application owns
// its loader, collection membership and the lifetime of that verified identity.
//
// familyFor groups keys for invalidation. An application that supplies it also
// opts into family-wide revocation: a 403 or opaque 404 for one member retires
// every member. Without it a denied read retires only its own key.
//
// identity and verifyIdentity cover history restoration. A document restored
// from the back/forward cache shows no confirmed value until the current
// session has been checked against the one this partition was created for.
export function createReadPartition(load, {
  familyFor, revisionOf, onSessionLost, identity, verifyIdentity, onIdentityChanged,
  revisionLimit = REVISION_LIMIT,
} = {}) {
  const entries = new Map();
  const revisions = new Map();
  const paused = signal(false);
  const sharedFamilies = typeof familyFor === "function";
  const family = sharedFamilies ? familyFor : key => key[0];
  const page = typeof addEventListener === "function" && typeof removeEventListener === "function";
  let disposed = false, restoring;

  // A binding that throws while it renders a new state must not turn into an
  // unhandled rejection or stop the other entries from settling.
  function publish(entry, value) {
    try { entry.state.set(value); } catch (error) { report(error); }
  }

  function cancel(entry) {
    const previous = entry.controller;
    entry.controller = null;
    previous?.abort();
  }

  function dispose() {
    if (disposed) return;
    disposed = true;
    if (page) {
      removeEventListener("pagehide", hide);
      removeEventListener("pageshow", show);
    }
    const retired = Array.from(entries.values());
    entries.clear();
    revisions.clear();
    try {
      batch(() => {
        for (const entry of retired) {
          entry.confirmed = undefined;
          entry.state.set(closed);
          cancel(entry);
        }
      });
    } catch (error) { report(error); }
  }

  function revoke(denied, error) {
    try {
      batch(() => {
        for (const entry of entries.values()) {
          if (sharedFamilies ? entry.family !== denied.family : entry !== denied) continue;
          entry.confirmed = undefined;
          cancel(entry);
          entry.state.set({status: "forbidden", error});
        }
      });
    } catch (failure) { report(failure); }
  }

  function issue(entry) {
    if (untrack(paused)) return;
    const old = entry.controller;
    const controller = new AbortController();
    entry.controller = controller;
    const current = () => entries.get(entry.id) === entry && entry.controller === controller;
    old?.abort();
    if (!current()) return;
    publish(entry, entry.confirmed ? {status: "refreshing", value: entry.confirmed.value} : pending);
    // Re-check at dispatch as well as publication. Setup can dispose a scope
    // synchronously, before this request gets a chance to start.
    return Promise.resolve().then(async () => {
      if (!current()) return;
      let value;
      try {
        value = await load(entry.key, controller.signal);
        if (!current()) return;
        if (!acceptRevision(entry.id, entry.key, value)) {
          throw new Error("The read returned an older revision. Refresh to try again.");
        }
      } catch (error) {
        if (!current()) return;
        entry.controller = null;
        if (error?.status === 401) {
          dispose();
          try { onSessionLost?.(error); } catch (failure) { report(failure); }
        } else if (error?.status === 403 || error?.status === 404) {
          revoke(entry, error);
        } else {
          publish(entry, {status: "error", value: entry.confirmed?.value, error});
        }
        return;
      }
      if (!current()) return;
      entry.controller = null;
      entry.confirmed = {status: "ready", value};
      publish(entry, entry.confirmed);
    });
  }

  function read(input, owner = lifetime().abort) {
    const key = snapshotKey(input);
    const id = JSON.stringify(key);
    if (disposed || owner.aborted) throw new Error("Cannot subscribe from a closed lifetime.");
    let entry = entries.get(id);
    const fresh = !entry;
    if (fresh) {
      entry = {id, key, family: family(key), state: signal(pending), subscribers: 0,
        controller: null, confirmed: undefined};
      entries.set(id, entry);
    }
    entry.subscribers++;
    const active = signal(true);
    function release() {
      if (!entry) return;
      const retired = entry;
      entry = null;
      owner.removeEventListener("abort", release);
      if (--retired.subscribers === 0 && entries.get(id) === retired) {
        entries.delete(id);
        cancel(retired);
      }
      try { active.set(false); } catch (error) { report(error); }
    }
    owner.addEventListener("abort", release, {once: true});
    if (fresh) issue(entry);
    return {
      state() {
        if (!active() || !entry) return closed;
        const value = entry.state();
        return value !== closed && paused() ? suspended : value;
      },
      refresh: () => !disposed && entry ? issue(entry) : undefined,
      release,
    };
  }

  function invalidate(name) {
    return batch(() => Promise.all(Array.from(entries.values())
      .filter(entry => entry.family === name)
      .map(issue)));
  }

  // Remember the newest revision of recently confirmed keys, including keys
  // nobody is watching now. The oldest unwatched keys are forgotten first.
  function acceptRevision(id, key, value) {
    const version = revisionOf?.(key, value);
    if (version === undefined) return true;
    if (!Number.isSafeInteger(version) || version < 0) throw new TypeError("Invalid resource revision.");
    if (version < revisions.get(id)) return false;
    revisions.delete(id);
    revisions.set(id, version);
    if (revisions.size > revisionLimit) {
      for (const old of revisions.keys()) {
        if (revisions.size <= revisionLimit) break;
        if (old !== id && !entries.has(old)) revisions.delete(old);
      }
    }
    return true;
  }

  // Call only for an authorized, terminal mutation in this partition. Record
  // the revision even if its detail view is closed; a later stale replica
  // response must not become the next editor's baseline.
  function confirm(input, value) {
    if (disposed) return;
    const key = snapshotKey(input);
    const id = JSON.stringify(key);
    const entry = entries.get(id);
    return batch(() => {
      if (acceptRevision(id, key, value) && entry) {
        entry.confirmed = {status: "ready", value};
        publish(entry, entry.confirmed);
      }
      return invalidate(family(key));
    });
  }

  // Hide every confirmed value and stop its transport. Subscribers read
  // "suspended" until restore() admits the current identity.
  function suspend() {
    if (disposed || untrack(paused)) return;
    try {
      batch(() => {
        paused.set(true);
        for (const entry of entries.values()) cancel(entry);
      });
    } catch (error) { report(error); }
  }

  // Resolves true once the partition is live again. A failed check leaves it
  // suspended so the caller can try again. A different identity closes it.
  function restore() {
    if (disposed) return Promise.resolve(false);
    if (!untrack(paused)) return Promise.resolve(true);
    if (restoring) return restoring;
    const work = (async () => {
      if (verifyIdentity) {
        let now;
        try { now = await verifyIdentity(); } catch { return false; }
        if (disposed) return false;
        if (identity && (now?.session !== identity.session || now?.tenant !== identity.tenant)) {
          dispose();
          try { onIdentityChanged?.(now); } catch (error) { report(error); }
          return false;
        }
      } else {
        // Nobody vouched for the reader. Show only what the server sends now.
        for (const entry of entries.values()) entry.confirmed = undefined;
      }
      try {
        batch(() => {
          paused.set(false);
          for (const entry of entries.values()) issue(entry);
        });
      } catch (error) { report(error); }
      return true;
    })().finally(() => { if (restoring === work) restoring = undefined; });
    restoring = work;
    return work;
  }

  function hide(event) { if (event.persisted) suspend(); }
  function show(event) { if (event.persisted) void restore(); }
  if (page) {
    addEventListener("pagehide", hide);
    addEventListener("pageshow", show);
  }

  return {read, invalidate, confirm, dispose, suspend, restore};
}
