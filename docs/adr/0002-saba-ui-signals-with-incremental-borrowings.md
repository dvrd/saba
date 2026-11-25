---
status: accepted
---

# Saba UI updates the DOM through fine-grained signals

Saba's runtime created real DOM nodes once and required every later change to be written by hand, with no dependency tracking by design. We are reversing that: state lives in signals, and each DOM node that reads a signal is updated in place when it changes, because rebuilding regions loses focus and input state and Mesa's views cannot be kept consistent by hand. Propagation is push-pull with clean/check/dirty marking, so shared dependencies recompute once per change.

## Considered options

- **Virtual DOM re-rendering**: rejected; it re-runs components and diffs trees to find a change the dependency graph already knows.
- **Immediate-mode redraw** (Clay, Dear ImGui, microui): rejected; redrawing every frame only pays when the target is cleared each frame, and the DOM keeps its nodes.
- **An explicit incremental graph written with map/bind** (Jane Street Incremental): rejected as the authoring surface because it needs macro sugar we do not have, but three of its mechanisms are adopted under the signal surface: per-node cutoff, liveness gated on demand, and lists maintained by keyed deltas.

## Consequences

Components run once; code that reads a signal outside a tracked context does not update. Explicit `update()` remains as an escape hatch.

Each run of an authored `effect()` gets its own scope. Cleanups, nested effects, computeds, child components and resource subscriptions created during a run belong to that run and are released before the next run and when the effect stops. A function returned by the callback is that run's cleanup. [Effect ownership](../../src/modules/dom.js)

Getter-backed component props preserve tracked reads across component boundaries. Resources deliver confirmed data into those bindings according to the owning scope and request generation. [Reactive prop semantics](0007-saba-reactive-props-and-bindings.md) · [Async ownership](0006-saba-async-reads-and-mutations.md)

## Child values and ownership

Milestone 1 gives every dynamic child an insertion range with stable start and end anchors. A range belongs to the enclosing scope and can have its own effects and nested scopes. The first read and subsequent reads accept the same values.

| Value | DOM result |
| --- | --- |
| String, number or bigint | One text node. A scalar-to-scalar write changes that node's data in place. |
| `null`, `undefined`, or either boolean | No content between the anchors. Adjacent siblings keep their position. |
| DOM node, JSX element or component | Insert the node or component roots. Create the rendered branch's nested scopes under the range. |
| Fragment or array, including nested arrays and JSX spread children | Insert children in order, recursively applying these rules. Capture a fragment's actual roots before insertion consumes it. |
| Raw function, promise or other unsupported value | Raise a child-value error. A compiler-created reader has its own representation. |

For `{open() && <Editor/>}`, the outer range subscribes to `open`. On close it releases the editor's bindings, refs and scope exactly once, then removes its roots. On reopen it mounts a new editor. On an unkeyed structural replacement the previous branch is disposable. Validate a replacement before removing committed content and clean up any provisional scopes if construction fails. The range's outer subscription survives a normal branch change. `update(target, content)` disposes every removed descendant binding and invalidates its queued work before replacement, even if its parent component stays mounted. Bindings on the target itself and its siblings survive. [Current append, scope and update paths](../../src/modules/dom.js)

Exercise text → empty → fragment with two roots → nested array → text, with a sibling on each side. Assert exact order and scalar text-node identity. Replace a bound region with `update` during a batch, then flush, mutate the old signal and unmount. Check that the removed branch never writes again and its cleanup ran once.

## Keyed rows

Milestone 2 adds `keyed(items, keyOf, renderRow)`. Each evaluation reads an ordered snapshot of records. `keyOf(record)` returns a stable string or finite number unique among these siblings. Validate the full key sequence before creating, moving, disposing or publishing any row update. A missing, invalid or duplicate key reports an error and preserves the last committed rows. A later valid snapshot can reconcile again.

