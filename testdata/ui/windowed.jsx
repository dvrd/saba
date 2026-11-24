import {keyed, mount, signal} from "/__saba/dom.js";
import {createReadPartition} from "/__saba/reads.js";
import {observeRowWindow} from "/__saba/sliding-window.js";

function check(ok, message) {
  if (!ok) throw new Error(message);
}

// The consumer keeps a single focused row mounted beyond the overscan band.
// Scroll position is independent of the mounted row count.
export async function observeWindow(host) {
  const height = 24, total = 1000000;
  const band = signal([]), focused = signal(null);
  const drafts = new Map();
  const rows = () => {
    const ids = band(), id = focused();
    return id !== null && !ids.includes(id) ? [id, ...ids] : ids;
  };
  const row = readId => {
    const id = readId();
    return <label role="listitem" aria-posinset={id + 1} aria-setsize={total}
                  style={{position: "absolute", top: id * height + "px", height: height + "px"}}>
      <input data-row={id} aria-label={"Row " + (id + 1)} value={drafts.get(id) || ""}
             onFocus={() => focused.set(id)} onBlur={() => focused.set(null)}
             onInput={event => drafts.set(id, event.target.value)} />
    </label>;
  };
  const dispose = mount(host, () =>
    <div role="list" style={{height: "72px", overflow: "auto", position: "relative"}}>
      <div style={{height: total * height + "px"}}>{keyed(rows(), id => id, row)}</div>
    </div>
  );
  const viewport = host.firstElementChild;
  const owner = new AbortController(), requests = [];
  const partition = createReadPartition((key, abort) => {
    const deferred = Promise.withResolvers();
    requests.push({key, abort, ...deferred});
    return deferred.promise;
  });
  let query = "ad", nextPage;
  function requestNext() {
    if (!nextPage) nextPage = partition.read(["search", query, "cursor-1"], owner.signal);
    return nextPage;
  }
  const watch = observeRowWindow(viewport, {rowCount: total, rowHeight: height, overscanRows: 4, thresholdRows: 2},
    (first, end) => {
      band.set(Array.from({length: end - first}, (_, i) => first + i));
      if (end >= 18) requestNext();
    });
  function scrollToRow(id) {
    viewport.scrollTop = id * height;
    viewport.dispatchEvent(new Event("scroll"));
  }
  try {
    const input = viewport.querySelector("input");
    input.focus();
    input.value = "unsaved title";
    input.dispatchEvent(new Event("input", {bubbles: true}));
    input.setSelectionRange(2, 7, "backward");
    scrollToRow(20);
    const retired = nextPage;
    scrollToRow(25);
    await Promise.resolve();
    check(requests.length === 1 && requests[0].key[1] === "ad", "nearby windows duplicated the pending cursor read");
    check(viewport.querySelectorAll("input").length <= 12 &&
      viewport.querySelector('[data-row="25"]').parentElement.getAttribute("aria-posinset") === "26",
      "buffered window lost its logical position or grew with the dataset");
    check(viewport.querySelector('[data-row="0"]') === input && document.activeElement === input &&
      input.value === "unsaved title" && input.selectionStart === 2 && input.selectionEnd === 7 &&
      input.selectionDirection === "backward", "scrolling a dirty focused row outside the band lost its edit or selection");
    scrollToRow(0);
    check(viewport.querySelector('[data-row="0"]') === input, "returning to the edited row rebuilt its input");

    retired.release();
    query = "ada"; nextPage = undefined;
    const current = requestNext();
    await Promise.resolve();
    check(requests[0].abort.aborted && requests.length === 2, "query change kept the old cursor subscription");
    requests[1].resolve(["Ada Lovelace"]);
    await Promise.resolve();
    requests[0].resolve(["retired result"]);
    await Promise.resolve();
    check(current.state().value?.[0] === "Ada Lovelace" && retired.state().status === "closed",
      "a delayed cursor page published into a different query");
  } finally {
    watch.dispose();
    owner.abort();
    partition.dispose();
    dispose();
  }
  return true;
}
