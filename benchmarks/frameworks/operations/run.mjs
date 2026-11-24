import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { createServer } from "node:http";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";
import { transform } from "@solidjs/compiler";
import { withRenderer } from "./desk.mjs";
import { measure, options } from "./measure.mjs";

const args = options(process.argv.slice(2));

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_PATH || "playwright");
const base = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(base, "../../..");
const mesa = process.env.MESA_REPO;
if (!mesa) throw Error("Set MESA_REPO to a bot-mesa checkout containing the pinned revision.");
const commit = "7bc8044ab02c2daf23bab432c325b39a99d6da7d";
const files = new Map();
function file(relative) {
  if (!files.has(relative)) {
    files.set(relative, execFileSync("git", ["-C", mesa, "show", commit + ":web/" + relative]));
  }
  return files.get(relative);
}
const catalog = JSON.parse(file("locales/es.json"));
const escape = (value) =>
  String(value).replace(
    /[&<>"']/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c],
  );
const doc = file("desk.html").toString().replace(
  /\{\{([^}]+)\}\}/g,
  (_, key) =>
    key === "locale"
      ? "es"
      : key === "copy"
      ? JSON.stringify(catalog).replaceAll("<", "\\u003c")
      : escape(catalog[key] ?? key),
);
const native = file("desk.js").toString();
const patched = withRenderer(native);
const temp = await mkdtemp(path.join(os.tmpdir(), "saba-operations-"));
let browser;
try {
  let shared = process.env.WEBTOOLS_SHARED;
  if (!shared) {
    const toolchain = path.join(temp, "odin");
    await mkdir(toolchain);
    execFileSync("krs", ["install", "--frozen", "--root=" + toolchain], {
      cwd: root,
      stdio: "inherit",
    });
    shared = path.join(toolchain, "shared");
  }
  const sabaModule = path.join(temp, "operations.js");
  execFileSync(process.env.ODIN || "odin", [
    "run",
    path.join(base, "compile"),
    "-collection:shared=" + shared,
    "-out:" + path.join(temp, "compiler"),
    "--",
    path.join(base, "saba.jsx"),
    sabaModule,
  ], { cwd: root, stdio: "inherit" });
  const saba = await readFile(sabaModule, "utf8");
  const solid = await build({
    absWorkingDir: base,
    entryPoints: ["solid.jsx"],
    bundle: true,
    minify: true,
    format: "esm",
    platform: "browser",
    conditions: ["browser", "production"],
    target: "es2022",
    write: false,
    define: { "process.env.NODE_ENV": '"production"' },
    plugins: [{
      name: "solid",
      setup(builder) {
        builder.onLoad({ filter: /\.jsx$/ }, async ({ path: filename }) => ({
          contents: transform(await readFile(filename, "utf8"), {
            filename,
            generate: "dom",
            hydratable: false,
            dev: false,
          }).code,
          loader: "js",
        }));
      },
    }],
  });
  const runtime = await readFile(path.join(root, "src/modules/dom.js"));
  browser = await chromium.launch({
    channel: "chromium",
    ...(process.env.SABA_CHROME ? { executablePath: process.env.SABA_CHROME } : {}),
  });
  const results = [];
  let expected;
  for (const variant of ["desk", "saba", "solid"]) {
    const fixture = await start(
      variant,
      variant === "saba" ? saba : solid.outputFiles[0].contents,
      runtime,
    );
    try {
      const output = await exercise(browser, fixture, variant);
      if (expected) {
        assert.deepEqual(output.tables, expected, variant + " projected different row or column data");
      } else expected = output.tables;
      results.push(output.observations);
    } finally {
      fixture.close();
    }
  }
  const report = {
    mesa: commit,
    chromium: browser.version(),
    locale: "es",
    profile: "behavior smoke, no performance timings",
    results,
  };
  if (args.rounds) {
    const sabaBundle = await build({
      entryPoints: [sabaModule],
      bundle: true,
      minify: true,
      format: "esm",
      platform: "browser",
      target: "es2022",
      write: false,
      plugins: [{
        name: "saba-runtime",
        setup(builder) {
          builder.onResolve(
            { filter: /^\/__saba\/dom\.js$/ },
            () => ({ path: path.join(root, "src/modules/dom.js") }),
          );
        },
      }],
    });
    report.timing = await measure(
      browser,
      (variant) =>
        start(
          variant,
          variant === "saba" ? sabaBundle.outputFiles[0].contents : solid.outputFiles[0].contents,
          runtime,
        ),
      args,
    );
  }
  const json = JSON.stringify(report, null, 2) + "\n";
  if (args.output) await writeFile(args.output, json);
  process.stdout.write(json);
} finally {
  await browser?.close();
  await rm(temp, { recursive: true, force: true });
}