For each new key the runtime creates a row scope, a movable DOM range and a signal holding the current record. It calls `renderRow(readItem)` once with a read-only accessor, for example `item => <Row record={item()}/>`. A retained key updates the accessor to the incoming record in the same batch as the reorder. A label reading its new fields updates even when every record is a fresh object. A draft initialized once from the record belongs to the row instance. The form's explicit reset or merge policy decides when to overwrite that draft. [Editor contract](0008-saba-routed-edit-forms.md)

Prepare a keyed update before changing any committed row. Construct all new ranges off the live list under provisional row scopes. Validate their initial results and queue their framework-managed startup work. Keep retained record updates, moves and removals pending until every new row is ready. If a later `renderRow` throws or returns an unsupported child, dispose every provisional scope, cancel its queued work and report the error. The previous order, record accessors, active input, selection and live row scopes remain usable. On success commit the record updates and DOM changes in one batch, dispose removed rows and activate the new scopes.

Move a retained row's whole range and keep its scope, listeners and existing input node. Move as few rows as possible: retained rows whose previous positions form a longest increasing subsequence of the new order stay in place, and only the others move. A focused row is therefore detached only when its own position changes relative to its neighbours. Where the browser supports `moveBefore`, a retained row moves with it. Preserve the active element, selection direction and caret across moves. A move path that detaches the active element must restore focus and selection after placement. Dispose removed keys once. A previously removed key that returns creates a new instance.

A passive row that returns a detached intrinsic element with a single compiler-proven text binding uses that element as both ends of its range. Its text subscription still observes independent reads and follows the record accessor when a key receives a replacement record. The list keeps its two outer boundaries. Rows that expose their own lifetime, register startup work, or return empty or multiple roots keep the general range representation. Both representations use the same key validation and prepare-before-commit rules. [Text binding rules](0007-saba-reactive-props-and-bindings.md) · [Browser acceptance fixture](../../testdata/ui/keyed.jsx)

A row can acquire work after it is created. For example, `mount(cell, Badge)` can add a component whose scope belongs to the caller. Removing that cell must release the badge's bindings and run its cleanup exactly once. After starting the cell's scopes, activation checks its live children. A sole text node with no scope of its own needs no startup. During removal the runtime releases work attached to a sole text node and then to the cell. For nested components, siblings or a tracked empty text node detached by `normalize()`, it snapshots the children to visit so that cleanup callbacks can safely change the DOM.

Start with two editable rows. Type a draft, select a substring, reverse their keys using fresh objects with changed labels, then remove the edited row. Assert labels, node identity, unchanged draft, active element, selection and cleanup counts. Repeat with a multi-root row, an empty row and a duplicate-key snapshot followed by a valid one. No row or record changes on the rejected snapshot.

Start another update with a changed label on a retained row, one removal and two insertions. Let the second insertion throw after the first registered cleanup. Verify the original ordered node references, labels, focused selection and row subscriptions still work. The staged cleanup runs once and its startup callback never fires. Retry with a valid second insertion and verify the complete new order and one cleanup for the removed committed row.

## Buffered windows for fixed-height rows

An opt-in browser module exports `observeRowWindow` from `/__saba/sliding-window.js`. It publishes a half-open interval of logical **rows**. The consumer owns the scroll spacer, positions the first mounted row and gives its keyed renderer the corresponding records. For an eight-column grid, multiply the two row indices by eight and clamp the final record index to the dataset length. This keeps the scroll thumb proportional to the full dataset and preserves overlapping row nodes. [Window controller](../../src/modules/sliding-window.js) · [Working grid adapter](../../benchmarks/frameworks/rich/scale.js)

```js
import {observeRowWindow} from '/__saba/sliding-window.js';

// rows contains one immutable record per row. replaceRows is the list's renderer.
function mountWindow(viewport, spacer, band, rows, replaceRows) {
  const rowHeight = 26;
  spacer.style.height = rows.length * rowHeight + 'px';
  // The spacer is positioned relative; its band is positioned absolute.
  return observeRowWindow(viewport, {rowCount: rows.length, rowHeight}, (first, end) => {
    band.style.top = first * rowHeight + 'px';
    replaceRows(rows.slice(first, end));
  });
}
```

