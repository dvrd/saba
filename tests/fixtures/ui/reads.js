import {createReadPartition} from "/__saba/reads.js";

function check(condition, message) {
  if (!condition) throw new Error(message);
}

export async function observeReads() {
  const requests = [];
  let sessionLosses = 0;
  const partition = createReadPartition((key, signal) => {
    const request = Promise.withResolvers();
    requests.push({...request, key, signal});
    return request.promise;
  }, {familyFor: () => "items", onSessionLost: () => sessionLosses++});
  const a = new AbortController();
  const b = new AbortController();
  const key = ["item", 4];
  const first = partition.read(key, a.signal);
  key[1] = 99;
  const second = partition.read(["item", 4], b.signal);
  await Promise.resolve();
  check(requests.length === 1 && requests[0].key[1] === 4, "equal immutable keys must share a request");
  a.abort();
  check(!requests[0].signal.aborted && first.state().status === "closed", "releasing one subscriber stopped a shared request");
  requests[0].resolve("initial");
  await Promise.resolve();
  check(second.state().value === "initial", "the remaining subscriber lost its value");

  const retired = second.refresh();
  await Promise.resolve();
  check(second.state().status === "refreshing" && second.state().value === "initial", "refresh lost the confirmed value");
  b.abort();
  const owner = new AbortController();
  const replacement = partition.read(["item", 4], owner.signal);
  await Promise.resolve();
  check(requests[1].signal.aborted, "the last release did not cancel");
  requests[1].reject(Object.assign(new Error("late"), {status: 401}));
  await retired;
  check(sessionLosses === 0 && replacement.state().status === "pending", "a retired error settled the replacement or logged it out");
  const winning = replacement.refresh();
  await Promise.resolve();
  requests[3].resolve("newer");
  await winning;
  requests[2].resolve("stale");
  await Promise.resolve();
  check(replacement.state().value === "newer", "a superseded generation overwrote the winner");

  const related = partition.read(["search", "4"], owner.signal);
  await Promise.resolve();
  requests[4].resolve(["private"]);
  await Promise.resolve();
  const denied = replacement.refresh();
  await Promise.resolve();
  requests[5].reject(Object.assign(new Error("denied"), {status: 403}));
  await denied;
  check(replacement.state().status === "forbidden" && related.state().value === undefined,
    "revocation did not clear protected data from related reads");
  const refreshAll = partition.invalidate("items");
  await Promise.resolve();
  check(requests.length === 8, "collection invalidation did not refresh both readers");
  requests[6].reject(Object.assign(new Error("signed out"), {status: 401}));
  requests[7].resolve(["private again"]);
  await refreshAll;
  check(sessionLosses === 1 && replacement.state().status === "closed" && related.state().status === "closed",
    "the retired identity published a completion");
  owner.abort();

  const other = createReadPartition(() => { throw new Error("unexpected loader invocation"); });
  const signal = new AbortController().signal;
  for (const invalid of [[], [""], ["a", undefined], ["a", {}], ["a", Infinity], ["a", , 1]]) {
    let rejected = false;
    try { other.read(invalid, signal); } catch (error) { rejected = error instanceof TypeError; }
    check(rejected, "accepted an invalid resource key");
  }
  other.dispose();

  let replicaRevision = 9;
  const versioned = createReadPartition(async () => ({revision: replicaRevision}), {
    revisionOf: (_key, value) => value.revision,
  });
  const detail = versioned.read(["item", 42], signal);
  await detail.refresh();
  replicaRevision = 8;
  await versioned.confirm(["item", 42], {revision: 10});
  check(detail.state().status === "error" && detail.state().value.revision === 10, "a stale replica replaced the committed detail");
  detail.release();
  const reopened = versioned.read(["item", 42], signal);
  await reopened.refresh();
  check(reopened.state().status === "error" && reopened.state().value === undefined, "a stale replica became the reopened baseline");
  replicaRevision = 11;
  await reopened.refresh();
  check(reopened.state().value.revision === 11, "a fresh revision could not recover");
  versioned.dispose();
  return true;
}
