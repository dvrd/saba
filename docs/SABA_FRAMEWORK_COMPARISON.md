# The same editor in Saba, vanilla JavaScript, Solid, React, Svelte and htmx

Open the synthetic Saba test form, edit item 42 with 1,000 items loaded, then rename it so it enters another visible list. These measurements use seven implementations of that one screen. They include the existing Saba mount path and a hand-authored prototype of the planned reactive compiler output. The earlier measurements exercised the legacy sheet module with synthetic rows. [Sheet benchmark](SABA_UI_PERFORMANCE.md)

Measured before 2026-11-25. The compiler now lowers some keyed and checkbox lists and element-or-nothing holes to direct DOM code, which may change the compiled Saba figures below. They are kept as recorded until new measurements replace them. All runs used Chromium. [Lowering rules](adr/0007-saba-reactive-props-and-bindings.md#shapes-the-compiler-lowers-to-direct-dom-code)

The [project board and million-record grid](SABA_RICH_RENDERING.md) extend this comparison to bulk edits, animated pointer moves and mounted-component capacity.

## Results

On the constrained profile, **current Saba made the field editable first in every round**. The planned Saba prototype was close to Solid and vanilla JavaScript, and opened the field a median 114.6 ms earlier than React when comparing the same round. Current Saba enabled it a median 31.2 ms earlier than the prototype, even with a larger bundle.

Across all seven implementations, constrained median keystroke-to-frame latency spanned only **24.0–24.2 ms**. This editor updates a local draft preview while the lists stay in place. Typing offered little basis for choosing between these implementations.

For the prototype, one confirmed save took **211.8 ms** at the median. Within individual visits, the median interval from PATCH acknowledgement to fresh DOM was **135.2 ms**, and only **6.0 ms** elapsed from the last refresh response to fresh DOM. Together the four reads returned 1,501 list rows and one detail record for a single renamed item. A concrete experiment for Saba is to return the canonical edit and its list membership changes with the PATCH, then run this benchmark with the same ordering, row identity and durability checks.

The htmx implementation transferred slightly fewer bytes per save than the JSON clients. Its median interval from the last refresh response to fresh DOM was **79.1 ms** under throttling. This result applies to the full-list HTML morph used here. An htmx implementation that sends just the affected elements would measure a different update strategy.

Times below are **median / p95 in milliseconds**. The run completed 392 measured editor visits and 3,920 trusted keystrokes in Chromium 145.0.7632.6 on an Apple M1 Max.

### Constrained

| Implementation | Editable | Lists ready | Key to frame | Save to fresh DOM | Saved painted |
| --- | ---: | ---: | ---: | ---: | ---: |
| Planned Saba prototype | 260.3 / 268.5 | 339.6 / 349.1 | 24.2 / 25.7 | 211.8 / 221.1 | 234.8 / 251.5 |
| Current Saba | 230.6 / 240.6 | 304.1 / 312.3 | 24.2 / 25.9 | 208.4 / 213.3 | 232.7 / 245.0 |
| Vanilla JavaScript | 255.3 / 270.2 | 326.0 / 341.0 | 24.1 / 25.9 | 208.7 / 214.3 | 235.6 / 247.1 |
| Solid | 261.9 / 268.9 | 341.5 / 359.9 | 24.2 / 26.1 | 216.8 / 233.8 | 240.2 / 261.7 |
| React | 375.0 / 404.9 | 454.0 / 492.7 | 24.2 / 26.4 | 212.8 / 225.2 | 236.7 / 250.0 |
| Svelte | 266.6 / 274.5 | 345.5 / 356.7 | 24.1 / 26.0 | 213.3 / 223.1 | 236.4 / 245.8 |
| htmx + Idiomorph | 284.5 / 292.6 | 491.9 / 522.7 | 24.0 / 25.8 | 289.7 / 301.3 | 315.4 / 328.4 |

### Desktop

| Implementation | Editable | Lists ready | Key to frame | Save to fresh DOM | Saved painted |
| --- | ---: | ---: | ---: | ---: | ---: |
| Planned Saba prototype | 25.1 / 27.1 | 31.0 / 39.0 | 18.6 / 26.8 | 10.4 / 10.9 | 52.3 / 53.8 |
| Current Saba | 25.5 / 27.6 | 29.6 / 34.9 | 18.7 / 27.0 | 9.9 / 11.5 | 52.5 / 54.5 |
| Vanilla JavaScript | 25.1 / 27.5 | 27.4 / 30.1 | 18.7 / 26.8 | 9.4 / 12.2 | 52.8 / 55.0 |
| Solid | 31.3 / 36.2 | 38.2 / 41.9 | 18.6 / 26.9 | 13.5 / 38.2 | 52.8 / 59.1 |
| React | 55.1 / 57.9 | 55.2 / 58.0 | 18.7 / 26.8 | 10.1 / 12.2 | 52.6 / 53.9 |
| Svelte | 31.9 / 40.1 | 39.5 / 42.3 | 18.7 / 26.9 | 11.6 / 13.1 | 52.6 / 54.6 |
| htmx + Idiomorph | 31.4 / 36.3 | 75.8 / 81.8 | 18.7 / 26.9 | 53.9 / 57.6 | 71.3 / 85.0 |

### Transfer by implementation

Median encoded response bodies in KiB (1,024 bytes). Initial transfer includes the HTML, CSS, JavaScript and the four initial data responses.

| Implementation | JavaScript | Initial transfer | Five save responses |
| --- | ---: | ---: | ---: |
| Planned Saba prototype | 2.4 | 69.6 | 65.8 |
| Current Saba | 3.9 | 70.9 | 65.8 |
| Vanilla JavaScript | 1.2 | 68.4 | 65.8 |
| Solid | 17.8 | 84.8 | 65.8 |
| React | 66.9 | 133.9 | 65.8 |
| Svelte | 22.4 | 89.4 | 65.8 |
| htmx + Idiomorph | 22.2 | 88.6 | 64.9 |

## Why current Saba opened the editor before vanilla JavaScript

The original constrained comparison gave current Saba a 27.1 ms median lead over vanilla in paired rounds for time to an editable field. On desktop, vanilla reached that milestone 0.6 ms earlier in paired rounds. A cold startup trace on the same throttled Chromium found the difference before the first data request. From the end of the module download to its first statement, current Saba waited a median 6.9 ms and vanilla waited 58.5 ms. Once JavaScript started, vanilla requested the item in 6.7 ms and Saba took 15.2 ms. Fetching the item itself took about 64 ms for either implementation.

To isolate the effect of the initial HTML, each implementation ran with an empty host and with the same disabled form already present. Within each implementation the JavaScript bundle was byte-identical across both HTML variants. Saba cleared the host before mounting. Vanilla created the form if the host was empty. Each case ran 12 measured cold navigations. Values are medians in milliseconds.

| Implementation | HTML sent first | Module downloaded to first statement | First content visible | Field editable |
| --- | --- | ---: | ---: | ---: |
| Current Saba | Empty host | 6.3 | 256 | 241.3 |
| Vanilla JS | Empty host | 5.1 | 242 | 228.8 |
| Current Saba | Disabled form | 55.7 | 220 | 284.6 |
| Vanilla JS | Disabled form | 55.6 | 220 | 274.8 |

Shipping the disabled form gave both implementations an earlier first paint. Shipping the empty host let both begin executing JavaScript earlier and request the record sooner. With matching initial content, vanilla made the field editable sooner in both cases. First paint and field eligibility measure different events. A user can see the initial form before the record is available, and a field can become enabled in the DOM before the next paint.

A separate control kept the vanilla bundle and form and moved the module into the document head. Moving it alone left the wait at 58.6 ms. Adding `blocking="render"` to the same head script reduced the wait to 3.3 ms. The field became editable at 227 ms and first content moved from 222 ms to 242 ms. These timings identify a Chromium scheduling effect for this page and profile. The trace does not identify a particular internal scheduler rule. [HTML script blocking attribute](https://html.spec.whatwg.org/multipage/scripting.html#attr-script-blocking)

The observations include the original bundled pages, HTML-only controls, timestamped modules and the initial-HTML crossover. Each case discarded a warm-up, reset SQLite and used a fresh browser context with its HTTP cache disabled. The driver verified the populated field, the four data requests and the three initial row counts. [Startup trace and bundle hashes](benchmarks/saba-vanilla-startup.json)

## What ran

| Implementation | Initial screen and updates |
| --- | --- |
| Current Saba | The checkout’s DOM runtime mounts the screen in an empty host. Handwritten keyed rows retain their nodes. [Implementation](../testdata/mesa_perf/entry.js) |
| Planned Saba prototype | Static form HTML with instance-local target validation. Signals update the form and keyed row text. The future compiler and general-purpose runtime are still planned. [Implementation](../testdata/mesa_perf/planned.js) |
| Vanilla JavaScript | The same static form with native DOM listeners, a key-to-node map and direct text writes. It has no framework dependencies. [Implementation](../benchmarks/frameworks/src/vanilla.js) |
| Solid | A client-compiled component uses native state and a keyed list with row accessors. [Implementation](../benchmarks/frameworks/src/solid.jsx) |
| React | A production client root uses controlled input, keyed rows and memoized list panels so typing leaves unchanged lists alone. [Implementation](../benchmarks/frameworks/src/react.jsx) |
| Svelte | A client-compiled component uses Svelte state and keyed each blocks. [Implementation](../benchmarks/frameworks/src/App.svelte) |
| htmx | A static form declares its requests. Odin returns escaped HTML fragments and triggers four refreshes after a successful PATCH. Idiomorph uses list-local row IDs to preserve nodes. Typing previews the draft locally. [HTML](../benchmarks/frameworks/htmx.html) · [Server fragment rendering](../testdata/mesa_perf/frameworks.odin) |

React, Solid, Svelte and current Saba build their initial UI in the browser. Vanilla, htmx and the Saba prototype receive the blank form in the first document. Every editor fetches its detail record before enabling the field. These startup strategies are part of the measured implementations. Server-rendered or hydrated variants of the client-rendered entries would be separate experiments.

The run used React and React DOM 19.3.1, Solid and its web runtime 2.0.3 with compiler 2.0.2, Svelte 5.58.0, and htmx 2.0.11 with Idiomorph 0.8.0. On save, the planned prototype and the five comparison clients put the pending operation ID in session storage and clear it on acknowledgement. Current Saba omits that client-side journal. All seven perform the same durable server write.

All bundles were built with esbuild in production mode, minified and served locally as a single JavaScript module per implementation. The browser requested one bundle with no CDN or third-party network traffic. The two Saba entries bundle the same source modules used in the earlier study. That study loaded multiple modules and separately tested module preloading. The single bundle here removes that extra discovery step for all seven. [Build script](../benchmarks/frameworks/build.mjs) · [Pinned dependency lock](../benchmarks/frameworks/package-lock.json)

## Workload and clocks

- Each screen shows the same title editor, draft preview and three lists with the same CSS. Initially 1,000 distinct items occupy 1,500 row instances. Item 42 appears in the first two lists and enters the third on save. All implementations issue four initial GETs and one durable PATCH followed by four GETs. The same Odin server and on-disk SQLite store serve every run. htmx requests HTML. The other six clients request JSON.
- **Editable** runs from navigation start until the field is enabled with the fetched record. **Lists ready** runs from navigation start until the initial three lists have committed. The driver waits for both and for the visible Ready status to paint before typing.
- **Key to frame** measures the unrounded Chromium Event Timing trace for each trusted keydown with a recorded frame commit. The input echoes into a visible draft preview. Ten keys are paced with three animation frames between them. There is no list filtering on each keypress. [Event Timing API](https://www.w3.org/TR/event-timing/)
- **Fresh DOM** runs from submit-handler entry until the confirmed detail and all three lists have committed. **Saved painted** ends at the browser-reported presentation of a visible Saved marker inserted after those commits. The harness checks the revision, title and ordered content of all 1,501 final row instances, verifies retained row nodes for item 42 and checks the exact request sequence.
- **JS body bytes** are the browser’s encoded response-body size for the implementation’s bundle. **Save body bytes** sum the five API responses, excluding upload bytes, framing and headers. Static assets use the benchmark server’s negotiated content coding. Data responses use its no-store policy. htmx’s timings include server fragment construction, transfer and browser-side morphing. It could also use a single out-of-band response for a differently designed save.
- Fresh browser context and disabled HTTP cache per visit, warm server and browser process, single user and loopback data. Desktop runs without throttling. Constrained uses 4× CPU throttling, 60 ms emulated network latency, 10 Mbps download and 2 Mbps upload in the same desktop Chromium. Both use a 1,200 × 900 viewport.
- Each profile discards one warm-up visit per implementation, then runs 28 seven-way rounds. Rotations and reversals place every implementation in each execution position four times. Per implementation and profile this gives 28 startup and save observations, and 280 keys clustered within those visits. The p95 uses nearest rank and is the second-slowest observed visit for startup and saves. Single-digit millisecond differences need repeated runs across machines before they support a framework choice.

## Reproduce

Use Odin with Saba’s shared collection, Node 22 or newer, npm, and Playwright with full Chromium. The Taskfile installs the locked compilation dependencies, builds all seven bundles, starts the isolated Odin service and drives Chromium. Set `PLAYWRIGHT_PATH` to a local Playwright package directory if Node cannot resolve it. `SABA_BENCH_NODE`, `ODIN` and `WEBTOOLS_SHARED` select the local tools. Choose a fresh output path when keeping runs for comparison.

```sh
task bench:frameworks -- --trials 28 --profiles desktop,constrained --out /tmp/web-frameworks.json
```

The raw report includes each visit, individual key latencies, package versions, served bundle hashes and benchmark source hashes. [Raw measurements](benchmarks/web-frameworks.json) · [Browser harness](../testdata/mesa_perf/measure.cjs)
