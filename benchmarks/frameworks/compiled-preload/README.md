# Cold startup with compiled module preloads

This experiment opens Saba’s compiled `/items/42` editor directly in Chromium. The Odin origin builds the same JSX used in the browser acceptance suite, including its real attachment, editor and mutation modules. It serves a fixed session and item response on loopback. Each pair uses one generation. The hinted document uses exactly the links the compiler emitted. Removing just those link tags must recreate the entire control document byte for byte. Both visits use the same entry and module URLs. [Authored item form](../../../tests/fixtures/ui/item.jsx) · [Odin origin](origin/main.odin)

## Run it

Use Node 22 or newer, Playwright with Chromium installed, and the Odin and Krs toolchains configured for this checkout. For a standalone Playwright installation matching the recorded run, install it outside the repo and point the driver at it.

```sh
npm install --prefix /tmp/saba-preload-tools playwright@1.58.2
/tmp/saba-preload-tools/node_modules/.bin/playwright install chromium
export PLAYWRIGHT_PATH=/tmp/saba-preload-tools/node_modules/playwright
node benchmarks/frameworks/compiled-preload/run.mjs /tmp/preload-negotiated.json --pairs 12
node benchmarks/frameworks/compiled-preload/run.mjs /tmp/preload-identity.json --pairs 12 --document-coding identity
```

`ODIN` selects the compiler executable, `SABA_CHROME` selects a browser executable and `WEBTOOLS_SHARED` selects an existing Odin dependency collection. With no collection override, the driver invokes `krs install --frozen` in its temporary directory. The Taskfile entry accepts the same arguments. [Project toolchain setup](../../../docs/SABA_UI_ROADMAP.md#test-entry-point)

## Method

Each experiment uses one headless Chromium process. Each visit gets a new browser context, no HTTP cache, and a 1280 × 800 viewport. Each run excludes one warm-up pair and alternates the arm that goes first across measured pairs. DevTools emulates 60 ms network latency, 10 Mbit/s download, 2 Mbit/s upload and 4× CPU slowdown over HTTP/1.1.

The browser’s navigation clock measures the first animation frame when the original visible title field is enabled, contains the authorized record value `Lamp`, and the attached page has hidden its recovery link. The following frame provides a paint opportunity. A real edit after measurement must enable Save. Origin counters surround each visit. Every generated startup dependency, the entry, the document and the two API resources must be requested exactly once. The report includes decoded body hashes, encoded document sizes and per-visit counts. [Browser driver](run.mjs)

The normal run uses Saba's production compression selection. The identity control forces both HTML responses to use identity coding while preserving the production choices for every JavaScript response. The two runs generate independent build IDs. Each comparison pairs visits within a single build.

## Recorded measurements

With both HTML documents served as identity, the editor became eligible in a median **452.8 ms without hints** and **366.0 ms with hints**. The median paired saving was **86.6 ms**, and every measured pair improved. The following-frame medians were 459.7 and 372.4 ms respectively. The hints added 723 HTML bytes, increasing the document from 648 to 1,371 bytes. Seven dependencies, one entry, the document and the two API resources each reached the origin exactly once on every visit. [Identity-coding trials](identity.json)

The negotiated run on Apple M1 Max and headless Chromium 145.0.7632.6 reached an editable form in a median **461.2 ms without hints** and **368.4 ms with hints**. All 12 pairs improved. The median paired saving was **91.6 ms**. The request counts matched the identity experiment. [Negotiated-coding trials](result.json)

The control HTML fell below Saba’s 1 KiB compression threshold and transferred 648 identity bytes. The larger hinted HTML qualified for compression and transferred 353 bytes. The negotiated result includes both the discovery change and this change in document transfer size. This synthetic form measures cold startup on the stated profile. The fixed session and item responses exclude production database and identity-service latency.
