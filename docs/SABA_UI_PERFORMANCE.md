# Legacy Mesa sheet and synthetic Saba form benchmarks

This benchmark follows three user actions. Open an editor, type into it with 1,000 records loaded, then save and wait for the server-confirmed value to reach the visible lists. The sheet harness edits the synthetic `Title` cell of row 1 using Mesa’s legacy sheet module. The separate Saba fixture edits `bench_items.title` for item 42. Both datasets belong to the benchmarks. Mesa v2’s product workflows live in its web UI.

## Legacy sheet benchmark

The application baseline loads the unmodified sheet module and stylesheet from Mesa commit `6587213d1b8717cdc8807bcbbc3816477db946e9`. A loopback service supplies synthetic records, the catalog and save responses. Mesa fetches pages of 200. At the typing checkpoint it has fetched 1,000 records and mounted 200 rows. On a successful save it reloads the first page. The benchmark runs the sheet in isolation from the rest of the authenticated application.

Times are **median / p95 in milliseconds**, with 20 cold contexts per profile.

| Profile | First cell edit-eligible | Keystroke to frame | Tab to confirmed cell in DOM | Save requests |
| --- | ---: | ---: | ---: | ---: |
| Desktop | 47.0 / 78.9 | 20.1 / 24.4 | 25.4 / 35.0 | 2 |
| Constrained | 436.2 / 451.3 | 31.4 / 36.4 | 216.0 / 221.2 | 2 |

**Enter and Tab produced different outcomes.** Tab committed the typed value, performed a refresh GET and displayed the canonical server value. Enter displayed a success message but reopened the editor with its previous value. In the captured case the input showed `Item 1` while the synthetic server held `Saved quicktype`. The Enter handler finished editing, then the same key event bubbled to the cell and started another edit. The refresh path skips loading while an edit is active. This case is a failed save-to-fresh journey and has no successful latency. [Captured Enter result](benchmarks/mesa-sheet-enter.json)

In the constrained sheet benchmark, typing reached its next frame within 36.4 ms at p95, while opening the first cell took 451.3 ms at p95. The sheet’s `refresh()` waits for the catalog before requesting the selected page. A focused application experiment would deliver the first authorized page with its catalog selection and compare time to the same editable cell, including transfer size and empty or unauthorized selections.

## Matched Saba comparison

The two historical paths ran the same Saba Odin HTTP server and used the same HTML structure, CSS, data, request sequence and disk-backed SQLite database. The current path constructs the screen with the checkout’s real `mount` and JSX runtime and maintains keyed nodes by hand. The prototype attaches to a static form and uses tracked effects, per-row signals and a tab-session operation journal. This exercises the proposed rendering mechanisms. That historical measurement predates the production compiler, generated artifacts, scheduler and cross-navigation recovery.

The 1,000 distinct items initially render 1,500 row instances across three visible lists. The editor can accept typing as soon as its detail read completes. The typing checkpoint separately waits for all three lists to settle. Ten trusted keystrokes update the input and its visible draft preview. Submitting a title beginning with `!` adds item 42 to the third list. Each trial checks its presence and title in all three lists, revision 2, and the retained DOM identity of the existing rows.

Times are **median / p95 in milliseconds**. Each request count covers one successful save.

| Profile | Screen | Editable | Ready painted | Key to frame | Save to fresh DOM | Save to painted | Requests |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Desktop | Current Saba mount | 46.3 / 59.0 | 88.0 / 100.0 | 26.4 / 27.9 | 10.6 / 51.7 | 66.9 / 80.3 | 5 |
| Desktop | Reactive prototype | 41.2 / 69.7 | 80.0 / 92.0 | 26.4 / 28.0 | 47.1 / 59.1 | 73.4 / 86.0 | 5 |
| Constrained | Current Saba mount | 308.9 / 330.2 | 332.0 / 356.0 | 26.9 / 35.0 | 214.5 / 221.4 | 239.6 / 251.0 | 5 |
| Constrained | Reactive prototype | 351.7 / 377.5 | 376.0 / 400.0 | 27.1 / 35.0 | 215.1 / 227.0 | 239.7 / 256.3 | 5 |

