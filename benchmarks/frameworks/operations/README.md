# Mesa v2 Operations smoke test

This harness opens the live, read-only Operations screen in Chromium. It serves the Spanish Desk assets from Mesa commit `7bc8044ab02c2daf23bab432c325b39a99d6da7d` and supplies deterministic session, catalog and paginated Operations responses on loopback. `MESA_REPO` points to a checkout containing the commit. The harness reads its Git objects and keeps generated files in a temporary directory.

The Desk baseline executes the original JavaScript. Both candidates keep the same shell, authentication checks, source selection, loader, cache, sorting, filtering and navigation. They replace the live table rows and status controls. Saba compiles authored JSX with the checkout’s Odin transform and uses its browser runtime. Solid uses its production compiler and pinned packages from `benchmarks/frameworks/package-lock.json`.

Install the framework benchmark dependencies with `npm ci` in `benchmarks/frameworks`. Run from the repository root with Node 22 or later, Odin and Playwright Chromium available.

```sh
MESA_REPO=/path/to/bot-mesa node benchmarks/frameworks/operations/run.mjs /tmp/operations-smoke.json
```

Use `PLAYWRIGHT_PATH` for an external Playwright installation, `SABA_CHROME` for a particular Chromium executable, and `ODIN` for the compiler path when needed. `WEBTOOLS_SHARED` selects an existing collection with the pinned Kessel. By default the harness invokes `krs install --frozen` in a temporary root.

The smoke compares all displayed cells across first load, load-more, refresh, same-document Back, retry and reload. It exercises access denial, session expiry, keyboard selection and search. The report records cumulative Operations request counts, retained DOM nodes and focus. The versions share Mesa’s existing data loader, so the warm Back result reflects that cache. A production latency comparison needs repeated cold and warm runs, representative data and an agreed improvement threshold. [Recorded behavior](smoke.json)

## Repeated timing trials

Pass `--rounds N` to run one excluded warm-up per renderer, then N visits per renderer. Each visit opens a fresh browser context and exercises cold entry, load-more, refresh and same-document Back in that order. The renderer order rotates and reverses across visits. For timing, both candidate renderers ship as single minified bundles alongside the original Desk modules. The behavior smoke also exercises Saba’s directly served compiler output.

```sh
MESA_REPO=/path/to/bot-mesa node benchmarks/frameworks/operations/run.mjs /tmp/operations.json --rounds 30 --profile constrained
```

The default desktop profile uses native CPU and network speeds. The constrained profile sets 4× CPU throttling, 60 ms network latency, 10 Mbit/s download and 5 Mbit/s upload. The browser measures from navigation start, the button’s click event or the call to browser Back until one animation frame after the expected rows and ready controls are visible. This provides a frame-based approximation of presentation. The JSON includes raw visits, median and nearest-rank p95 for each action, completed resource transfer bytes and request counts, Operations API request counts, and post-GC heap usage after returning to Operations. Keep the agreed improvement threshold, data volume and profile with any adoption comparison.
