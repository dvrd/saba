import assert from "node:assert/strict";

export function options(args) {
  let rounds = 0, profile = "desktop", output;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--rounds") {
      rounds = Number(args[++i]);
      if (!Number.isSafeInteger(rounds) || rounds < 1) throw Error("Expected --rounds N with N >= 1");
    } else if (args[i] === "--profile") {
      profile = args[++i];
      if (!["desktop", "constrained"].includes(profile)) throw Error("Choose desktop or constrained");
    } else if (!args[i].startsWith("-") && !output) {
      output = args[i];
    } else throw Error("Usage: run.mjs [output.json] [--rounds N] [--profile desktop|constrained]");
  }
  if (profile !== "desktop" && !rounds) throw Error("Set --rounds to enable timing");
  return { rounds, profile, output };
}

// Runs in the browser before Desk or either renderer loads. Use its monotonic
// clock at input dispatch and on animation frames. The driver can collect
// the observation later without adding automation round trips to the clock.
function instruments() {
  const expected = { cold: [1, 2], loadMore: [1, 2, 3], refresh: [1, 2], warmBack: [1, 2] };
  const observations = {};
  function resources() {
    // An open EventSource has no completed Resource Timing entry.
    const entries = performance.getEntriesByType("navigation").concat(
      performance.getEntriesByType("resource"),
    );
    return {
      completed: entries.length,
      transferred: entries.reduce((sum, entry) => sum + entry.transferSize, 0),
    };
  }
  let startOnButton;
  function begin(action) {
    const start = action === "cold" ? 0 : performance.now();
    const baseline = action === "cold" ? { completed: 0, transferred: 0 } : resources();
    const cells = expected[action];
    const valid = () => {
      if (location.pathname !== "/books/operaciones") return false;
      if (document.querySelector("#main h1")?.textContent !== "Operaciones") return false;
      const ready = [...document.querySelectorAll("#main .live-status button")].some((button) =>
        button.textContent === "Recargar"
      );
      if (!ready) return false;
      const rows = document.querySelectorAll("#sheet-body tr.row-link");
      if (rows.length !== cells.length) return false;
      return cells.every((id, i) => {
        const row = rows[i];
        const label = (action === "refresh" || action === "warmBack") && id === 2
          ? "Updated client"
          : "Client " + id;
        return row.cells[0]?.textContent === "OP-" + id && row.cells[1]?.textContent === label &&
          row.cells.length === 9 && row.getClientRects().length > 0;
      });
    };
    function check() {
      if (!valid()) {
        requestAnimationFrame(check);
        return;
      }
      // A second frame gives the first correct visible DOM a paint opportunity.
      requestAnimationFrame(() => {
        if (!valid()) {
          requestAnimationFrame(check);
          return;
        }
        const finish = performance.now();
        const final = resources();
        observations[action] = {
          frameMs: finish - start,
          transferBytes: final.transferred - baseline.transferred,
          completedRequests: final.completed - baseline.completed,
        };
      });
    }
    requestAnimationFrame(check);
  }
  document.addEventListener("click", (event) => {
    if (!startOnButton || !event.target.closest("button")) return;
    const action = startOnButton;
    startOnButton = null;
    begin(action);
  }, true);
  window.operationsTrial = {
    observations,
    arm(action) {
      startOnButton = action;
    },
    back() {
      begin("warmBack");
      history.back();
    },
  };
  if (location.pathname === "/books/operaciones") begin("cold");
}