## Where the time goes

**Typing.** The prototype and the handwritten screen both reached roughly 28 ms at desktop p95 and 35 ms under throttling. Comparing the median of each navigation's ten keys within its matching pair gave a difference below 0.4 ms in either profile. These numbers support retaining fine-grained bindings for this editing workload. Filtering all 1,000 records on each keystroke would be a different workload.

**Opening the editor.** Under throttling, the prototype needed about 39 ms longer to enable editing in the median matched pair. The difference between its presented Ready marker and the current screen's marker was 42 ms in the median pair. Desktop showed a small median advantage for the prototype and a slower p95 for enabling the field. Early static HTML and an editable field are separate milestones.

A separate 12-pair navigation trace reproduced the delay on every pair. On the current screen the browser started fetching the first shared module a median 4.9 ms after the entry response finished. The prototype waited 43.1 ms at that point. The shared application module and runtime had identical bytes. The detail request itself took about 65 ms in both modes, and both enabled the input less than 4 ms after its response. This localizes the gap to shared module discovery before component attachment. The trace records scheduling and request timings without assigning an internal browser cause. [Startup trace](benchmarks/saba-startup.json) · [Diagnostic driver](../benchmarks/mesa/startup.cjs)

**A measured startup improvement.** A second 12-pair experiment ran the same planned page twice. One version added `rel="modulepreload"` for its two unconditional dependencies, `/app.js` and `/__saba/dom.js`. On constrained cold navigation, median time to editable fell from **333.9 to 260.2 ms**. Every pair improved, with a median paired saving of **70.9 ms**. Median time until all three lists were ready fell from 415.7 to 346.3 ms. The HTML grew by 24 encoded body bytes. Each dependency transferred once, and both arms fetched the same four API resources. This is a candidate for compiler-generated, generation-specific preload links. Validate it on actual routes and warm caches before adopting it broadly. [Preload experiment and raw timings](benchmarks/saba-preload.json)

**Saving.** Every Saba save produced one PATCH, one detail GET and three list GETs. Together the five API responses carried **67,367 encoded body bytes**. This excludes request bodies, headers, the page and its static assets. On the constrained prototype the median PATCH acknowledgement arrived at 72 ms. The last response completed at 198 ms, the three lists were current at 215 ms, and the Saved marker was presented at 240 ms. The direct, per-trial median delay between acknowledgement and current DOM was 142 ms. There is useful room to shorten the refresh path even when the write itself must remain durable.

For an implementation experiment, use the canonical item already returned by PATCH to update the detail view. Have the server identify changed list memberships or return revisioned list changes for views it can resolve, with a full refresh available for unknown filters, pages or revisions. Run the same entering-filter scenario and require all three lists to reach the confirmed revision. For the legacy sheet benchmark, make Enter commit once and confirm the same state as Tab before treating Enter as a successful performance sample.

## Generated JSX editor on the same workload

