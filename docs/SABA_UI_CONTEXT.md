# Saba UI

The part of Saba that turns JSX components into pages: a compiler that runs at build time and a runtime that runs in the browser.

## Language

### State

**Signal**:
A value that can be read and written, and that remembers which computations read it.
_Avoid_: Observable, atom, state variable

**Computed**:
A value derived from signals and other computeds, recalculated only when one of them has changed.
_Avoid_: Memo, derived, selector

**Effect**:
A computation run for what it does rather than what it returns, re-run when a value it read changes.
_Avoid_: Watcher, reaction, subscriber

**Cutoff**:
The rule by which a recalculated value that equals its previous value stops the change from travelling further.
_Avoid_: Equality check, bail-out

**Liveness**:
Whether an effect is currently demanded; an effect that is not live does no work when its inputs change.
_Avoid_: Active, mounted, subscribed

### Components

**Component**:
A function that runs once and returns DOM nodes.
_Avoid_: Widget, view

**Scope**:
The lifetime of one component instance; everything the instance created is released when its scope ends.
_Avoid_: Owner, context, root

**Hole**:
A place in JSX markup filled by an expression in braces.
_Avoid_: Slot, interpolation, expression container

**Reactive hole**:
A hole the compiler emits as a tracked reader or prop getter. Evaluating it records the signals it actually reads.
_Avoid_: Dynamic expression

**Static hole**:
A hole the compiler evaluates once at its construction point. Its value may only be available in the browser.

**Binding**:
An owned computation that writes a DOM property or attribute, a text node, or the children between two stable anchors. Only a compiler-created binding descriptor installs an effect.

**Keyed list**:
A list that matches records to row scopes and DOM ranges by a stable key. A retained row gets the new record through an accessor and keeps its local draft.
_Avoid_: For loop, repeater

### Output

**Template**:
The markup of a component that the compiler resolved at build time and emitted as HTML.
_Avoid_: Shell, skeleton, static part

### Application data

**Resource**

A shared read identified by an authenticated partition and a typed tuple of inputs. A live entry and its current request generation authorize publication. A collection family groups reads whose membership can change after a save.

**Mutation**

A request to change server state. A save captures the operation ID, submitted values and expected server revision so the editor can recognize its outcome across retries or navigation.

**Draft**

Field values owned by an editor, together with the revision the user edited. They survive a rejected save. Field edit versions distinguish submitted input from changes made while the save was pending.

**Receipt**

The server’s durable outcome for one operation. A tab-session journal holds a separate recovery pointer for each outstanding operation. A restored editor consults its receipts after verifying identity.

**Build generation**

One immutable set of route metadata, HTML, browser entries and their transitive modules. The server publishes the set together. A document can attach only to the matching generation.

## Design and delivery

The roadmap tracks the compiler, browser runtime and Odin page server through a synthetic item form. Mesa v2’s web UI is the product integration target. It records the delivery order and the observable result required to close each milestone. [Saba UI delivery roadmap](SABA_UI_ROADMAP.md)

## Write and serve a compiled component

Save this component as `web/counter.jsx`. The heading and button label go into the initial HTML. The browser runs `Counter` once, reads `count` into the output, and updates that output when the button is clicked.

```jsx
import {signal} from "/__saba/dom.js"

export const title = "Counter"

export default function Counter() {
  const count = signal(0)
  return <main>
    <h1>Counter</h1>
    <output>{count()}</output>
    <button onClick={() => count.set(count() + 1)}>Add one</button>
  </main>
}
```

A consuming Odin application with Saba in its shared collection can serve the page with this `main.odin`. From the directory containing `main.odin` and `web/`, run `odin run main.odin -file` and open `http://127.0.0.1:8080/`.

```odin
package main

import saba "shared:saba"

main :: proc() {
    assert(saba.serve({
        address = "127.0.0.1", port = 8080,
        handler = proc(_: ^saba.Connection, _: ^saba.Request) -> saba.Response {
            return {status = .Not_Found}
        },
        modules = {{directory = "web", prefix = "/ui/"}},
        pages = {templates = {pages = {{
            path = "/",
            variants = {{
                language = "en", source_file = "web/counter.jsx",
                module_url = "/ui/counter.js", recovery_label = "Reload",
            }},
        }}}},
    }))
}
```

For a data-backed example, the item page uses a parameterized route, reads an authorized baseline and connects its JSX fields to an editor. Its API and editable title belong to the synthetic framework fixture. [Item page](../testdata/ui/item.jsx) · [Odin route registration](../tests/ui/browser_test.odin) · [Read-only Mesa v2 Operations comparison](../benchmarks/frameworks/operations/README.md)
