const step = "saba-ui-history-step";
const writes = "saba-ui-write-count";
const receiptReads = "saba-ui-receipt-count";
const identityChecks = "saba-ui-identity-count";
const initialForm = document.querySelector("form");
const increment = key => sessionStorage.setItem(key, String(Number(sessionStorage.getItem(key) || 0) + 1));
const historyProbe = () => new URL(location.href).searchParams.has("history-probe");

async function report(message) {
  await fetch("/history-result", {method: "POST", body: message, cache: "no-store"});
}
if (historyProbe()) {
  addEventListener("error", event => { void report("page error: " + (event.error?.stack || event.message)); });
  addEventListener("unhandledrejection", event => { void report("unhandled rejection: " + (event.reason?.stack || event.reason)); });
}
export function reportFailure(error) { return report("startup: " + (error.stack || error)); }
function check(condition, message) { if (!condition) throw new Error(message); }

export async function testIdentity() {
  increment(identityChecks);
  return initialIdentity();
}
export async function initialIdentity() {
  const response = await fetch("/api/test-session", {credentials: "same-origin", cache: "no-store"});
  if (!response.ok) throw new Error("Session check failed");
  return response.json();
}

export function historyTransport(transport) {
  if (!historyProbe()) return transport;
  return {
    read: transport.read,
    async receipt(item, id, signal) {
      increment(receiptReads);
      return transport.receipt(item, id, signal);
    },
    async patch(item, bytes, signal) {
      increment(writes);
      const sending = transport.patch(item, bytes, signal);
      if (new URL(location.href).searchParams.has("deploy")) {
        const {operationId: id, expectedRevision} = JSON.parse(bytes);
        // The Odin checkpoint holds the writer immediately after reservation.
        // A 202 receipt proves the operation is pending at deployment.
        while ((await transport.receipt(item, id, signal)).status !== 202) {
          await new Promise(resolve => setTimeout(resolve, 10));
        }
        sessionStorage.setItem(step, "rollout");
        sessionStorage.setItem("saba-ui-old-build", document.getElementById("app").dataset.generation);
        sessionStorage.setItem("saba-ui-old-operation", id);
        sessionStorage.setItem("saba-ui-old-revision", String(expectedRevision));
        location.assign("/away");
        return sending;
      }
      const reply = await sending;
      if (reply.status !== 200) throw new Error("Unexpected live PATCH status " + reply.status);
      // The real server has committed. Simulate a lost delivery to this editor
      // by leaving its transport unresolved until navigation revokes the signal.
      const lost = new Promise((_, reject) => {
        signal.addEventListener("abort", () => reject(new Error("reply lost")), {once: true});
      });
      sessionStorage.setItem(step, "away");
      console.info("saba test: SQLite write committed; navigating away");
      location.assign("/away");
      return lost;
    }
  };
}

export async function driveHistory(editor, item) {
  try {
    const form = document.querySelector("form");
    const input = form.elements.title;
    check(item === "42" && form === initialForm, "route parameter or retained form does not match");
    check(form.querySelector("fieldset").disabled && input.value === "", "generated form was editable or populated before authorization");
    if (!historyProbe()) { await editor.open(); return; }
    const switching = new URL(location.href).searchParams.has("switch-user");
    if (switching) sessionStorage.setItem("saba-ui-switch-user", "yes");
    const stage = sessionStorage.getItem(step);
    console.info("saba test: form attached; history step", stage);
    if (stage === "rollout") {
      check(document.getElementById("app").dataset.generation !== sessionStorage.getItem("saba-ui-old-build") &&
        document.querySelector("h1").textContent === "Review item", "old generation served after publication");
      check(await editor.open(), "release B could not reconcile the existing journal");
      check(input.value === "canonical browser save" && !editor.canSave() && sessionStorage.getItem(writes) === "1" &&
        Number(sessionStorage.getItem(receiptReads)) >= 1, "release B lost or replayed the old operation");
      const authoritative = await (await fetch("/api/items/42", {credentials: "same-origin", cache: "no-store"})).json();
      check(authoritative.revision === Number(sessionStorage.getItem("saba-ui-old-revision")) + 1, "deployment duplicated the durable effect");
      const id = sessionStorage.getItem("saba-ui-old-operation");
      check(!Object.keys(sessionStorage).some(k => k.startsWith("saba:mutation:") && k.endsWith(id)), "release B retained a terminal pointer");
      await report("new generation reconciled its predecessor's pending mutation");
      return;
    }
    if (stage === "away") throw new Error("Back loaded a new document instead of restoring the original");
    if (stage === "reload") {
      check(await editor.open(), "fresh record load failed");
      check(input.value === (switching ? "Lamp" : "canonical browser save") && !editor.canSave(), "reload restored the wrong account or draft");
      check(sessionStorage.getItem(writes) === "1" && Number(sessionStorage.getItem(receiptReads)) === (switching ? 0 : 1) &&
        sessionStorage.getItem(identityChecks) === "1", "unexpected PATCH, receipt or identity-check count");
      await report(switching ? "persisted Back, changed identity, zero previous receipts, fresh authorized record" :
        "persisted Back, verified identity, one receipt, one committed PATCH, clean reload");
      return;
    }
    addEventListener("pagehide", event => {
      if (event.persisted) sessionStorage.setItem("saba-ui-private-hidden", String(input.value === "" && form.querySelector("fieldset").disabled));
    });
    addEventListener("pageshow", async event => {
      if (!event.persisted) return;
      try {
        console.info("saba test: trusted persisted Back; checking identity");
        check(event.isTrusted && sessionStorage.getItem("saba-ui-private-hidden") === "true", "restored private values were visible during suspension");
        const restored = await editor.restore();
        if (switching) {
          check(!restored && input.value === "" && !editor.canSave(), "a new identity saw the old draft during Back");
        } else {
          check(restored && input.value === "unsaved edit after submit" && editor.canSave(), "same-session Back lost the post-submit draft");
        }
        sessionStorage.setItem(step, "reload");
        location.reload();
      } catch (error) { await report("restoration: " + (error.stack || error)); }
    });
    check(await editor.open(), "initial routed read failed");
    function type(value) {
      input.value = value;
      input.dispatchEvent(new Event("input", {bubbles: true}));
    }
    type(switching ? "canonical switched browser save" : "canonical browser save");
    form.requestSubmit();
    type("unsaved edit after submit");
  } catch (error) { await report("initialization: " + (error.stack || error)); }
}