This first compiler measurement mounted every row in the three lists. The separate [buffered-list comparison](#compiled-editor-with-a-sliding-window) exercises the design's fixed-height window on this same editor.

The authored form runs through `pages.prepare_pages` and attaches to its generated document. In this historical run its eight generation-qualified modules included Saba’s editor, mutation journal, shared-read cache and keyed-list renderer. The comparison arm runs the historical reactive prototype on the same server. Each arm reads the detail and three lists, sends one durable PATCH and refreshes the same four resources. Every trial checks the ten trusted keys and their visible draft echo, all row IDs and titles in order after save, row identity in the two original lists, membership of item 42 in the third list and confirmed revision 2. [Authored form](../benchmarks/mesa/generated.jsx) · [Driver and assertions](../benchmarks/mesa/measure.cjs)

On an Apple M1 Max with Chrome 157.0.8103.80, each profile ran one discarded warm-up pair and 12 measured pairs in alternating order. The values below are milliseconds, shown as p50 / p95. Each startup and save cell has 12 observations, so its nearest-rank p95 is the slowest observation. Each typing cell has 120 key events. [Raw samples, source and served module hashes](benchmarks/saba-generated-editor.json)

| Profile | Implementation | Editable | All lists ready | Key to frame | Submit to fresh DOM | Submit to Saved paint |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Desktop | Prototype | 25.4 / 29.2 | 30.9 / 35.6 | 16.2 / 18.9 | 18.3 / 21.2 | 47.6 / 54.0 |
| Desktop | Generated | 51.6 / 54.4 | 51.2 / 54.0 | 16.2 / 19.2 | 21.0 / 40.5 | 48.5 / 65.8 |
| Constrained | Prototype | 327.3 / 338.7 | 405.0 / 421.5 | 17.2 / 19.9 | 199.0 / 201.6 | 212.7 / 217.8 |
| Constrained | Generated | 311.8 / 319.9 | 410.3 / 425.3 | 17.2 / 19.5 | 206.1 / 215.7 | 215.9 / 225.0 |

The generated form became editable earlier in every constrained pair and later in every desktop pair. Its encoded startup JavaScript totaled 22,527 bytes against 13,984 bytes for the prototype. The generated page includes compiler preloads and the production helpers. Their individual contributions to these startup timings require separate controls. The constrained PATCH acknowledgement arrived at roughly 72 ms in both arms. The generated form took a median 7.0 ms longer per pair to make all three lists current. This comparison measures one successful save on a cold synthetic route and leaves Mesa v2 product latency, contention, warm navigation and recovery performance unmeasured.

## Compiled editor with a sliding window

The two routes compile the same JSX form, issue the same API requests and use the same SQLite store. The full-list component mounts every record. The windowed component gives each list a scroll area up to 45% of the viewport height, a logical height of 33 pixels per row and eight rows of overscan on either side. Approaching within three rows of the mounted edge triggers a refill. Each mounted row exposes its position and total list length to assistive technology. [Window controller](../src/modules/sliding-window.js) · [Windowed list component](../benchmarks/mesa/lists/windowed/list.jsx) · [Full-list component](../benchmarks/mesa/lists/full/list.jsx)

The fixture starts with 1,000 unique records across 1,500 list memberships. Renaming item 42 adds one membership to the third list. The driver checks the full API responses, the visible IDs and titles in logical order, the edited row’s DOM identity, the confirmed revision and the size of the mounted window after scrolling. All scrolling checks run after the save and paint measurements. [Benchmark driver](../benchmarks/mesa/measure.cjs)

On an Apple M1 Max with Chrome 157.0.8103.80, each profile ran 12 measured pairs in alternating order after one warm-up pair. Each visit used a fresh browser context. The constrained profile used 4× CPU slowdown and 60 ms network latency. Times below are medians in milliseconds. [Raw trials and module hashes](benchmarks/saba-windowed-editor.json)

| Profile | Compiled list | Initial mounted rows | All lists ready | Form editable | Submit to fresh DOM |
| --- | --- | ---: | ---: | ---: | ---: |
| Desktop | Full | 1,500 | 53.5 | 53.4 | 20.2 |
| Desktop | Windowed | 42 | 39.5 | 39.8 | 18.9 |
| Constrained | Full | 1,500 | 466.5 | 345.3 | 218.4 |
| Constrained | Windowed | 42 | 374.3 | 340.6 | 209.3 |

The windowed lists became ready sooner in all 24 pairs. The median paired saving was 14.3 ms on desktop and 90.9 ms under throttling. Under throttling the form became editable sooner in six of 12 pairs. Both versions fetched 67,228 encoded API body bytes on startup and made the same five requests on save. The windowed version mounted 43 rows after save and at most 61 across the sampled scroll positions, including a jump to the end and back. These counts describe DOM work. Scroll frame times and heap usage were outside this run.

## Re-measurement on 2026-11-25

The JSX compiler's lowering rules changed after the records above. Slot windows are no longer lowered, so `benchmarks/frameworks/fair/saba-slot.jsx` runs on the runtime path. Lowered keyed mounts keep a runtime host guard and scope ownership, and bare `{record().field}` text stays on the runtime. Both benchmarks were run again from `develop` at `f50250a` on the same Apple M1 Max with Google Chrome 158.0.8127.37. The earlier editor record used Chrome 157.0.8103.80 and the earlier fair record used Chrome for Testing 148.0.7778.96. The machine was not idle. Other test suites were running, and the one-minute load average was 8.9 to 17.0 during the editor run and 8.7 to 35.1 during the fair run on 10 cores. Absolute times, and especially p95 values, are therefore less reliable than ratios within a round or pair. [Editor samples](benchmarks/saba-generated-editor-2026-11-25.json) · [Fair samples](benchmarks/renderer-fair-2026-11-25.json)

### Generated editor

`task bench:compiled-editor -- --trials 12 --profiles desktop,constrained`. Times are p50 / p95 in milliseconds. Paired deltas are the median of generated minus prototype within the same pair.

| Profile | Metric | Generated, 2026-11-20 | Generated, 2026-11-25 | Prototype, 2026-11-20 | Prototype, 2026-11-25 |
| --- | --- | ---: | ---: | ---: | ---: |
| Desktop | Editable | 51.6 / 54.4 | 48.8 / 80.6 | 25.4 / 29.2 | 26.1 / 38.8 |
| Desktop | All lists ready | 51.2 / 54.0 | 49.4 / 80.1 | 30.9 / 35.6 | 31.1 / 49.7 |
| Desktop | Key to frame | 16.2 / 19.2 | 16.4 / 18.3 | 16.2 / 18.9 | 16.3 / 19.8 |
| Desktop | Submit to fresh DOM | 21.0 / 40.5 | 20.4 / 22.7 | 18.3 / 21.2 | 18.1 / 61.9 |
| Desktop | Submit to Saved paint | 48.5 / 65.8 | 58.9 / 68.5 | 47.6 / 54.0 | 60.3 / 77.1 |
| Constrained | Editable | 311.8 / 319.9 | 333.2 / 452.0 | 327.3 / 338.7 | 337.9 / 368.0 |
| Constrained | All lists ready | 410.3 / 425.3 | 422.1 / 554.0 | 405.0 / 421.5 | 413.1 / 453.3 |
| Constrained | Key to frame | 17.2 / 19.5 | 17.0 / 19.2 | 17.2 / 19.9 | 17.2 / 20.6 |
| Constrained | Submit to fresh DOM | 206.1 / 215.7 | 209.3 / 219.7 | 199.0 / 201.6 | 202.3 / 240.8 |
| Constrained | Submit to Saved paint | 215.9 / 225.0 | 220.6 / 230.8 | 212.7 / 217.8 | 213.6 / 255.8 |
| Both | Encoded startup JavaScript (bytes) | 22,527 | 31,318 | 13,984 | 18,930 |

The desktop gap to the prototype is unchanged. Generated Saba became editable a paired median 23.4 ms later than the prototype, later in all 12 pairs, against 25.3 ms in all 12 pairs before. Its median moved from 51.6 to 48.8 ms, which is within the noise of this loaded run and is not an improvement to rely on. **The constrained startup advantage mostly disappeared.** Generated Saba used to be editable a paired median 13.8 ms earlier, in all 12 pairs. It is now 3.1 ms earlier and is slower in 5 of 12 pairs. Its startup JavaScript grew by 8,791 encoded bytes (39%), and the prototype, which shares the runtime, grew by 4,946 bytes. The extra bytes are a plausible cause. This run did not isolate them. Typing and save latency did not change beyond noise. The constrained paired list-ready delta rose from 6.2 to 10.8 ms.

### Keyed and slot-window updates

`task bench:fair` with its defaults: 6 rounds, a 2,048-row list, a 256-row window, 12 repetitions and 6 warm-up passes. Every arm passed its checks. Values are medians in milliseconds. Ratios are the median per-round ratio to `vanilla-keyed` for list operations and to `vanilla-slot` for window operations. Every arm, including vanilla, got slower in absolute terms under the new browser and load, so compare the ratios.

| Arm | Metric | 2026-11-21 | 2026-11-25 | Ratio, 2026-11-21 | Ratio, 2026-11-25 |
| --- | --- | ---: | ---: | ---: | ---: |
| saba-slot | Window jump | 0.26 | 1.46 | 2.74× | **14.16×** |
| saba-slot | Window shift | 0.10 | 0.19 | 2.18× | 3.20× |
| saba-slot | Window mount | 0.85 | 1.25 | 3.42× | 2.70× |
| saba-slot | Mount 2,048 | 6.5 | 30.8 | 2.56× | **7.81×** |
| saba-slot | Dense update | 2.50 | 16.85 | 2.10× | **7.24×** |
| saba-slot | Reverse | 1.35 | 14.43 | 1.23× | **9.52×** |
| saba-slot | Rotate | 1.34 | 12.30 | 4.82× | **35.20×** |
| saba-slot | Splice | 0.40 | 1.55 | 1.31× | 3.92× |
| saba-slot | Heap after mount (bytes) | 1,490,058 | 6,053,698 | | |
| saba-keyed | Mount 2,048 | 13.0 | 4.25 | 5.14× | 1.12× |
| saba-keyed | Dense update | 2.03 | 1.99 | 1.71× | 0.92× |
| saba-keyed | Splice | 0.66 | 0.55 | 2.14× | 1.31× |
| saba-keyed | Window jump | 1.16 | 0.40 | 12.20× | 3.96× |
| saba-keyed | Heap after mount (bytes) | 4,054,990 | 1,030,293 | | |
| react | Window jump | 0.55 | 0.86 | 5.89× | 8.08× |
| solid | Window jump | 0.53 | 0.69 | 5.66× | 6.28× |

**The slot-window case regressed severely.** With the window on the runtime path, a disjoint jump costs 14 times the hand-written recycler, against 2.7 times before. It is now slower than React (8.1×), Solid (6.3×), Svelte (8.3×) and Preact (9.6×) on the same jump, all of which it beat before. Full-list dense, reverse and rotate updates on the slot arm are 7 to 35 times vanilla, and its heap after mount roughly quadrupled. Record-keyed Saba moved the other way. Its mount, heap and list operations are now within about 1.3× of vanilla-keyed. This run happened under heavy load, so the absolute times should be repeated on an idle machine. Even so, the slot arm's ratios moved far more than any other arm's.

### Not re-measured

`task bench:scale` was not run. Other test suites kept the machine's load average between 38 and 69 for more than 20 minutes after the fair run, and the session ended before the machine became idle. The [compiled slot window](SABA_RENDERER_LOSSES.md#compiled-slot-windows) figures in the losses document (0.50 ms jump and 7.55 ms over 31 refills) are therefore still from 2026-11-20 and predate the change that stopped lowering slot windows. The fair result suggests they no longer hold.

## Conditions and clocks

- One Apple M1 Max, macOS arm64, full Chromium 145.0.7632.6 running headless. Each navigation uses a fresh browser context. The browser process and loopback service stay warm. Desktop uses the machine at its normal speed. The constrained profile applies Chromium’s 4× CPU slowdown, 60 ms network latency, 10 Mbps download and 2 Mbps upload. The latter is a repeatable emulation. Both profiles use local synthetic data and exclude production authentication, TLS, other users and external services.
- The Saba comparison alternates which implementation runs first within each pair. It discards one warm-up pair per profile, then records 30 pairs per profile. Each cell has 30 startup/save samples and 300 paced typing samples. The Mesa sheet uses 20 fresh contexts and nine paced keys per trial in each profile. Percentiles use nearest rank. Keys within a navigation share that navigation’s conditions.
- **Editable** starts at the browser’s navigation time origin. It ends when the Saba input is enabled with its fetched record, or when Mesa’s first cell is present and the sheet reports edit eligibility. For Mesa that happens after the first page. Later interactions verify actual editability. For Saba the separate **Ready painted** column uses the browser’s Element Timing timestamp for a visible status inserted when editing becomes possible.
- **Key to frame** uses each trusted keydown and Chromium’s unrounded Event Timing trace duration, matched to the document event with an interaction ID and recorded commit. This includes input dispatch through the browser’s reported next frame, including fast events that the standard observer may omit. It measures a visible edit and its input echo, with paced keys after the lists settle. Display hardware, startup typing contention and filtering the entire dataset on each keystroke are outside that workload. [Event Timing](https://www.w3.org/TR/event-timing/)
- **Save to fresh DOM** begins at the trusted Tab keydown in Mesa and at submit-handler entry in Saba. It ends when the confirmed value reaches the sheet or all three Saba lists. **Save to painted** on Saba uses the Element Timing timestamp of the visible Saved status, inserted only after the four refreshes have published. Browser timing granularity and frame scheduling apply. The Mesa DOM clock ends before paint.
- Saba uses one SQLite connection, WAL mode, `synchronous=FULL`, a durable operation reservation, then a transaction that commits the value and its receipt. The browser overlaps its refresh requests. SQL work shares one connection. The application runs with a bounded four-worker offload pool. Each trial resets the store and then measures one user. The matched screen loads its two entry variants at the same dependency depth and disables the browser HTTP cache. Production module discovery, warm-cache behavior, multi-user saturation and deployment performance require their own measurements.

## Reproduce

Use Odin with Saba’s shared dependencies, including Kakunou, plus a Node installation with Playwright and its full Chromium browser. Set `PLAYWRIGHT_PATH` to the Playwright package directory if Node cannot resolve it locally. `SABA_BENCH_NODE` selects the Node executable. `SABA_CHROME` can select an installed Chrome or Chromium binary for the matched editor runs. `ODIN` and `WEBTOOLS_SHARED` select the compiler and shared collection. The Odin fixture creates a temporary database, binds to an ephemeral loopback port, launches the browser driver and cleans up the child processes and database.

```sh
task bench:mesa -- --trials 30 --profiles desktop,constrained --out /tmp/saba-mesa.json
task bench:mesa-preload -- /tmp/saba-preload.json
task bench:mesa -- --suite generated --trials 12 --profiles desktop,constrained --out /tmp/saba-generated-editor.json
task bench:windowed-editor -- --trials 12 --profiles desktop,constrained --out /tmp/saba-windowed-editor.json

MESA_CHECKOUT=/path/to/bot-mesa task bench:mesa-sheet -- --profile desktop --trials 20 --out /tmp/mesa-sheet.json
MESA_CHECKOUT=/path/to/bot-mesa task bench:mesa-sheet -- --profile constrained --trials 20 --out /tmp/mesa-sheet-constrained.json
```

Raw samples and machine metadata are available for [matched Saba](benchmarks/saba-mesa.json), [desktop Mesa](benchmarks/mesa-sheet.json) and [constrained Mesa](benchmarks/mesa-sheet-constrained.json). The fixture, source assertions and clock definitions are in the [Odin server](../benchmarks/mesa/main.odin), [browser driver](../benchmarks/mesa/measure.cjs) and [Mesa sheet driver](../benchmarks/mesa/mesa-sheet.cjs).

The [seven-implementation framework comparison](SABA_FRAMEWORK_COMPARISON.md) repeats the editor journey with production bundles for vanilla JavaScript, Solid, React, Svelte, htmx and both Saba paths.
