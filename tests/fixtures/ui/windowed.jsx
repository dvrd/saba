import {keyed, mount, signal} from "/__saba/dom.js";
import {createReadPartition} from "/__saba/reads.js";
import {observeRowWindow} from "/__saba/sliding-window.js";

function check(ok, message) {
  if (!ok) throw new Error(message);
}

// 48 million pixels of rows exceed the element height cap of every engine:
// about 33.5 million CSS pixels in Chromium and WebKit, which clamp taller
// elements, and about 17.9 million in Gecko, which lays a taller element out
// with no height at all. The controller must size the spacer to what this
// engine can lay out and still reach the last row.
async function observeCompressed(host) {
  const rowHeight = 24, rowCount = 2000000;
  const viewport = document.createElement("div"), spacer = document.createElement("div"), band = document.createElement("div");
  viewport.style.cssText = "height:72px;overflow:auto;position:relative";
  band.style.cssText = "position:absolute;top:0;left:0;right:0";
  viewport.append(spacer, band);
  host.append(viewport);
  let range = [];
  const watch = observeRowWindow(viewport, {rowCount, rowHeight, overscanRows: 4, thresholdRows: 2, spacer, band}, (first, end) => {
    range = [first, end];
    band.replaceChildren(...Array.from({length: end - first}, (_, i) => {
      const row = document.createElement("div");
      row.style.height = rowHeight + "px";
      row.dataset.row = String(first + i);
      return row;
    }));
  });
  try {
    const laidOut = spacer.getBoundingClientRect().height;
    check(laidOut > 0 && Math.abs(laidOut - parseFloat(spacer.style.height)) < laidOut * 1e-5 && laidOut < rowCount * rowHeight,
      "the spacer collapsed or exceeded what this engine lays out: " + spacer.style.height + " laid out as " + laidOut);
    check(viewport.scrollHeight >= laidOut, "the viewport cannot scroll through the spacer");
    viewport.scrollTop = viewport.scrollHeight;
    viewport.dispatchEvent(new Event("scroll"));
    check(viewport.scrollTop > 0 && range[1] === rowCount, "the end of a compressed dataset was unreachable: " + range);
    const last = band.querySelector(`[data-row="${rowCount - 1}"]`).getBoundingClientRect();
    const frame = viewport.getBoundingClientRect();
    check(last.bottom > frame.top && last.top < frame.bottom, "the last row is not under the viewport at the end of the scroll range");
  } finally {
    watch.dispose();
    viewport.remove();
  }
  return true;
}

// The consumer keeps a single focused row mounted beyond the overscan band.
// Scroll position is independent of the mounted row count. This owner sizes
// and positions its own rows one pixel per pixel, so its 12 million pixels stay
// under every engine's element height cap (Gecko lays out nothing past about
// 17.9 million); observeCompressed covers datasets taller than the cap.
export async function observeWindow(host) {
  check(await observeCompressed(host), "compressed row window did not complete");
  const height = 24, total = 500000;
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
