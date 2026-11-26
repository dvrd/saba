# Where React beat the planned Saba renderer

The earlier seven-way comparison exposed two material deficits for the handwritten Saba prototype. On the throttled board, React committed a cross-column drop sooner in seven of seven rounds and painted it sooner in six. In the single fully mounted million-cell trial React mounted 1.38 s sooner, used 316 MiB less sampled peak renderer memory, and painted the jump to the final cell 41 ms sooner. The repeated 2 GiB trials also consistently fit more React cells. These follow-ups keep production code and the original benchmark fixtures intact. [Dashboard and scale baseline](SABA_RICH_RENDERING.md)

Measured before 2026-11-25. The compiler now lowers some keyed and checkbox lists and element-or-nothing holes to direct DOM code, which may change the compiled Saba figures below. They are kept as recorded until new measurements replace them. All runs used Chromium.

## Moving a keyed card

Each round used the same four-lane board with 240 cards. After selection, batch edit, undo and filtering, a trusted mouse drag moved the first card of the first lane ahead of the first card of the second lane. The benchmark checked all affected state and final DOM order, timed the same 300 ms animation, and collected Chromium compositor presentation feedback. The three variants rotated through all six execution orders twice under 4× CPU throttling. DOM mutation counts came from separate warm-up visits, with the observer disabled during timing.

The original Saba list updates the source lane first. Its cursor still points at the card being dragged. To match the next snapshot, it moves the 59 siblings ahead of that cursor, then moves the dragged card into the destination lane. This produces the right order and retains all 240 nodes, but the browser has to process 60 moves. React removed the dragged card from its old lane and created its counterpart in the new lane, retaining 239 nodes.

The first experiment gives Saba the board's existing move action, including the target key and destination. It places the existing card before the destination key, then runs the ordinary keyed reconciliation. The warm-up recorded one move, with all 240 original nodes retained. The cross-lane drop is the workload under test. Other kinds of reorder need their own measurements.

| Constrained median over 12 rounds | Original planned Saba | Saba with move action | React |
| --- | ---: | ---: | ---: |
| Renderer update | 5.7 ms | 1.7 ms | 4.2 ms |
| Post-update geometry measurement | 11.6 ms | 4.0 ms | 3.9 ms |
| Pointer release to DOM commit | 29.7 ms | 18.8 ms | 21.8 ms |
| Pointer release to first paint marker | 79.2 ms | 65.1 ms | 74.8 ms |
| Pointer release to settled paint marker | 397.6 ms | 387.1 ms | 396.8 ms |

Within paired rounds, the variant painted sooner than original Saba in 12/12, with a median saving of 15.8 ms. It painted sooner than React in 9/12, with a median saving of 7.6 ms. React reconciled its keyed snapshot through its existing adapter. The move action supplied extra information to this Saba variant. [Measured visits, timing phases and DOM operations](benchmarks/renderer-drag.json)

### Inferring the move from the snapshot

The second experiment removes the action hint. All three renderers receive the same ordered lists. At the first mismatch the candidate builds a map of retained nodes to their next parent. It skips a cursor node that is about to leave the current lane and proceeds to the retained siblings. The destination lane then moves that node once. In-order updates avoid building the map. This specializes cross-parent movement and deletions. Arbitrary within-lane permutations still use the regular reconciliation path.

| Separate constrained run, 12 rounds | Original planned Saba | Saba with snapshot-only change | React |
| --- | ---: | ---: | ---: |
| Card additions / removals in the diagnostic drop | 60 / 60 | 1 / 1 | 1 / 1 |
| Existing card nodes retained, out of 240 | 240 | 240 | 239 |
| Renderer update | 2.9 ms | 1.2 ms | 1.9 ms |
| Post-update geometry measurement | 5.1 ms | 1.7 ms | 1.7 ms |
| Pointer release to DOM commit | 14.2 ms | 9.0 ms | 10.5 ms |
| Pointer release to first paint marker | 44.1 ms | 44.1 ms | 44.7 ms |

The snapshot-only version spent less time in the renderer than original Saba and React in all 12 rounds. The median paired saving through commit was 5.3 ms against original Saba and 1.3 ms against React. The corresponding first-paint savings were 0.5 ms and 1.2 ms. The original first-paint disadvantage relative to React did not recur at its previous size in this run. Absolute timings differed across the two sessions, so each column should be compared only with its same-run controls.

Filtering down to 35 cards also painted sooner than original Saba in 11/12 rounds (6.2 ms median paired saving). Restoring the full list took 1.6 ms longer in paired rounds. The median worst inter-frame gap was 33.3 ms, compared with 16.7 ms for original Saba and 25.0 ms for React. The evidence supports the reduction in DOM moves and commit cost. [Snapshot-only measurements](benchmarks/renderer-drag-snapshot.json) · [Reproduce either drag experiment](../benchmarks/frameworks/experiments/drag.py)