async function start(variant, renderer, runtime) {
  const calls = [];
  const holds = [];
  let round = 0, fault = 0;
  function operation(id, edited) {
    return {
      record_id: "fixture-" + id,
      id: "OP-" + id,
      client: id === 2 && edited ? "Updated client" : "Client " + id,
      kind: "Cambio",
      sell: "USD",
      buy: "EUR",
      delivered: "12.345678",
      received: "11.345678",
      cost: "1.000000",
      readable: true,
      status: "cerrada",
    };
  }
  const server = createServer(async (req, res) => {
    const send = (type, body, status = 200) => {
      res.writeHead(status, { "Content-Type": type, "Cache-Control": "no-store" });
      res.end(body);
    };
    const json = (data, status = 200) => send("application/json", JSON.stringify(data), status);
    const url = new URL(req.url, "http://localhost");
    const authed = (req.headers.cookie || "").split(";").some((entry) =>
      entry.trim() === "pilot-session=local"
    );
    if (url.pathname === "/login") return send("text/html", "<h1>Fixture login</h1>");
    if (url.pathname.startsWith("/api/")) {
      calls.push(url.pathname + url.search);
      if (!authed) return json({ error: "unauthorized" }, 401);
      if (url.pathname === "/api/pairing") return json({ phase: "online" });
      if (url.pathname === "/api/events") {
        res.writeHead(200, { "Content-Type": "text/event-stream" });
        res.write(": ready\n\n");
        return;
      }
      if (url.pathname === "/api/sheets") return json({ read_only: false, books: [] });
      if (url.pathname === "/api/books/operations") {
        const held = holds.shift();
        if (held) {
          held.arrive();
          await held.release;
        }
        if (fault) {
          const status = fault;
          fault = 0;
          return json({ error: "unavailable" }, status);
        }
        const cursor = url.searchParams.get("before");
        if (cursor && cursor !== "page-2") return json({ error: "invalid_cursor" }, 400);
        if (!cursor) round++;
        return json({
          items: (cursor ? [3] : [1, 2]).map((i) => operation(i, round >= 2)),
          next: cursor ? null : "page-2",
        });
      }
      return json({ error: "unexpected_fixture_route" }, 404);
    }
    if (url.pathname === "/" || url.pathname.startsWith("/books/")) {
      if (!authed) {
        res.writeHead(303, { Location: "/login?next=" + encodeURIComponent(url.pathname) });
        res.end();
        return;
      }
      return send("text/html; charset=utf-8", doc);
    }
    if (url.pathname === "/desk.js") {
      return send("text/javascript", variant === "desk" ? native : patched);
    }
    if (url.pathname === "/operations-renderer.js") return send("text/javascript", renderer);
    if (url.pathname === "/__saba/dom.js") return send("text/javascript", runtime);
    if (/^\/(?:[\w-]+\.(js|css)|fonts\/[\w.-]+)$/.test(url.pathname)) {
      const mime = url.pathname.endsWith(".js")
        ? "text/javascript"
        : url.pathname.endsWith(".css")
        ? "text/css"
        : "font/woff2";
      try {
        return send(mime, file(url.pathname.slice(1)));
      } catch {}
    }
    return send("text/plain", "missing", 404);
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return {
    url: "http://127.0.0.1:" + server.address().port,
    calls,
    fault(status) {
      fault = status;
    },
    hold() {
      const arrived = Promise.withResolvers(), released = Promise.withResolvers();
      holds.push({ arrive: arrived.resolve, release: released.promise });
      return { arrived: arrived.promise, release: released.resolve };
    },
    close() {
      server.closeAllConnections();
      server.close();
    },
  };
}

async function exercise(browser, fixture, variant) {
  const context = await browser.newContext({ locale: "es-VE", timezoneId: "America/Caracas" });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  const addr = fixture.url + "/books/operaciones", tables = [];
  const operations = () => fixture.calls.filter((p) => p.startsWith("/api/books/operations")).length;
  const snapshots = {};
  const ready = () => page.getByRole("button", { name: "Recargar", exact: true }).waitFor();
  const rows = () => page.locator("#sheet-body tr.row-link");
  async function arriving(hold) {
    let timeout;
    try {
      await Promise.race([
        hold.arrived,
        new Promise((_, reject) => {
          timeout = setTimeout(
            () => reject(Error("Operations request failed to reach fixture")),
            10000,
          );
        }),
      ]);
    } finally {
      clearTimeout(timeout);
    }
  }
  async function snapshot(name, count) {
    await ready();
    await page.waitForFunction(
      (n) => document.querySelectorAll("#sheet-body tr.row-link").length === n,
      count,
    );
    const data = await rows().evaluateAll((nodes) =>
      nodes.map((n) => Array.from(n.cells, (c) => c.textContent))
    );
    assert.equal(data[0].length, 9);
    tables.push(data);
    snapshots[name] = operations();
  }
  async function refs() {
    await page.evaluate(() => {
      window.pilotRefs = [
        document.querySelector("#main h1"),
        document.querySelector("#sheet-filter"),
        document.querySelector("#sheet-body tr.row-link"),
      ];
    });
  }
  async function retained() {
    return page.evaluate(() => ({
      heading: window.pilotRefs[0] === document.querySelector("#main h1"),
      filter: window.pilotRefs[1] === document.querySelector("#sheet-filter"),
      firstRow: window.pilotRefs[2] === document.querySelector("#sheet-body tr.row-link"),
      focus: document.activeElement.id || document.activeElement.localName,
    }));
  }
  try {
    await page.goto(addr);
    assert.equal(new URL(page.url()).pathname, "/login");
    assert.equal(operations(), 0);
    await context.addCookies([{ name: "pilot-session", value: "local", url: fixture.url }]);
    await page.goto(addr);
    await snapshot("cold", 2);
    assert.deepEqual(
      fixture.calls.filter((x) => ["/api/pairing", "/api/sheets", "/api/books/operations"].includes(x))
        .slice(0, 3),
      ["/api/pairing", "/api/sheets", "/api/books/operations"],
    );
    await page.locator("#sheet-filter").fill("Client 2");
    await page.waitForFunction(() => document.querySelectorAll("#sheet-body tr.row-link").length === 1);
    assert((await rows().first().innerText()).includes("Client 2"));
    await page.locator("#sheet-filter").fill("");
    await page.waitForFunction(() => document.querySelectorAll("#sheet-body tr.row-link").length === 2);
    await rows().first().press("Enter");
    await page.locator("#sheet-body tr[aria-selected=true]").waitFor();
    await refs();
    const more = fixture.hold();
    await page.getByRole("button", { name: "Cargar más" }).click();
    await arriving(more);
    // Focus an unaffected editable control while a real request is outstanding.
    await page.locator("#sheet-filter").focus();
    more.release();
    await snapshot("loadMore", 3);
    const pagination = await retained();
    assert(fixture.calls.includes("/api/books/operations?before=page-2"));
    await refs();
    const refresh = fixture.hold();
    await page.getByRole("button", { name: "Recargar", exact: true }).click();
    await arriving(refresh);
    await page.locator("#sheet-filter").focus();
    refresh.release();
    await snapshot("refresh", 2);
    assert(tables.at(-1)[1].includes("Updated client"));
    const refreshed = await retained();
    await page.locator('button[data-module="mesa"]').click();
    await page.locator('a[data-view="usuario"]').click();
    await page.waitForURL("**/books/usuario");
    await page.goBack();
    await snapshot("warmBack", 2);
    assert.equal(snapshots.warmBack, snapshots.refresh);
    fixture.fault(503);
    await page.getByRole("button", { name: "Recargar", exact: true }).click();
    await page.getByRole("button", { name: "Reintentar" }).click();
    await snapshot("retry", 2);
    await page.reload();
    await snapshot("reload", 2);
    await context.clearCookies();
    await page.getByRole("button", { name: "Recargar", exact: true }).click();
    await page.waitForURL("**/login?next=**");
    assert.equal(await rows().count(), 0);
    assert.deepEqual(errors, []);
    assert.deepEqual(snapshots, { cold: 1, loadMore: 2, refresh: 3, warmBack: 3, retry: 5, reload: 6 });
    const incremental = variant !== "desk";
    assert.deepEqual(pagination, {
      heading: incremental,
      filter: incremental,
      firstRow: incremental,
      focus: incremental ? "sheet-filter" : "body",
    });
    assert.deepEqual(refreshed, { ...pagination, firstRow: false });
    return {
      tables,
      observations: {
        variant,
        operationRequests: snapshots,
        pagination,
        refresh: refreshed,
        deniedEntry: true,
        expiredSessionRedirect: true,
      },
    };
  } finally {
    await context.close();
  }
}
