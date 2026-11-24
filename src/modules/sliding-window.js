// Fixed-height, vertically scrolling rows. The owner sizes the scroll space
// and renders [first, end) at first * rowHeight within that space.
//
// A browser caps the height of an element (about 33.5 million CSS pixels in
// Chromium and WebKit, about 17.9 million in Gecko). A dataset taller than the
// cap cannot be scrolled to its end one pixel per pixel. Pass the spacer, and
// optionally the band, and the controller sizes the spacer to what the browser
// can lay out, maps the scroll position proportionally onto the full dataset
// and keeps the band under the viewport. Below the cap this changes nothing.
const heightLimits = new WeakMap();

function measuredLimit(viewport) {
  const doc = viewport.ownerDocument;
  if (typeof doc?.createElement !== "function" || !doc.documentElement) return Infinity;
  if (heightLimits.has(doc)) return heightLimits.get(doc);
  let limit = Infinity;
  try {
    const probe = doc.createElement("div");
    probe.style.cssText = "position:absolute;visibility:hidden;pointer-events:none;width:1px;top:0;left:0;height:1000000000px";
    doc.documentElement.appendChild(probe);
    const measured = probe.getBoundingClientRect().height;
    probe.remove();
    // Stay a little under the cap: the spacer's own offset counts as well.
    if (measured > 0 && measured < 1e9) limit = Math.floor(measured * 0.95);
  } catch {
    limit = Infinity;
  }
  heightLimits.set(doc, limit);
  return limit;
}

export function observeRowWindow(viewport, options, render) {
  const {rowHeight, overscanRows = 8, thresholdRows = 3, spacer = null, band = null} = options;
  let {rowCount} = options;
  function checkCount(count) {
    if (!Number.isSafeInteger(count) || count < 0) throw new RangeError('Expected a nonnegative row count');
  }
  checkCount(rowCount);
  if (!Number.isFinite(rowHeight) || rowHeight <= 0) throw new RangeError('Expected a positive row height');
  if (!Number.isSafeInteger(thresholdRows) || !Number.isSafeInteger(overscanRows) ||
      thresholdRows < 0 || overscanRows <= thresholdRows) {
    throw new RangeError('overscanRows must exceed the nonnegative thresholdRows');
  }
  const view = viewport.ownerDocument.defaultView;
  // Only a controller that sizes the spacer may compress it. An owner that
  // positions its own band at first * rowHeight keeps one pixel per pixel.
  const limit = !spacer ? Infinity
    : options.maxScrollHeight !== undefined ? options.maxScrollHeight : measuredLimit(viewport);
  if (!(limit > 0)) throw new RangeError('Expected a positive maximum scroll height');
  let first = -1;
  let end = -1;
  let lastHeight = -1;
  let lastTop = 0;
  let pending = null;
  let disposed = false;
  let spacerHeight = -1;
  let bandOffset = NaN;

  // Where the viewport is within the full dataset, and where it physically is.
  function locate(height) {
    const full = rowCount * rowHeight;
    const laidOut = Math.min(full, limit);
    const maxTop = Math.max(0, full - height);
    const maxScroll = Math.max(0, laidOut - height);
    const scroll = Math.max(0, Math.min(viewport.scrollTop, maxScroll));
    const top = laidOut < full && maxScroll > 0 ? Math.min(maxTop, scroll * (maxTop / maxScroll)) : Math.min(scroll, maxTop);
    return {top, scroll, laidOut};
  }

  function place(position) {
    if (spacer && position.laidOut !== spacerHeight) {
      spacerHeight = position.laidOut;
      spacer.style.height = spacerHeight + 'px';
    }
    // first * rowHeight in dataset coordinates, shifted to the physical scroll.
    const offset = Math.max(0, first) * rowHeight - position.top + position.scroll;
    if (band && offset !== bandOffset) {
      bandOffset = offset;
      band.style.transform = 'translateY(' + offset + 'px)';
    }
    return {offset, height: position.laidOut};
  }

  function inspect(canRefill, forceGeometry = false) {
    if (disposed) return;
    const height = viewport.clientHeight;
    const position = locate(height);
    const top = position.top;
    const travel = top - lastTop;
    lastTop = top;
    const visibleFirst = height ? Math.floor(top / rowHeight) : 0;
    const visibleEnd = height ? Math.min(rowCount, Math.ceil((top + height) / rowHeight)) : 0;
    const uncovered = visibleFirst < first || visibleEnd > end;
    const resized = height !== lastHeight;
    const above = first > 0 ? visibleFirst - first : Infinity;
    const below = end < rowCount ? end - visibleEnd : Infinity;
    const nearEdge = height > 0 && Math.min(above, below) <= thresholdRows;

    if (!uncovered && !resized && !forceGeometry) {
      // A compressed band follows every scroll, not only a refill.
      if (spacer || band) place(position);
      if (!nearEdge) return;
      // At walking speed multiple events can share one prepaint refill. If
      // another step this large could exhaust the runway, refill in this event.
      const runway = travel < 0 ? above : below;
      if (!canRefill && runway * rowHeight >= Math.abs(travel)) {
        if (pending === null) pending = view.requestAnimationFrame(flush);
        return;
      }
    }

    const nextFirst = height ? Math.max(0, visibleFirst - overscanRows) : 0;
    const nextEnd = height ? Math.min(rowCount, visibleEnd + overscanRows) : 0;
    lastHeight = height;
    if (first === nextFirst && end === nextEnd) {
      if (spacer || band) place(position);
      return;
    }
    first = nextFirst;
    end = nextEnd;
    try {
      render(nextFirst, nextEnd, place(position));
    } catch (error) {
      first = end = lastHeight = -1;
      throw error;
    }
  }
  function flush() {
    pending = null;
    inspect(true);
  }
  function scroll() { inspect(false); }
  const observer = new view.ResizeObserver(() => inspect(true));
  inspect(true);
  viewport.addEventListener('scroll', scroll, {passive: true});
  observer.observe(viewport);
  return {
    setRowCount(next) {
      checkCount(next);
      if (disposed || next === rowCount) return;
      rowCount = next;
      inspect(true, true);
    },
    dispose() {
      if (disposed) return;
      disposed = true;
      viewport.removeEventListener('scroll', scroll);
      observer.disconnect();
      if (pending !== null) view.cancelAnimationFrame(pending);
      pending = null;
    },
  };
}