In a six-round repeat the diagnostic again counted 60 moves for the original prototype and one for the snapshot change. Median pointer release to DOM commit was 21.3 ms for the original, 13.0 ms for the change and 15.0 ms for React. This fixture maintains its own card map across board lanes. The production keyed list owns keys within each list and removes outgoing rows before placing survivors. [Repeat measurements](benchmarks/renderer-drag-snapshot-repeat.json) · [Board reconciler](../benchmarks/frameworks/rich/saba-keys.js) · [Production keyed list](../src/modules/dom.js)

## Mounting one million cells

The scale comparison uses fresh, unthrottled desktop Chromium processes. Each fully mounts one million eight-column grid cells in bands of 4,096, updates 10,311 records, scrolls to the bottom and hit-tests the final cell. A 6 GiB renderer guard and 150-second deadline apply to every visit. The same run checks record text and node shape at both ends of every band. React uses the same production bundle as the original scale benchmark.

The Saba fixture normally places a text node between two DOM comments in every cell. For a binding guaranteed to produce exactly one text node, the proposed compiler contract allows direct ownership of that node. The experimental variant omits just the comments. It keeps the signal, effect, update, cleanup, band reconciliation, connected cell count and displayed values. At one million cells this removes two million DOM nodes. Dynamic holes with variable node counts are a different case. [Experiment](../benchmarks/frameworks/experiments/text-slot.mjs)

All nine visits completed the mount, sparse update and final-cell hit test. In each of three rounds, all three implementations ran once and their positions rotated. The following values are per-implementation medians. The jump clock starts in the trusted button handler. Both update and jump end at the presentation of the visible status marker.

| Fully mounted million-cell grid | Original planned Saba | Saba with one text node | React |
| --- | ---: | ---: | ---: |
| Start to mount paint | 19.13 s | 18.14 s | 16.60 s |
| Sampled peak renderer RSS, including baseline | 5,065 MiB | 4,882 MiB | 4,455 MiB |
| Sparse update through DOM changes | 51.2 ms | 46.7 ms | 486.9 ms |
| Sparse update through paint | 1.70 s | 1.55 s | 1.96 s |
| Click to handle final-row scroll | 29.4 ms | 28.7 ms | 28.2 ms |
| Click to final-row paint | 174.6 ms | 152.6 ms | 148.1 ms |

The single-text variant improved mount, memory, sparse-update paint and final-row paint against original Saba in all three paired rounds. Its median within-round savings were **1.58 s to mount, 184 MiB of peak RSS and 16.4 ms to paint the final row**. The median of three paired changes can differ from subtracting the per-implementation medians in the table.

React still mounted sooner than the new variant in two of three rounds and used less memory in all three. The new variant's mount times ranged from 10.39 to 18.20 s, while React ranged from 16.57 to 16.93 s. The final-row paint gap decreased to a 4.5 ms paired median, with the new variant ahead in one round. The scroll handler ran about 28–29 ms after the click for all three. These measurements locate most of the jump latency after the scroll handler and do not identify the browser's internal cause. [Raw visits, data checks and stage times](benchmarks/renderer-text-slot.json)

### Why the text-only cell still consumes more memory

Each cell has one input, a record from its parent band, and one output, the text `id · score`. The band compares record identities and already knows which cells changed. The handwritten Saba prototype also gives each cell a signal with a set of subscribers and an effect with a set of dependencies. The first render runs the effect to discover that single connection. Both sets, their backing storage and the per-cell functions stay alive while the cell is mounted. React's memoized tile takes the same record as a prop and returns a div with a primitive text child. React retains component and DOM bookkeeping for each tile, with no local hook or subscription in this fixture. [Saba cell and band](../benchmarks/frameworks/rich/scale.js) · [Signal and effect](../benchmarks/frameworks/rich/reactivity.js) · [React tile](../benchmarks/frameworks/rich/scale-react.jsx)

To measure what stays alive, we started a fresh Chromium process for each variant, created the data, collected garbage, then mounted and laid out 20,480 cells. After two animation frames we collected garbage again. Each figure below is the increase over that variant's data-only baseline divided by 20,480. The browser's embedder heap includes native browser objects. Process RSS also includes memory outside these heap counters and can fluctuate between visits.

| Retained bytes per mounted cell, rounded | V8 JavaScript heap | Browser embedder heap |
| --- | ---: | ---: |
| Saba with two comment anchors | 520 B | 2,936 B |
| Saba with one text node | 515 B | 2,772 B |
| Same text node, set `data-id` with `setAttribute` | 513 B | 2,596 B |
| Saba fixed input, same `dataset.id` assignment | 69 B | 2,772 B |
| Saba fixed input with `setAttribute` | 68 B | 2,580 B |
| React memoized tile | 354 B | 2,606 B |

Three costs are visible in the snapshots and controlled variants.

