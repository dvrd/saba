import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { once } from "node:events";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_PATH || "playwright");
const profile = { latencyMs: 60, downMbps: 10, upMbps: 2, cpuRate: 4 };
const base = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(base, "../../..");
let pairs = 12, documentCoding = "negotiated", output, origin, exited, browser;
const args = process.argv.slice(2);
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--pairs") {
    pairs = Number(args[++i]);
    assert(Number.isInteger(pairs) && pairs > 0, "Expected a positive number of pairs");
  } else if (args[i] === "--document-coding") {
    documentCoding = args[++i];
    assert(["negotiated", "identity"].includes(documentCoding), "Choose negotiated or identity");
  } else if (!args[i].startsWith("-") && !output) output = args[i];
  else {throw Error(
      "Usage: run.mjs [output.json] [--pairs N] [--document-coding negotiated|identity]",
    );}
}

const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
const round = (value) => Math.round(value * 10) / 10;
function median(numbers) {
  const list = [...numbers].sort((a, b) => a - b);
  const mid = Math.floor(list.length / 2);
  return round(list.length % 2 ? list[mid] : (list[mid - 1] + list[mid]) / 2);
}

// The page clock starts at navigation. Record the first frame on which the
// attached, visible input has the authorized record and can receive input.
function installClock() {
  const eligible = () => {
    const input = document.querySelector('input[name="title"]');
    const host = document.getElementById("app");
    return input?.value === "Lamp" && input.matches(":enabled") &&
      !host.inert && !host.hasAttribute("data-saba-pending") &&
      input.getClientRects().length > 0 &&
      document.querySelector("[data-saba-recover]").hidden;
  };
  function check() {
    if (!eligible()) return requestAnimationFrame(check);
    const eligibleFrameMs = performance.now();
    requestAnimationFrame(() => {
      if (!eligible()) return requestAnimationFrame(check);
      window.preloadObservation = { eligibleFrameMs, followingFrameMs: performance.now() };
    });
  }
  requestAnimationFrame(check);
}

async function visit(address, mode, generationPrefix, expected) {
  const counts = async () => {
    const reply = await fetch(address + "/__bench/requests");
    assert(reply.ok);
    return reply.json();
  };
  const context = await browser.newContext({
    serviceWorkers: "block",
    viewport: { width: 1280, height: 800 },
  });
  try {
    await context.addInitScript(installClock);
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    const session = await context.newCDPSession(page);
    await session.send("Network.enable");
    await session.send("Network.setCacheDisabled", { cacheDisabled: true });
    await session.send("Network.emulateNetworkConditions", {
      offline: false,
      latency: profile.latencyMs,
      downloadThroughput: profile.downMbps * 1e6 / 8,
      uploadThroughput: profile.upMbps * 1e6 / 8,
    });
    await session.send("Emulation.setCPUThrottlingRate", { rate: profile.cpuRate });
    const before = await counts();
    const reply = await page.goto(address + "/items/42?hints=" + mode, { waitUntil: "commit" });
    assert.equal(reply.status(), 200);
    await page.waitForFunction(() => window.preloadObservation, undefined, { timeout: 15000 });
    const htmlCoding = (await reply.headerValue("content-encoding")) || "identity";
    if (documentCoding === "identity") assert.equal(htmlCoding, "identity");
    const measured = await page.evaluate(() => {
      const doc = performance.getEntriesByType("navigation")[0];
      return {
        ...window.preloadObservation,
        encodedHTMLBytes: doc.encodedBodySize,
        documentResponseEndMs: doc.responseEnd,
      };
    });
    // Verify the edit event actually reached the compiled binding after timing.
    await page.locator('input[name="title"]').fill("Lamp revised");
    assert(await page.locator('button[type="submit"]').isEnabled());
    assert.deepEqual(errors, []);
    const after = await counts();
    const transfers = {};
    for (const [key, count] of Object.entries(after)) {
      const delta = count - before[key];
      if (delta) transfers[key.replace(generationPrefix, "")] = delta;
    }
    // Greater-than-one catches preload plus entry re-fetch. Exact equality also
    // catches missing startup dependencies or an additional API request.
    assert.deepEqual(Object.keys(transfers).sort(), expected);
    for (const [resource, delta] of Object.entries(transfers)) assert.equal(delta, 1, resource);
    return {
      mode,
      htmlCoding,
      eligibleFrameMs: round(measured.eligibleFrameMs),
      followingFrameMs: round(measured.followingFrameMs),
      documentResponseEndMs: round(measured.documentResponseEndMs),
      encodedHTMLBytes: measured.encodedHTMLBytes,
      originRequests: transfers,
    };
  } finally {
    await context.close();
  }
}

