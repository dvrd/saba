// A distinct document enables a real native Back navigation. Observe pageshow
// so the initial navigation is committed before traversing the history.
async function visitNextGeneration() {
  await fetch("/test-publish", {method: "POST"});
  const old = sessionStorage.getItem("saba-ui-old-build");
  for (;;) {
    const html = await (await fetch("/items/42", {cache: "no-store"})).text();
    const form = new DOMParser().parseFromString(html, "text/html");
    const generation = form.getElementById("app")?.dataset.generation;
    if (generation && generation !== old && form.querySelector("h1")?.textContent === "Review item") break;
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  const id = sessionStorage.getItem("saba-ui-old-operation");
  // The development client can reload this neutral page when B publishes.
  // Preserve the witnessed 202 before unlocking the writer so the new
  // document can finish the same transfer.
  if (sessionStorage.getItem("saba-ui-witnessed-pending") !== id) {
    const receipt = await fetch("/api/items/42/operations/" + encodeURIComponent(id), {cache: "no-store"});
    if (receipt.status !== 202 && sessionStorage.getItem("saba-ui-witnessed-pending") !== id)
      throw new Error("Release B was published outside the pending write window");
    sessionStorage.setItem("saba-ui-witnessed-pending", id);
  }
  await fetch("/test-release", {method: "POST"});
  location.replace("/items/42?history-probe&deploy");
}

addEventListener("pageshow", () => {
  if (sessionStorage.getItem("saba-ui-history-step") === "rollout") {
    visitNextGeneration().catch(error => fetch("/history-result", {method: "POST", body: String(error.stack || error)}));
    return;
  }
  if (sessionStorage.getItem("saba-ui-switch-user") === "yes")
    document.cookie = "saba-test-user=second; Path=/; SameSite=Strict";
  setTimeout(() => history.back(), 0);
}, {once: true});