- **Reactive bookkeeping.** Per text-only Saba cell, the two sets and their backing tables accounted for 152 shallow bytes, six functions for about 168 B, three captured environments for about 80 B, and the signal, effect and returned cell objects for 68 B. These distinct groups cover about 468 of the 515 JavaScript bytes per cell. React retained 40,975 Fiber objects for the 20,480 cells and five bands, roughly two per cell and 208 shallow bytes per cell. The 354 B in the table includes React's other retained JavaScript allocations.
- **Attribute writes.** Setting `node.dataset.id` kept a native `DOMStringMap` for each of the 20,480 Saba cells. Switching just the setter to `node.setAttribute('data-id', value)` produced the same DOM attribute and left five maps, one for the final cell that the fixture reads in each band. The change saved 176–192 browser-heap bytes per cell across the two binding variants. The measured saving includes associated browser storage. The map object's own shallow size was about 42 B.
- **DOM shape.** The original cell also created two comments around its label. Removing them eliminated 40,960 DOM nodes in this sample and two million at full scale. Even with those comments gone, each framework pays for the cell div, its text, and browser bookkeeping. The roughly 2.6 KiB per cell on the browser heap explains why a million simultaneously mounted cells consume gigabytes even with a small binding.

Object counts and per-cell estimates come from post-GC snapshots of the five-band sample. Multiplying those estimates by one million would not predict peak process RSS. [Heap measurements, source hashes and object counts](benchmarks/renderer-cell-heap.json)

### How much of mount time belongs to the cells

In a separate million-cell experiment, a Saba variant stored the current record and the text-node reference on a small instance with a shared update method. The parent called that method whenever it supplied a changed record. The variant retained the same band comparison, DOM shape, `dataset.id` assignment and initial text write as the text-only control. Production React ran unchanged. [Experimental fixed-input cell](../benchmarks/frameworks/experiments/fixed-cell.js)

| Median of three fresh Chromium visits per variant | Saba text-only | Saba fixed input | React |
| --- | ---: | ---: | ---: |
| Create the detached bands and their cells | 2.16 s | 1.83 s | 2.06 s |
| Attach bands and force layout | 7.08 s | 7.27 s | 7.40 s |
| Start to mount paint | 15.51 s | 15.17 s | 15.77 s |
| Sparse update through DOM changes | 43.8 ms | 33.8 ms | 771.6 ms |
| Sparse update through paint | 1.42 s | 1.32 s | 2.16 s |
| Sampled peak renderer RSS | 4,916 MiB | 4,690 MiB | 4,380 MiB |

Replacing the per-cell reactive graph cut peak RSS in all three paired rounds, by 224 MiB at the median. React used less peak RSS than text-only Saba in every round of both experiments. Mount time varied more. React led text-only Saba in two of three rounds in the earlier experiment. Text-only Saba led React in two of three here. For all three implementations the attach-and-layout step took longer than creating the detached cells. Mount-to-paint also includes the fixture's browser round trips, checkpoints and presentation waits. The clocks do not isolate a paint-only duration. [All nine visits, checksums, timing phases and memory samples](benchmarks/renderer-cell-binding.json)

The final full-grid experiment isolated the attribute setter. The two Saba variants used the same fixed-input cell and differed by one statement. All nine visits completed the million-cell mount, edited 10,311 records and reached the final cell. Compared within the same rounds, using `setAttribute` saved a median **212 MiB peak RSS and 531 ms to mount** against `dataset.id`. Its peak RSS was lower and its mount finished sooner than React's in all three rounds. The final-row jump had a small median advantage for React. These comparisons cover one cell shape in desktop Chromium. [Measured visits and source hashes](benchmarks/renderer-cell-attribute.json)

| Median of three visits per variant in the setter experiment | Saba fixed input, `dataset.id` | Saba fixed input, `setAttribute` | React |
| --- | ---: | ---: | ---: |
| Start to mount paint | 15.40 s | 14.92 s | 15.46 s |
| Sampled peak renderer RSS | 4,231 MiB | 4,019 MiB | 4,754 MiB |
| Sparse update through DOM changes | 35.5 ms | 33.9 ms | 343.8 ms |
| Sparse update through paint | 1.42 s | 1.35 s | 1.67 s |
| Click to final-row paint | 140.5 ms | 144.1 ms | 139.5 ms |

For a sparse update, the Saba band compares record references and dispatches directly to the 10,311 changed cells. The React band maps the full record slice to keyed elements on every render, then React can reuse the memoized tiles with unchanged props. Both adapters receive the same immutable records. This difference in the update path helps explain how the original Saba variant could spend more memory while committing edits sooner. [Band implementations](../benchmarks/frameworks/rich/scale.js) · [React band](../benchmarks/frameworks/rich/scale-react.jsx)

When the compiler can prove a text node has one parent-supplied input and no independent reactive reads, it can emit a direct text update. A cell that reads a second signal, switches dependencies, or changes the number of DOM children needs the appropriate tracking or structural binding. Known `data-*` attributes can use `setAttribute` directly. The prototype comparison here measures planned Saba. The separate `saba-current` benchmark calls the public component mount for every cell, including its scope and teardown machinery. [Current runtime](../src/modules/dom.js)

### Can the compiler remove the cell object entirely?