const profiles = {
  desktop: { cpu: 1, latencyMs: 0, downBytesPerSec: -1, upBytesPerSec: -1 },
  constrained: { cpu: 4, latencyMs: 60, downBytesPerSec: 10_000_000 / 8, upBytesPerSec: 5_000_000 / 8 },
};
const actions = ["cold", "loadMore", "refresh", "warmBack"];
const variants = ["desk", "saba", "solid"];
async function visit(browser, fixture, profile) {
  const context = await browser.newContext({ locale: "es-VE", timezoneId: "America/Caracas" });
  try {
    await context.addCookies([{ name: "pilot-session", value: "local", url: fixture.url }]);
    await context.addInitScript(instruments);
    const page = await context.newPage();
    const cdp = await context.newCDPSession(page);
    if (profile !== "desktop") {
      const config = profiles[profile];
      await cdp.send("Emulation.setCPUThrottlingRate", { rate: config.cpu });
      await cdp.send("Network.enable");
      await cdp.send("Network.emulateNetworkConditions", {
        offline: false,
        latency: config.latencyMs,
        downloadThroughput: config.downBytesPerSec,
        uploadThroughput: config.upBytesPerSec,
      });
    }
    const sample = {};
    let priorOperations = 0;
    async function capture(action, expectedRequests) {
      await page.waitForFunction((key) => Boolean(window.operationsTrial.observations[key]), action);
      const observation = await page.evaluate(
        (key) => window.operationsTrial.observations[key],
        action,
      );
      const count = fixture.calls.filter((url) => url.startsWith("/api/books/operations")).length;
      observation.operationRequests = count - priorOperations;
      assert.equal(observation.operationRequests, expectedRequests, action);
      assert(observation.frameMs > 0 && observation.transferBytes >= 0, action);
      sample[action] = observation;
      priorOperations = count;
    }
    await page.goto(fixture.url + "/books/operaciones");
    await capture("cold", 1);
    await page.evaluate(() => window.operationsTrial.arm("loadMore"));
    await page.getByRole("button", { name: "Cargar más" }).click();
    await capture("loadMore", 1);
    await page.evaluate(() => window.operationsTrial.arm("refresh"));
    await page.getByRole("button", { name: "Recargar", exact: true }).click();
    await capture("refresh", 1);
    await page.locator('button[data-module="mesa"]').click();
    await page.locator('a[data-view="usuario"]').click();
    await page.waitForURL("**/books/usuario");
    await page.evaluate(() => window.operationsTrial.back());
    await capture("warmBack", 0);
    let retainedHeapBytes = null;
    try {
      await cdp.send("HeapProfiler.collectGarbage");
      retainedHeapBytes = (await cdp.send("Runtime.getHeapUsage")).usedSize;
    } catch (error) {
      if (!/not found|unsupported/i.test(error.message)) throw error;
    }
    return { actions: sample, retainedHeapBytes };
  } finally {
    await context.close();
  }
}

function quantile(values, p) {
  return values.toSorted((a, b) => a - b)[Math.ceil(p * values.length) - 1];
}

export async function measure(browser, createFixture, { rounds, profile }) {
  const trials = [];
  // Warm up each implementation once. Rotate the first position and alternate
  // directions so six rounds cover all six possible execution orders.
  for (let round = -1; round < rounds; round++) {
    const index = Math.max(0, round);
    const order = variants.map((_, i) => variants[(index % 3 + (index % 6 < 3 ? i : 3 - i)) % 3]);
    for (const variant of order) {
      const fixture = await createFixture(variant);
      try {
        const sample = await visit(browser, fixture, profile);
        if (round >= 0) trials.push({ round, variant, ...sample });
      } finally {
        fixture.close();
      }
    }
  }
  const summary = {};
  for (const variant of variants) {
    const visits = trials.filter((t) => t.variant === variant);
    const byAction = {};
    for (const key of actions) {
      const rows = visits.map((t) => t.actions[key]);
      byAction[key] = {
        medianMs: quantile(rows.map((x) => x.frameMs), .5),
        p95Ms: quantile(rows.map((x) => x.frameMs), .95),
        medianTransferBytes: quantile(rows.map((x) => x.transferBytes), .5),
        medianCompletedRequests: quantile(rows.map((x) => x.completedRequests), .5),
        medianOperationRequests: quantile(rows.map((x) => x.operationRequests), .5),
      };
    }
    const heaps = visits.map((t) => t.retainedHeapBytes).filter((n) => n !== null);
    summary[variant] = {
      actions: byAction,
      medianRetainedHeapBytes: heaps.length ? quantile(heaps, .5) : null,
    };
  }
  return {
    rounds,
    profile,
    throttling: profiles[profile],
    clock:
      "Browser navigation start/click capture/history.back to one frame after the first correct visible rows",
    bytes:
      "Completed same-origin navigation and resource transferSize including headers; open event stream excluded",
    heap: "V8 used bytes after GC at warm Back",
    trials,
    summary,
  };
}
