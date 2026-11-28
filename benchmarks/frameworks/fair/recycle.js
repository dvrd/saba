// Same overlap rule as mountSlotWindow in src/modules/slot-window.js.
// The vanilla slot arm uses it directly. Saba's arm goes through the runtime,
// which also snapshots records and watches the host for outside edits.

export function allocate(old, start, first, count, makeSlot) {
  const low = Math.max(start, first);
  const high = Math.min(start + old.length, first + count);
  if (high <= low || start === first) {
    const kept = Math.min(count, old.length);
    if (old.length === count) return { next: old, prefix: 0, suffix: count, retired: [] };
    const next = old.slice(0, kept);
    while (next.length < count) next.push(makeSlot());
    return { next, prefix: 0, suffix: kept, retired: old.slice(kept) };
  }
  const prefix = low - first;
  const suffix = high - first;
  const free = [...old.slice(0, low - start), ...old.slice(high - start)];
  const next = new Array(count);
  let used = 0;
  for (let i = 0; i < count; i++) {
    if (i >= prefix && i < suffix) next[i] = old[first + i - start];
    else next[i] = used < free.length ? free[used++] : makeSlot();
  }
  return { next, prefix, suffix, retired: free.slice(used) };
}

function move(host, element, before) {
  if (element.parentNode === host && typeof host.moveBefore === 'function') host.moveBefore(element, before);
  else host.insertBefore(element, before);
}

export function place(host, plan) {
  const { next, prefix, suffix } = plan;
  for (let i = 0; i < prefix; i++) move(host, next[i].element, next[prefix].element);
  for (let i = suffix; i < next.length; i++) move(host, next[i].element, null);
}
