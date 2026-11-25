---
status: accepted
implementation: implemented
---

# Reactive props stay live across component calls

A component runs its setup once. The parent owns its signal and the child owns the binding that reads the prop. Passing a value through another component must preserve that connection. This decision specifies the contract between the Kessel compiler and the browser runtime. [Signal design](0002-saba-ui-signals-with-incremental-borrowings.md) · [Compiler design](0003-saba-jsx-compiler-on-kessel.md)

## From parent signal to child text

```jsx
function Badge(props) {
  return <output>{props.count}</output>
}

function Inbox() {
  const unread = signal(2)
  return <><Badge count={unread()}/><button onClick={() => unread.set(3)}>Add message</button></>
}
```

In the first compiler milestone, the component call has the semantics of `jsx(Badge, { get count() { return unread() } })`. The child emits the equivalent of `jsx("output", {}, binding(() => props.count))`, where `binding` denotes a compiler/runtime-private descriptor. While evaluating that binding, the prop getter reads the parent's signal. Clicking the button changes the output text from `2` to `3` on the same text node. Both setup functions have run exactly once.

## What the compiler emits

The one-shot grammar covers primitive literals, a bare lexical variable or import, a function or arrow literal, and parentheses around one of these. A bare name captures its JavaScript value at that point, including a signal accessor passed as data. Creating a function does not execute its body. Other synchronous value expressions default to a tracked reader for a DOM child or attribute, or a getter for a component prop. This includes optional chains, tagged templates, coercions and opaque helpers. No inspection of a helper body is required. Event and ref positions receive their ordinary values once during construction. A click invokes the registered handler.

`{Date.now()}` therefore gets a reader. Its first browser evaluation captures the time. With no signal reads it has no dependency to wake it. For an explicit snapshot, assign `const openedAt = Date.now()` during setup and use `{openedAt}`. Evaluating a hole once and proving its value available during the build are separate decisions. The later HTML emitter can extract proven build-time values. Browser clocks, request data and opaque calls stay in browser code. [HTML delivery](0004-saba-compile-time-html-no-request-rendering.md)

When the sole child of an intrinsic element is an expression that JavaScript guarantees will produce a string on successful evaluation, the compiler can emit a tracked text binding. This includes an untagged template literal, `typeof`, concatenation with a proven string operand, and a conditional whose two branches produce strings. For example, `<div>{id + ' · ' + record().score}</div>` mounts one text node and updates its data. The reader still executes the original expression so that a getter or coercion can read signals, register cleanup or throw. A bare property read such as `record().title` can also produce structural content and uses the general binding. Sibling bindings keep their boundaries so DOM normalization can preserve each position. Attachment to a server-emitted range retains its preflight markers and staged writes. [JSX emitter](../../src/jsx/jsx.odin) · [Text binding](../../src/modules/dom.js)

## Shapes the compiler lowers to direct DOM code

Some shapes compile to plain DOM loops instead of runtime bindings. Lowering is declined, never approximated, wherever the direct code could differ from the runtime path, and a declined shape compiles exactly as it would without lowering. Lowering is never applied in a module that names `globalThis`, because the generated code reaches the platform through it. [Lowered lists](../../src/jsx/closed.odin) · [Tree rows](../../src/jsx/tree.odin) · [Direct holes](../../src/jsx/hole.odin)

**Keyed and checkbox lists.** The module must import `signal`, `keyed` and `mount` from `/__saba/dom.js` under their own names. The mount is a named module-level function with simple parameters, the first two being the host and the records, and exactly this body:

```jsx
export function mountRows(host, records) {
  const rows = signal(records);
  const list = keyed(rows, record => record.id, Row);
  const dispose = mount(host, () => <>{list}</>);
  return { replace: rows.set, dispose };
}
```

The key must be a field the row reads. Local names may not shadow `signal`, `keyed` or `mount`, and a signature containing JSX stays on the runtime because the signature is copied verbatim. `Row` is a named module-level function with one simple parameter and a single returned element, in one of these forms:

- a `div`, `span`, `p`, `li`, `td` or `th` whose only child is an expression JavaScript guarantees is a string, such as `{record().id + ' · ' + record().label}`;
- an `<input type="checkbox">` with no children, whose `checked`, if present, is dynamic and written to the live property;
- a tree of HTML-only elements, including `img` and `video`, with literal or provably string text, and element-or-nothing conditionals such as `{record().vip ? <b>VIP</b> : null}`.

