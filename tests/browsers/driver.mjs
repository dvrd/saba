// Loads a Saba fixture page in Firefox or WebKit through Playwright, for the
// Odin UI suites that otherwise drive Chromium directly.
//
//   node tests/browsers/driver.mjs ENGINE dump URL [SECONDS]
//     Prints the document once its <pre id="result"> holds a result, like
//     Chromium's --dump-dom.
//   node tests/browsers/driver.mjs ENGINE navigate URL [SECONDS]
//     Opens the page and keeps the browser alive while the page navigates and
//     reports to the fixture server itself. Ends after SECONDS or on SIGTERM.
//   node tests/browsers/driver.mjs ENGINE probe
//     Prints the browser build's version, or skips.
//
// ENGINE is firefox or webkit. Exits with 77 and a one-line reason when
// Playwright or the engine's browser build is not installed.
// PLAYWRIGHT_PATH can name a Playwright package outside tests/browsers.
import { existsSync } from "node:fs";
import { createRequire } from "node:module";

const SKIP = 77;
const [engine, mode, url, seconds = "30"] = process.argv.slice(2);
if (!["firefox", "webkit"].includes(engine) || !["dump", "navigate", "probe"].includes(mode) || (!url && mode !== "probe")) {
  console.error("usage: driver.mjs firefox|webkit dump|navigate|probe [URL [SECONDS]]");
  process.exit(2);
}

let playwright;
try {
  playwright = createRequire(import.meta.url)(process.env.PLAYWRIGHT_PATH || "playwright");
} catch {
  console.log("SKIP: Playwright is not installed. Run npm ci in tests/browsers or set PLAYWRIGHT_PATH.");
  process.exit(SKIP);
}
const type = playwright[engine];
if (!existsSync(type.executablePath())) {
  console.log(`SKIP: Playwright's ${engine} build is missing. Run npx playwright install ${engine} in tests/browsers.`);
  process.exit(SKIP);
}

const deadline = Number(seconds) * 1000;
// Playwright turns Firefox's back/forward cache off; the native history
// fixture needs the default, so it is restored. Playwright's WebKit build
// never restores a page from its back/forward cache (see browser_test.odin).
const browser = await type.launch({
  headless: true,
  firefoxUserPrefs: engine === "firefox" ? { "fission.bfcacheInParent": true } : undefined,
});
let closing = false;
async function close(code) {
  if (closing) return;
  closing = true;
  await browser.close().catch(() => {});
  process.exit(code);
}
process.on("SIGTERM", () => close(0));
process.on("SIGINT", () => close(130));

try {
  if (mode === "probe") {
    console.log(browser.version());
    await close(0);
  }
  const page = await browser.newPage();
  // The navigate log is shown only when the fixture fails; dump output is not.
  if (mode === "navigate") page.on("console", message => console.error(`console.${message.type()}: ${message.text()}`));
  page.on("pageerror", error => console.error(`page error: ${error.stack || error}`));
  await page.goto(url, { waitUntil: mode === "dump" ? "load" : "commit" });
  if (mode === "dump") {
    await page.waitForFunction(() => {
      const text = document.getElementById("result")?.textContent;
      return text && text !== "pending";
    }, null, { timeout: deadline, polling: 50 });
    process.stdout.write(await page.content());
    await close(0);
  } else {
    await new Promise(resolve => setTimeout(resolve, deadline));
    await close(0);
  }
} catch (error) {
  console.error(error.stack || String(error));
  await close(1);
}