A browser caps the height of an element, at about 33.5 million CSS pixels in Chromium. A taller dataset cannot be scrolled to its end one pixel per pixel. Pass the `spacer` option, and optionally `band`, to hand both to the controller. It then sets the spacer to the full height or, past the cap, to the largest height the browser lays out, measured once per document and kept 5% under it; `maxScrollHeight` overrides the measurement. The scroll position maps proportionally onto the whole dataset, and the controller sets the band's `transform` so it stays under the viewport on every scroll, not only on a refill. `render` receives a third argument, `{offset, height}`. Below the cap this changes nothing. Without `spacer` the controller never compresses, and the owner sizes the spacer and positions its band as above.

```js
const rowWindow = observeRowWindow(viewport, {rowCount: rows.length, rowHeight: 26, spacer, band},
  (first, end) => replaceRows(rows.slice(first, end)));
```

By default the mounted interval extends eight rows beyond the viewport on both sides, clipped at the dataset edges. A three-row inner threshold gives the renderer time to refill. While both scrollable sides have more than three rows of runway, a scroll only checks geometry. Near an edge the controller schedules one refill before paint and reads the latest scroll position, so a reversal can cancel the need for work. If another step of the same size could exhaust the remaining rows, or a jump already exposed a new interval, the scroll handler commits the destination immediately. The browser can skip all intermediate rows. Resizing and count changes recalculate the interval, including a partially visible row. An empty or hidden viewport renders zero rows.

Call `setRowCount(count)` when records are added or removed. An owner that sizes its own spacer keeps that height in sync; with the `spacer` option the controller resizes it. A same-length data edit is independent of scrolling. Update the currently mounted rows through their existing bindings and read the current values when offscreen rows later enter. The owning scope calls `dispose()` to remove the listener, observer and pending frame.

A dense read-only grid can pass the logical start and the corresponding records to `mountSlotWindow`. This lets a cell leaving the viewport display an incoming record while overlapping cells keep their nodes. The JSX and scroll-controller example shows how to prepare immutable scalar snapshots and where tracked bindings apply. [Recycling DOM cells in a buffered window](0007-saba-reactive-props-and-bindings.md#recycling-dom-cells-in-a-buffered-window)

The shipped controller assumes a known, uniform row height and locally available records. For a consumer that places editable controls in virtualized rows, keep unsaved drafts outside disposable row views and retain the focused editor or explicitly transfer and restore its focus and selection. Expose logical row positions and total count to assistive technology. For a remote cursor-paged source, prefetch the next page early enough for transport latency, deduplicate in-flight reads and publish only the current query generation. A distant seek to unavailable data needs an explicit loading state. These are separate integration checks for applications that combine editing with virtualization or remote paging. [Async reads](0006-saba-async-reads-and-mutations.md) · [Editor contract](0008-saba-routed-edit-forms.md)

## Attaching to served HTML

A compiled page's document carries `data-saba-pending` and `aria-busy="true"` on its `#app` host. It is not `inert`, so the static content stays readable and reachable while the module loads. Controls that must not act before attachment are disabled in the markup, as the editor's literal `disabled` fieldset is. A successful attachment removes both attributes, clears `inert` if an application or an older build set it, and hides the native recovery link. A failed attachment removes `aria-busy`, keeps `data-saba-pending` and reveals the recovery link. [Document shape](../../src/pages/build.odin) · [Page entry](../../src/pages/template-entry.js) · [Editor fieldset](0008-saba-routed-edit-forms.md#what-the-application-supplies)

Saba marks its own targets with `data-saba-node` on elements and `saba:` comments for range boundaries. Attachment walks the parsed host and skips every unmarked node, so an element or comment inserted by a browser extension, translation service or password manager neither fails attachment nor becomes a target. A marked node's owner is the nearest marked element above it, looking through foreign wrappers. Foreign nodes between a range's boundaries are replaced by that range's first write. A marked node that is missing, duplicated, misplaced or altered still fails attachment. A failure rolls back the DOM mutations, live form values, focus and selection recorded during that activation. [Template attachment](../../src/modules/attach.js)