const temp = await mkdtemp(path.join(os.tmpdir(), "saba-preload-"));
try {
  let shared = process.env.WEBTOOLS_SHARED;
  if (!shared) {
    execFileSync("krs", ["install", "--frozen", "--root=" + temp], { cwd: root, stdio: "inherit" });
    shared = path.join(temp, "shared");
  }
  const binary = path.join(temp, "origin");
  execFileSync(process.env.ODIN || "odin", [
    "build",
    path.join(base, "origin"),
    "-collection:shared=" + shared,
    "-out:" + binary,
  ], { cwd: root, stdio: "inherit" });
  const portfile = path.join(temp, "port");
  origin = spawn(binary, [path.join(root, "tests/fixtures/ui"), portfile, documentCoding], {
    stdio: ["ignore", "inherit", "inherit"],
  });
  exited = once(origin, "exit");
  let port;
  for (let attempts = 0; attempts < 500 && !port; attempts++) {
    assert.equal(origin.exitCode, null, "The benchmark origin exited during startup");
    try {
      port = await readFile(portfile, "utf8");
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
      await delay(20);
    }
  }
  assert(port, "Timed out waiting for origin");
  const address = "http://127.0.0.1:" + port;
  const get = async (route) => {
    const reply = await fetch(address + route);
    assert.equal(reply.status, 200);
    return Buffer.from(await reply.arrayBuffer());
  };
  const hintsHTML = (await get("/items/42?hints=on")).toString();
  const controlHTML = (await get("/items/42?hints=off")).toString();
  const link = /<link rel="modulepreload" href="([^"]+)">/g;
  const paths = [...hintsHTML.matchAll(link)].map((match) => match[1]);
  assert(paths.length > 0);
  assert.equal(
    hintsHTML.replaceAll(link, ""),
    controlHTML,
    "An arm differs beyond the generated hints",
  );
  const entry = /<script type="module" src="([^"]+)"><\/script>/.exec(controlHTML)[1];
  const prefix = /^\/__saba\/build\/[^/]+/.exec(entry)[0];
  const api = ["/api/test-session", "/api/items/42"];
  const artifacts = {};
  for (const url of [...paths, entry, ...api]) {
    assert(!Object.hasOwn(artifacts, url.replace(prefix, "")), "Duplicate dependency");
    artifacts[url.replace(prefix, "")] = sha256(await get(url));
  }
  const expected = [...Object.keys(artifacts), "/items/42"].sort();
  browser = await chromium.launch({
    channel: "chromium",
    ...(process.env.SABA_CHROME ? { executablePath: process.env.SABA_CHROME } : {}),
  });
  const trials = [];
  for (let pair = 0; pair <= pairs; pair++) {
    const order = pair % 2 ? ["off", "on"] : ["on", "off"];
    for (const mode of order) {
      const data = await visit(address, mode, prefix, expected);
      if (pair > 0) trials.push({ pair, ...data });
    }
  }
  const off = trials.filter((trial) => trial.mode === "off"),
    on = trials.filter((trial) => trial.mode === "on");
  const summary = {};
  for (const key of ["eligibleFrameMs", "followingFrameMs", "encodedHTMLBytes"]) {
    const differences = on.map((t, i) => t[key] - off[i][key]);
    summary[key] = {
      offMedian: median(off.map((t) => t[key])),
      onMedian: median(on.map((t) => t[key])),
      pairedMedianOnMinusOff: median(differences),
      pairsLowerWithHints: differences.filter((d) => d < 0).length,
    };
  }
  const result = {
    fixture: "tests/fixtures/ui/item.jsx",
    generatedAt: new Date().toISOString(),
    generation: prefix,
    chromium: browser.version(),
    browserChannel: "chromium",
    headless: true,
    documentCoding,
    cpu: os.cpus()[0].model,
    transport: "loopback HTTP/1.1",
    profile,
    pairs,
    excludedWarmupPairs: 1,
    freshContext: true,
    browserCacheDisabled: true,
    controlDocumentSHA256: sha256(controlHTML),
    hintedDocumentSHA256: sha256(hintsHTML),
    startupHints: paths.map((url) => url.replace(prefix, "")),
    entry: entry.replace(prefix, ""),
    sharedDecodedBodySHA256: artifacts,
    summary,
    trials,
  };
  if (output) await writeFile(output, JSON.stringify(result, null, 2) + "\n");
  console.log(JSON.stringify(output ? summary : result, null, 2));
} finally {
  await browser?.close();
  if (origin && origin.exitCode === null && !origin.signalCode) {
    origin.kill();
    await exited;
  }
  await rm(temp, { recursive: true, force: true });
}