The fixed-input version still allocated one instance per cell to hold the record, div and text node. Its host already owns the DOM and its parent retains the previous records. Two experimental renderers move the update loop to that parent. Both set the initial text in one operation and compare the previous and next record before writing a changed score. One caches each text node in an array. The other retrieves `host.children[i].firstChild` only when the score changes. Neither receives a list of changed indices. A structural change builds a temporary index for the affected suffix and keeps the element and text node of each surviving key. [Band implementations](../benchmarks/frameworks/experiments/text-band.js)

| Post-GC growth per cell at 20,480 mounted cells | Fixed cell with `setAttribute` | Band with cached text nodes | Band with DOM lookup |
| --- | ---: | ---: | ---: |
| JavaScript heap | 68.1 B | 31.9 B | 16.0 B |
| Browser embedder heap | 2,596 B | 2,596 B | 2,596 B |
| Cell instances retained | 20,480 | 0 | 0 |

The heap contained one array entry pointing to a text node per cached cell. The lookup variant retained no such entries. Each variant had the same DOM count. The data records already existed when each baseline snapshot was taken. A dedicated Chromium check also exercised interior key permutations, changed values on moves, insertion, removal, empty lists and disposal. It checked retained element and text-node identities and observed zero DOM mutations when replacement records displayed the same values. [Heap measurements](benchmarks/renderer-band-heap.json) · [Behavior check](../benchmarks/frameworks/experiments/verify-text-band.cjs)

#### Connected grid with one million cells

Four rotating rounds gave each variant each run position once. Each visit ran in a fresh Chromium process, mounted the same million cells, applied the same 10,311 edits and hit-tested the final row. All 16 visits passed. Building the detached bands is part of the overall mount-to-paint clock. The sparse-edit paint marker measures the first visible update after the full mount.

| Median per variant | Build detached bands | Mount to paint | Sparse edit to DOM | Sparse edit to paint | Peak renderer RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| Fixed cell with `setAttribute` | 1.45 s | 14.18 s | 32.8 ms | **1.27 s** | **4,029 MiB** |
| Band with cached text nodes | 1.15 s | **13.32 s** | 166.4 ms | 1.48 s | 4,471 MiB |
| Band with DOM lookup | 1.15 s | 13.75 s | 47.1 ms | 1.72 s | 4,575 MiB |
| React | 1.90 s | 14.67 s | 529.6 ms | 1.84 s | 4,383 MiB |

The cached band reached mount paint sooner in every paired round against the fixed cell, saving a median **1.23 s**. Its first edit painted **198 ms later**, and peak renderer RSS was **444 MiB higher** in the median matched pair. Both band variants built the detached bands faster and lost on first-edit paint and peak RSS to the fixed cell in all four rounds. The heap measurement captured live objects in a 20,480-cell grid after forced garbage collection. The RSS sampler observed the whole renderer process throughout the full million-cell visit without forced garbage collection. These measurements establish a trade-off. They cannot attribute the additional RSS to a particular browser allocator, GC phase or JIT decision. [Timing phases, memory samples and correctness checks](benchmarks/renderer-text-band.json)

#### Repeated edits in one active band

On a connected 4,096-cell band, six matched rounds exercised all six implementation orders for each edit density. Every fresh page prepared identical immutable snapshots, warmed up with 12 replacements, and then timed 36 replacements in blocks. Layout ran before each block. The values below measure the synchronous call through the DOM writes. Presentation and input preparation are outside that clock. The driver checked all 4,096 labels and verified the exact set of text nodes written on an additional update.

| Median time per replacement | Fixed cell | Band with cached text nodes | Band with DOM lookup |
| --- | ---: | ---: | ---: |
| Change approximately 1% of scores | 0.062 ms | **0.039 ms** | 0.049 ms |
| Change every score | 2.770 ms | **1.044 ms** | 1.348 ms |

The cached band beat both alternatives in all six pairs at each density. Its paired advantage over the lookup band was 0.009 ms for a sparse replacement and 0.295 ms for a dense one. This makes cached text nodes a candidate for a frequently recalculated region. The million-cell experiment favors the fixed cell when the priority is peak process memory or the first sparse edit reaching the screen. For a spreadsheet viewport, the existing windowed fixture held a million records with 144 cells mounted at the top, reaching its initial view in 70.8 ms and using 232 MiB with planned Saba. That change in how many cells the browser owns had a much larger effect. [Repeated edit measurements](benchmarks/renderer-band-edits.json) · [Windowed grid](SABA_RICH_RENDERING.md)

#### Generated JavaScript size

We bundled each standalone list renderer, including its keyed update and disposal code, with the same pinned esbuild and one exported mount function. After minification and Brotli compression the previous fixed-cell module was **479 bytes**. The cached-text version was **500 bytes**, and the lookup version was **506 bytes**. They share a more general fallback for structural edits. These are renderer module bodies. Application code, HTML, data, CSS and HTTP headers have separate costs. The scale timer starts after the modules load. [Generated module sizes and build options](benchmarks/renderer-band-size.json)