Attributes are `class`, `title` and lowercase `data-*` or `aria-*`, plus `src` and `alt` on `img`, `src`, `preload` and `poster` on `video`, and `type` and `checked` on a checkbox. Quoted static attributes come first, `checked` is never static, and each dynamic value reads at least one `record().field`. A bare `{record().field}` child never lowers: it can hold a node, an array or nothing, which the runtime renders structurally. SVG content, `a`, custom elements and any tag outside the HTML-only list keep the runtime's namespace decision.

The generated mount keeps the authored body. It takes the direct loop only when the host is an `Element` in the HTML namespace; any other host runs the authored statements on the runtime, errors included. The loop appends an end comment to the host and places its rows before it, so other children of the host keep their positions. It registers with the scope active at mount time and with that end marker, as a runtime mount does, so disposing the scope, or `update()` removing the marker, releases the list. Keys are validated with the runtime's rules and messages before any DOM change. A changed record object updates text only when its value differs, rewrites dynamic attributes with the runtime's nullish and boolean rules, and skips attributes that read only the key. `replace` with the same array does nothing. The loop reads record fields directly and installs no tracked bindings. [Equivalence fixture](../../testdata/ui/lowered.jsx)

**Element-or-nothing holes.** Outside page templates, an HTML-only, non-void element whose own children include a conditional such as `{open() ? <p>Saved</p> : null}` builds its static children once and swaps the branch from one tracked write that starts synchronously, so a prop getter, member read or signal call in the condition is followed as a binding would follow it. The host, its static descendants and the branch must use HTML-only tags with quoted attributes; branch text must be a string or number literal or a provably string expression. Conditions and branch text may use literals, identifiers, operators, non-computed member chains and zero-argument calls of an enclosing function's parameters. Any spelling of `on*`, `srcdoc`, `style`, `ref`, live form properties and a URL attribute that could hold a `javascript:` URL keep the element on the runtime, so the runtime's checks still apply.

**What stays on the runtime.** Bare `{record().field}` text, SVG and other foreign content, `a` and custom elements, rows with setup, events, refs or child components, any mount that differs from the four-statement form, and slot windows. A slot window enforces an empty, exclusive host, validates every range, recovers from foreign mutation of the host and gives accessor records tracked bindings, none of which the compiler can prove; its registered rows already use the compiled writer described below.

