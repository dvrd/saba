const result = document.getElementById("result");
const host = document.getElementById("app");
let phase = "forwarded JSX";
try {
  const {observeForwarding} = await import("./forwarded.js");
  const forwarded = observeForwarding(host);
  phase = "binding module";
  const {observeScheduler, observeDOM, observeExpressions} = await import("./bindings.js");
  phase = "scheduler";
  const scheduler = observeScheduler(host);
  phase = "DOM bindings and namespaces";
  const dom = observeDOM(host);
  phase = "expression evaluation";
  const expressions = await observeExpressions();
  phase = "shared reads";
  const reads = await (await import("./reads.js")).observeReads();
  phase = "keyed rows";
  const keyed = await (await import("./keyed.js")).observeKeyed(host);
  phase = "buffered row window";
  const windowed = await (await import("./windowed.js")).observeWindow(host);
  phase = "recycled slot window";
  const slots = await (await import("./slot-window.js")).observeSlots(host);
  phase = "mutations and editing";
  const mutations = await (await import("./mutations.js")).observeMutations(host);
  phase = "removed editor with surviving searches";
  const detached = await (await import("./removing-row.js")).verifyDetachedSave(host);
  phase = "template preflight and rollback";
  const templates = await (await import("/template-test/driver.js")).verifyTemplates();
  phase = "lowered lists and holes against the runtime";
  const lowered = await (await import("./lowered.js")).observeLowered(host);
  phase = "runtime regressions";
  const regressions = (await import("./regressions.js")).verifyRegressions(host);
  result.textContent = encodeURIComponent(JSON.stringify({forwarded, scheduler, dom, expressions, reads, keyed, windowed, slots, mutations, templates, detached, regressions, lowered}));
} catch (error) {
  result.textContent = encodeURIComponent(JSON.stringify({error: phase + ": " + (error.stack || error)}));
}