Emit static HTML for proven static content, and include only the helpers used by a route. Keep unavoidable objects consistent in field order and use dense, in-bounds arrays for retained references. V8 can use shared object shapes and specialize array access. The experiments measure the observable cost of allocations and updates. They do not identify which JIT optimization ran. Measure cold delivery separately. In the existing editor trial, 24 extra encoded HTML bytes preloaded two required modules and advanced the first editable state by a paired median of 70.9 ms. [V8 property access](https://v8.dev/blog/fast-properties) · [V8 array storage](https://v8.dev/blog/elements-kinds) · [Cold editor navigation](SABA_UI_PERFORMANCE.md)

The specialization needs an exclusively owned list of immutable, validated records with unique keys and plain primitive projected fields. In this experiment the scores are finite numbers and every row has one nonempty text child. Arbitrary prop getters, proxies or coercions can read another signal. Per-row refs, lifecycle hooks or independently reactive state can require individual ownership. A public keyed list must validate keys and preserve the previously committed rows on preparation failure. Both constraints still apply when choosing generated code.

## Smaller differences

Desktop selection painted about 6.5 ms later in paired rounds for Saba, even though Saba committed earlier in all seven rounds. The virtualized million-record jump had a paired median gap of 0.55 ms. The original editor showed no comparable repeatable loss to React. These observations provide little evidence of a renderer bottleneck for those interactions. [Dashboard observations](benchmarks/rich-dashboard.json) · [Editor observations](benchmarks/web-frameworks.json)

## Compiled Saba and React on a disjoint window jump

Jumping from the first row to the last row of a million-record grid replaces every visible cell. In the buffered fixture both renderers use Saba’s window controller, eight columns and the same eight rows of overscan. At either end the window contains 192 cells. Each implementation receives the same immutable records and renders the keyed ID and score. After the jump, the driver hit-tests the center of the last cell and checks its ID and updated score. The Saba adapter uses the Odin JSX transform and the production DOM runtime. React uses memoized tiles in a production build with a synchronous commit. [Saba adapter](../benchmarks/frameworks/rich/scale-saba.jsx) · [React adapter](../benchmarks/frameworks/rich/scale-react.jsx)

The renderer clock surrounds the call that replaces the mounted cells. The click-to-paint clock also includes scroll dispatch, layout and presentation of the visible status marker. Both start after the application modules and data are loaded. The harness rotates renderer order and launches a fresh browser process per visit. [Clock definitions and correctness checks](../benchmarks/frameworks/rich/scale-run.cjs)

In 12 rotating desktop rounds per window size, the smaller two-row overscan reproduced a distinction the historical table could not show. On the 144-cell jump the handwritten prototype spent a median 1.3 ms replacing cells, React 4.3 ms, and compiled Saba 10.0 ms. On the 192-cell buffered jump the medians were 2.0 ms, 5.9 ms and 16.5 ms respectively. All 12 buffered jumps also painted sooner in React than in compiled Saba. This run used Chromium 145 on a shared M1 Max with other jobs active. Compare implementations within a run. [Source and bundle hashes with all 72 visits](benchmarks/renderer-compiled-grid-baseline.json)

Three separate instrumented jumps on the original compiled bundle timed entire row loops. Median time was 5.2 ms to prepare 192 destination rows off the live DOM, 9.8 ms to remove the 192 old rows and 1.7 ms to place the new ones. Reading and validating the keys took 0.1 ms. This locates the largest cost in teardown. The timers include framework and browser work inside each loop. [Original row-phase timings](benchmarks/renderer-compiled-grid-phases.json)

The original runtime constructed a frozen lifetime and a native `AbortController` for each scope and aborted it on removal, including plain tiles without async work. The runtime now constructs them when code first requests the lifetime or a user startup callback receives it. Scopes that expose a lifetime retain cancellation and cleanup ordering. The browser regression mounts, replaces and disposes passive keyed rows. It observed six controller allocations before the change and zero afterward. [Runtime](../src/modules/dom.js) · [Regression fixture](../testdata/ui/keyed.jsx)

Six rotating rounds compared the saved original bundle, the changed bundle and React with identical 192-cell windows. Medians are in milliseconds on the same shared machine. Both Saba bundles have the same authored JSX and compiler. [All 18 visits, DOM counts and bundle hashes](benchmarks/renderer-compiled-grid-lifetimes.json)

| Disjoint jump | Row replacement | Click to final-row paint |
| --- | ---: | ---: |
| Compiled Saba before | 18.30 | 47.60 |
| Compiled Saba with on-demand lifetimes | 9.65 | 41.75 |
| React | 5.80 | 36.85 |

The change reduced replacement and paint time in all six matched rounds. React still led on both clocks in every round. Both renderers produced 192 cell elements and 192 text nodes. Saba also kept 770 comment nodes, two per keyed row, two per dynamic child, and two around the list. React used zero comments. This count motivated the compiler specialization measured below.

### Compiler specialization for text rows

The compiler now recognizes the existing tile's string expression. It emits a tracked write to one text node. When the rendered row is a passive intrinsic element with that single binding, the element serves as its own movable boundary. Key validation, updates from replacement records and preparation of new rows still use the public keyed-list implementation. On a jump from the start to the end of the grid, this removes the four per-cell markers that the preceding run counted. [Authored tile](../benchmarks/frameworks/rich/scale-saba.jsx)

Twelve rotating rounds compared the previous on-demand-lifetime bundle, the specialized bundle and production React on the same million-record buffered grid in Chromium 145 on an M1 Max. All 36 visits verified the same final cell after updating 10,311 records. The source JSX was unchanged. Times are medians in milliseconds. [Raw visits, DOM counts and served bundle hashes](benchmarks/renderer-compiled-text-rows.json)

| Renderer | Initial view painted | Sparse update painted | Replace 192 cells | Jump click to paint | Comments in destination window |
| --- | ---: | ---: | ---: | ---: | ---: |
| Previous compiled Saba | 121.15 | 75.40 | 8.20 | 39.65 | 770 |
| Specialized compiled Saba | 115.55 | 68.30 | 5.20 | 35.05 | 2 |
| React | 115.15 | 76.75 | 4.70 | 34.45 | 0 |

The specialization replaced the cells sooner than the previous Saba bundle in 12 of 12 rounds and painted the jump sooner in 11. React's paired median lead over specialized Saba was 0.50 ms for replacement and 0.95 ms through paint. All three produced 192 cell elements and 192 text nodes. The minified Saba grid bundle grew from 12,552 to 13,678 uncompressed bytes. Module transfer and startup are outside these grid clocks.

### Startup and cleanup for cells with one text child

When a cell connects, Saba now checks its live children after starting the scopes on the element. A single text child needs a startup visit only if a component has registered a scope on it. During removal Saba checks the owners on that text node and then on the element directly. This avoids building arrays of children for every simple cell. Nested elements, siblings and detached empty text retain the traversal needed to release all their owners, including siblings moved by a cleanup callback. The JSX and the keyed list API are unchanged. [Runtime](../src/modules/dom.js) · [Browser regressions](../testdata/ui/keyed.jsx)

Eighteen rotating rounds on an M1 Max compared the saved text-row build, the new build and production React in fresh Chromium 145 processes. All 54 visits updated 10,311 records and verified cell 999,999 in a 192-cell window. Times are medians in milliseconds. [Raw timings, bundle hashes and final DOM counts](benchmarks/renderer-text-lifecycle.json)

| Renderer | Initial view painted | Sparse update painted | Replace 192 cells | Jump click to paint |
| --- | ---: | ---: | ---: | ---: |
| Previous compiled Saba | 95.50 | 62.40 | 4.30 | 33.00 |
| Compiled Saba with live child checks | 89.95 | 58.10 | 3.70 | 32.55 |
| React | 98.35 | 62.10 | 3.75 | 29.40 |

Saba reduced median synchronous replacement time by 14% and improved in all 18 matched rounds. Against React, Saba finished replacement sooner in ten rounds, tied at the timer's resolution in four, and finished later in four. The click-to-paint results split nine rounds each, with a paired median advantage of 1.10 ms for React. The minified Saba grid bundle grew by 241 uncompressed bytes to 13,919 bytes. These clocks start after the modules have loaded.

In a second experiment the viewport scrolled down and back in eight-row steps. The shared window controller issued 31 refills over 32 steps. At least 192 cells retained their DOM identity across every step. The driver checked every mounted cell's ID and score and verified that outgoing cells disconnected. Across nine rotating rounds the median total time inside the renderer for all 31 refills was 28.5 ms for previous Saba, 24.0 ms for the new build and 20.8 ms for React. Saba improved in every round, and React retained the lead in every round. These totals exclude scroll dispatch, layout verification and paint. [Per-refill timings, driver source and reproduction instructions](benchmarks/renderer-text-lifecycle-scroll.json)

### How quickly can this grid update?

Twelve rotating rounds compared six implementations on the same M1 Max in Chromium 145. Each of the 72 visits jumped between two disjoint 192-cell windows after a sparse update to a million-record model. A fresh page then scrolled down and back. Each of 31 window refills retained 192 cells and introduced 64. The driver checked every cell's ID, class and score, the element and text identity of retained cells, and the final cell by hit test. Each implementation built or updated the destination on demand. [Raw timings, identity checks, reference implementations and replay instructions](benchmarks/renderer-grid-speed-references.json)

| Implementation | Replace 192 cells | Total across 31 refills | Jump click to marker paint |
| --- | ---: | ---: | ---: |
| Current compiled Saba | 4.25 ms | 33.00 ms | 32.30 ms |
| Production React | 4.60 ms | 29.00 ms | 36.30 ms |
| Fixed cell with Saba signals and arbitrary keys | 1.55 ms | 16.90 ms | 29.95 ms |
| Direct DOM, fresh elements for incoming IDs | 0.70 ms | 9.65 ms | 30.55 ms |
| Bulk numeric HTML, fresh elements for incoming IDs | 0.50 ms | 9.30 ms | 30.30 ms |
| Recycled elements and text nodes | 0.25 ms | 8.60 ms | 27.15 ms |

All values are medians. The fixed-cell reference uses Saba's production signal, effect and batch implementations. It validates distinct string or finite numeric keys, prepares fresh rows before touching the committed list, and preserves independently tracked score getters. It passed separate browser checks for mixed-key reordering, dependency changes, failed preparation and subscription teardown after every timed visit. It assumes exclusive ownership of the grid container and a known cell shape. General component scopes, refs and nested content added later still require lifecycle handling in the framework.

The direct DOM and bulk HTML references assume consecutive numeric IDs and immutable plain numeric scores. New keys receive new elements. The recycling reference changes the identity contract. After a disjoint jump an external reference to any of the original 192 cells points to an element now displaying another record. It kept all 192 element and text pairs on every jump. These timings establish achievable costs for these specific contracts and hardware. Presentation also includes scroll dispatch, browser layout and frame timing.

### Record keys and recycled slot keys in React and Saba

An eight-column telemetry grid displays one cell per record, each with a `data-id` and a text node containing its ID and score. The jump replaces IDs 0–191 with 999808–999999. The stock React and Saba tiles are keyed by record ID. Two experimental JSX adapters instead used the same physical slot allocator, keeping each overlapping record in its previous slot. React rendered its memoized tile via the same synchronous root commit. The Saba slot tile tracked a changing ID attribute and changing text. The direct DOM reference rebound the same slots with explicit attribute and text writes. [Stock React JSX](../benchmarks/frameworks/rich/scale-react.jsx) · [Stock Saba JSX](../benchmarks/frameworks/rich/scale-saba.jsx)

Ten rotating rounds in fresh Chromium 145 processes on an M1 Max verified 50 jumps and 1,550 overlapping window refills. Times are medians. The jump and refill clocks measure synchronous renderer work. Presentation uses the visible status marker, followed by a separate hit test of the final cell. [Raw timings, slot JSX, shared allocator and mutation audit](benchmarks/renderer-grid-slot-keys.json)

| Implementation | Jump across 192 cells | Total across 31 refills | Jump click to marker paint |
| --- | ---: | ---: | ---: |
| Saba, record keys | 3.10 ms | 24.65 ms | 28.45 ms |
| Saba, recycled slot keys | 0.90 ms | 21.40 ms | 27.10 ms |
| React, record keys | 3.45 ms | 21.55 ms | 29.30 ms |
| React, recycled slot keys | 1.40 ms | 21.60 ms | 26.85 ms |
| Direct DOM, recycled slots | 0.20 ms | 6.80 ms | 27.55 ms |

An independent DOM mutation audit observed both stock renderers remove 192 elements and insert 192 new ones on the jump. All three recycling renderers kept all 192 elements and text nodes. Each performed 192 writes to `data-id` and 192 writes to the existing text, with zero element moves. React still called the changed tiles and reconciled their output. Saba still validated keys and propagated record changes through the two reactive bindings on each tile. The direct implementation used a single loop over known element and text references. The clocks measure these paths as a whole.

Overlapping scrolls can require reordering even with stable slots. In the audited backward shift of 64 cells, the React and Saba slot adapters each moved 192 existing cell elements into order. The direct recycler moved 64. With slot keys, references and component-local state follow the slot across a record change. A stateful view must account for that when displaying a different record. [React's key and state model](https://react.dev/learn/preserving-and-resetting-state#option-2-resetting-state-with-a-key)

#### Work inside one recycled Saba jump

An untimed trace of the compiled slot adapter counted 192 key validations, 192 row lookups and 192 placement checks. Every row stayed in place. Updating the 192 row signals ran 192 ID bindings and 192 text bindings. The list observer and the 384 bindings each allocated a fresh map of the signals read during evaluation. No row or subscription was created during the jump. The DOM observer counted 192 attribute writes and 192 text writes. [Reactive evaluation](../src/modules/dom.js) · [Counters and benchmark source](benchmarks/renderer-slot-binding-work.json)

In a separate 15-round experiment, the allocator told the keyed list when the exact same array of physical slots covered a disjoint destination. A temporary runtime then passed each new record to its existing signal in the same order, bypassing the general list pass while retaining both reactive bindings. Median synchronous replacement times were 0.80 ms for compiled Saba, 0.60 ms for this diagnostic and 0.20 ms for the direct loop. The diagnostic finished sooner than the original in 11 matched rounds and tied in four, saving a paired median of 0.10 ms. The remaining paired median gap to the direct loop was 0.50 ms. That gap includes signal propagation, dependency tracking, expression evaluation and general DOM writers. Individual costs within that group were not timed. [45 checked visits, exact diagnostic diff and bundle hashes](benchmarks/renderer-slot-binding-work.json)

## Compiled slot windows

The Odin compiler can now generate a direct writer for a passive JSX row. The application opts into recycling with `mountSlotWindow(band, Tile)` and supplies a contiguous logical start plus the visible records. The runtime retains the overlapping positions, reuses outgoing cells at the entering edge, and sends each changed scalar snapshot to the generated writer. For the grid tile that writer sets `data-id` and writes the existing text node. The DOM regression counted zero moves for a disjoint 192-cell jump and exactly 64 moves for a 64-cell shift of a 256-cell window in either direction. Getters still establish subscriptions when a record reaches a tracked binding. [Authored JSX](../benchmarks/frameworks/rich/scale-saba-window.jsx) · [Browser regressions](../testdata/ui/slot-window.jsx)

Eight rotating rounds in fresh Chromium 145 processes on an Apple M1 Max used one million local records, a disjoint jump to the last 192 cells and a separate scroll journey with 31 overlapping refills. Every implementation received the same ordinary immutable inputs. The new adapter converted newly visible records into scalar snapshots inside the renderer clock and kept a cache bounded by the current window. The previous Saba, React and hand-written controls are byte-identical to their slot-recycling counterparts in the preceding comparison. The driver checked every displayed ID, score and text node, retained identities at each refill, and the destination hit test. [Raw visits, hashes, clocks and replay sources](benchmarks/renderer-compiled-slot-window.json)

| Median over eight rounds | Replace 192 cells on jump | Total renderer time for 31 refills | Jump click to marker paint |
| --- | ---: | ---: | ---: |
| Compiled Saba slot window, including snapshot preparation | 0.50 ms | 7.55 ms | 26.75 ms |
| Previous Saba with recycled slot keys | 0.60 ms | 14.00 ms | 27.80 ms |
| React with recycled slot keys | 0.90 ms | 14.85 ms | 28.55 ms |
| Hand-written recycled DOM loop | 0.20 ms | 4.85 ms | 27.15 ms |

Saba used less renderer time than the previous slot adapter for the 31 refills in all eight paired rounds. On the jump, it finished sooner in four rounds and tied in four at the timer’s resolution. The new renderer beat the React slot adapter on both renderer clocks in all eight rounds. On click-to-paint it finished ahead of React in five. Scroll delivery and browser presentation account for much of that clock, and these visits establish a more consistent improvement in synchronous work than in visible latency.

Within the same adapter, the interval after scalar snapshots were ready was a median **0.30 ms for the jump and 5.25 ms across the 31 refills**. This isolates what a caller with already-normalized data pays for the window replacement. The primary table includes the work of certifying incoming fields and indexing the snapshots. The hand-written reference knows its input schema and writes directly from those records. The separately timed intervals have independently computed medians. [Adapter and timing boundary](../benchmarks/frameworks/rich/scale-saba-window.jsx)

The normal Taskfile benchmark also ran four buffered visits per implementation. Its synchronous jump medians were 0.50 ms for the compiled slot window, 2.05 ms for ordinary record-keyed Saba and 2.10 ms for record-keyed React. The record-keyed adapters create fresh nodes for a disjoint destination and preserve the lifetime semantics of their record keys. These runs covered a million records with a bounded DOM. [Taskfile visits](benchmarks/renderer-compiled-slot-window.json)

## Reproduction

Use the project's pinned npm dependencies and Playwright's full Chromium. If the temporary fixtures cannot resolve Playwright, set `PLAYWRIGHT_PATH` to the package's absolute path. Run each browser experiment separately. Give the heap collector an empty directory. It writes snapshots and a compact `renderer-cell-heap.json` report there.

To test a renderer change against its previous version, save the generated `benchmarks/frameworks/dist/scale/saba-compiled.js` before editing the runtime. Add `saba-baseline` to the grid command's mode list and pass `--saba-baseline /path/to/saved.js`. The driver reports the hash of the bundle it served for each version.

```sh
(cd benchmarks/frameworks && npm ci && node build.mjs --scale)
task bench:scale -- --scenarios buffered --modes saba-compiled,react --trials 12 --out /tmp/compiled-grid.json
task bench:scale -- --scenarios buffered --modes saba-compiled-window,saba-compiled,react --trials 4 --out /tmp/compiled-slot-window.json
python3 benchmarks/frameworks/experiments/drag.py --strategy hint --trials 12 --out /tmp/drag-hint.json
python3 benchmarks/frameworks/experiments/drag.py --strategy snapshot --trials 12 --out /tmp/drag-snapshot.json
node benchmarks/frameworks/experiments/text-slot.mjs /tmp/text-slot.json 1000000 3
node benchmarks/frameworks/experiments/text-slot.mjs /tmp/cell-binding.json 1000000 3 --profile-binding
node benchmarks/frameworks/experiments/text-slot.mjs /tmp/cell-attribute.json 1000000 3 --profile-attribute
node benchmarks/frameworks/experiments/cell-heap.cjs /tmp/saba-cell-heap-snapshots
node benchmarks/frameworks/experiments/verify-text-band.cjs
node benchmarks/frameworks/experiments/text-slot.mjs /tmp/text-band.json 1000000 4 --profile-band
node benchmarks/frameworks/experiments/cell-heap.cjs /tmp/saba-band-heap-snapshots saba-fixed-input-attr,saba-band-text,saba-band-dom
node benchmarks/frameworks/experiments/band-size.mjs /tmp/text-band-size.json
node benchmarks/frameworks/experiments/band-edits.cjs /tmp/text-band-edits.json
```