A row or hole nested deeper than 128 elements is not analysed for lowering. The ordinary emitter reports `JSX nesting exceeds 128 levels` at the element that exceeds it, and an expression chaining more than 20,000 operators at one bracket level reports `Expression nesting is too deep to compile`. Both are located diagnostics rather than stack overflows. [Compiler limits](0003-saba-jsx-compiler-on-kessel.md#limits-and-memory)

## Recycling DOM cells in a buffered window

Use `mountSlotWindow(host, Row)` for a contiguous band of logical positions. Its `replace(first, records)` call places `records[0]` at logical index `first`. Overlapping indices keep their physical cells. When the band advances, a simple scalar row can reuse the outgoing elements and text nodes for incoming records. For example, moving a three-cell band from indices 10–12 to 11–13 keeps the cells for 11 and 12, then rebinds the former cell for 10 to display 13. The dataset can contain duplicate IDs because position supplies identity. [Window renderer](../../src/modules/slot-window.js)

This example displays local scores with one 24 px row per record. The viewport has a fixed height and `overflow-y: auto`. Inside it, a relatively positioned spacer contains an initially empty, absolutely positioned band at `top: 0`. Give `.score` a height of 24 px and `box-sizing: border-box`. [Scroll controller](../../src/modules/sliding-window.js)

```jsx
import {observeRowWindow} from '/__saba/sliding-window.js';
import {mountSlotWindow, scalarRecord} from '/__saba/slot-window.js';

function Score(row) {
  return <div class="score" data-id={row().id}>{row().id + ' · ' + row().points}</div>;
}

export function mountScores(viewport, spacer, band, scores) {
  const rowHeight = 24;
  const rows = scores.map(({id, points}) => scalarRecord({id, points}));
  const slots = mountSlotWindow(band, Score);
  spacer.style.height = rows.length * rowHeight + 'px';
  const scroll = observeRowWindow(viewport, {rowCount: rows.length, rowHeight}, (first, end) => {
    band.style.transform = 'translateY(' + first * rowHeight + 'px)';
    slots.replace(first, rows.slice(first, end));
  });
  return () => { scroll.dispose(); slots.dispose(); };
}
```

`scalarRecord` copies enumerable own fields into an immutable snapshot. Each field must have a string name and hold a string or finite number. Normalizing when records arrive lets subsequent windows share a snapshot for every unchanged record. To update a score, replace that record’s snapshot and call `replace` for the current band. Applications that load pages can normalize each arriving page. [Snapshot implementation](../../src/modules/scalar-records.js)

For `Score`, the compiler registers the fields `id` and `points` and emits a writer equivalent to the following. Each physical cell receives its element, text node and static class once. On rebind, the writer receives the new snapshot directly. The renderer can skip a cell that still holds the same snapshot. The ordinary `Score` function remains available through JSX, regular keyed lists and module imports. [Compiler](../../src/jsx/slot.odin) · [Compiled grid fixture](../../benchmarks/frameworks/rich/scale-saba-window.jsx)

```js
function write(element, text, row) {
  element.setAttribute('data-id', row.id);
  text.data = row.id + ' · ' + row.points;
}
```

The compiler recognizes a named module-level function with one simple parameter and a single return. The row must be a `div`, `span`, `p`, `li`, `td` or `th` with one expression statically known to produce a string. Each dynamic attribute and the text expression must read at least one `row().field`. They may also use string or number literals, addition, parentheses and untagged templates. Attributes can use `class`, `title` and lowercase `data-*` or `aria-*` names. Quoted static attributes precede dynamic attributes so the browser exposes them in JSX order. A named export or default function declaration can live in another module. [Compiler tests](../../tests/internal/jsx_test.odin)

An eligible row receiving an ordinary record, a reactive getter or a snapshot missing a required field uses tracked JSX bindings. Their reads and cleanup belong to that cell. Rows with setup, controls, refs, event handlers, child components or multiple roots use the ordinary keyed lifecycle with the logical index as key. Use `keyed(records, record => record.id, Row)` when component state, focus or a draft should follow a record across a reorder. Dispose the window with its owner to release its rows and subscriptions. [Keyed row ownership](0002-saba-ui-signals-with-incremental-borrowings.md#keyed-rows) · [DOM runtime](../../src/modules/dom.js)

## Forwarding and lifetime

The runtime passes the child's props with their getters intact. For JSX forwarding such as `<Badge {...props}/>`, the compiler and runtime enumerate the enumerable own prop names at construction and forward accessors lazily using their source object as receiver. Later JSX attributes override earlier ones in source order. Consume the component's reserved `ref` separately and supply its JSX children using the existing calling convention. [Current runtime](../../src/modules/dom.js)

Read `props.count` inside JSX or a computed to follow it. Ordinary JavaScript destructuring during setup, including `function Badge({count})`, takes a snapshot. Run child setup outside the caller’s tracking context even when a conditional binding creates the child. Its own bindings establish their own tracking contexts. A diagnostic should point authors who use a destructured prop as live JSX to the original property read.

Bindings evaluate once on attachment. Each subsequent evaluation records its current dependencies and drops subscriptions from the previous branch. Ending a child scope releases its bindings and skips their queued effects. Removing a conditional branch disposes its nested scopes. Mounting it again creates new instances. The same range owns results containing zero, one or multiple nodes. [Structural child values and disposal](0002-saba-ui-signals-with-incremental-borrowings.md#child-values-and-ownership)

An ordinary signal write outside a running flush settles affected effects before returning. A synchronous `batch(fn)` defers effects until the outermost batch exits, including on throw. Direct signal and computed reads within the batch see preceding writes. `Object.is` compares old and new values for signals and computed results. `untrack(fn)` suspends dependency collection and restores the previous tracker in a finally path, preserving scope ownership.

Errors during a flush go to different places by origin. A compiler-created binding reports its failure to the code that wrote the signal, which can rely on the committed DOM being unchanged, as with a rejected keyed snapshot. Only the first binding error is thrown; later ones go to `reportError`. An authored `effect()` has no such contract: when a write re-runs it and it throws, the error goes to `reportError` and never reaches the writer, and the rest of the flush continues. An error in an effect's first synchronous run throws from `effect()` itself. When `batch(fn)` throws, its own error is the one its caller sees, and errors from the flush it triggers are reported. [Scheduler](../../src/modules/dom.js)

A flush that does not settle within 100 passes hits the pass limit. The effects that wrote a signal during the last two passes of this flush are retired from it; they stay subscribed, so a later write runs them again. Every other pending effect gets another 100 passes to observe the final values. If none can be singled out, or the limit is reached again, all pending work is dropped. The writer then receives `Reactive flush exceeded the pass limit (100).`, and a binding error from the same flush is reported. Scheduler state is restored in a finally path, so independent later writes still run.

## Acceptance

- Compile and run the Badge example with an intermediate component forwarding `{...props}`. Assert setup counts, text-node identity and the final `3`. Override `count` after a spread and verify the overridden getter is never evaluated.
- Compile a literal, `Date.now()`, an opaque helper, an event handler and a ref. Assert the emitted value, reader or getter in each position and that the event callback first runs on click.
- Switch a binding between two signals. A write to the abandoned branch causes zero evaluations. Mount a child that destructures a prop and verify that changing the prop never reruns the enclosing conditional. Dispose a child inside a batch, then flush and assert zero further writes to its DOM.
- Batch two writes feeding the same computed through two paths. Assert one settled effect, equal-value cutoff and no subscription from an untracked read. Assert a self-writing effect reports the pass limit while an independent effect in the same flush still sees the final value. Throw from an authored effect on a later run and verify the writer does not see the error. [Scheduler tests](../../tests/javascript/scheduler.test.mjs)

## Function values and suspension

Only a generated binding descriptor installs a DOM effect. A callback prop such as `<List format={format}/>` carries the same function object. Even when a tracked prop returns a function, the consumer chooses when to call it. A raw function, promise or unsupported object in child position gets a type error.

A tracked reader is synchronous and can reevaluate. Put side effects in setup, an event or an effect with an explicit lifetime. For a hole containing a lexically valid `await` at the hole's own evaluation depth (for example, `return <p>{await label()}</p>` inside an async helper), preserve the await once at the original construction point, in JavaScript evaluation order. The resolved value is a snapshot, including when supplied as a component prop. Nested callback bodies retain their own suspension semantics. Component setup still returns a node synchronously. An unresolved promise is never awaited by a DOM binding. If another form cannot preserve its original execution context, such as a generator's `yield` hole in this milestone, report the original file, line and column and suggest assigning its result before JSX.

- Compile a tagged-template helper whose tag reads a signal, and a coercion whose `valueOf` reads one. A tracked text updates after a write. Pass a callback as a prop and assert identity and zero calls before the consumer invokes it.
- Run an async helper with sibling holes around `await`. Check evaluation order and a single call to the loader. Check a located diagnostic for the unsupported generator hole and a type error for rendering a raw function or promise.
- Throw inside a nested batch and an untracked read. Verify tracking resumes, queued live effects settle and a later independent write still works after reaching the flush limit.

## DOM attribute and property updates

An attribute binding owns updates as well as initial assignment. Remove an attribute for a nullish value. For ARIA, data and enumerated string attributes, serialize booleans as `"true"` and `"false"`. For other ordinary HTML attributes, false removes the attribute, true sets its presence (including `disabled`), and other values are strings. Honor the existing `className` and `htmlFor` aliases. When a style object changes, clear properties dropped by that binding before applying the new declarations. [Current construction path](../../src/modules/dom.js)

Live form properties use the same rules on attachment and update. For a text input or select, a nullish `value` becomes the empty string. Nullish `checked`, `selected` and `muted` become false. Apply the native value after its options exist and compare the live property with the desired value before assigning, so a same-value refresh preserves the caret. Conditional attributes in SVG and MathML use the element’s namespace rules. [Namespace handling](0003-saba-jsx-compiler-on-kessel.md#namespace-belongs-to-the-rendered-position)

The runtime refuses attribute values that would run or inject code, on attachment and on every update:

- Every prop whose name starts with `on` in any case and is longer than two characters is an event. A function becomes a listener, a nullish value is skipped, and anything else is a `TypeError`. `ONCLICK="…"` can never become an inline handler attribute.
- `srcdoc` (any case) refuses every value that would be written as a string, which is anything except a nullish or boolean value.
- `href`, `src`, `action`, `formaction` and `xlink:href` (any case) refuse a `javascript:` URL. The scheme is checked as the URL parser reads it, after removing tabs and line breaks and skipping leading control characters and spaces.
- `innerHTML`, `outerHTML` and `textContent` are refused in favour of JSX children.

`trusted(value)` opts one value in: the caller vouches that a `javascript:` URL or `srcdoc` markup does not come from another user or an unchecked server field. The runtime writes the wrapped value unchecked. [Attribute checks](../../src/modules/dom.js)

- On the same mounted input, clear `aria-describedby`, switch `aria-invalid` to false, and enable the input. Verify the description attribute disappears, the ARIA attribute reads `"false"`, and `disabled` is absent. Reapply the same text with a selection, then clear the value. Verify the selection survived the first write and the live value is empty after the second. Toggle a checkbox off and drop one property from a bound style object. Inspect the live property and resulting style.
