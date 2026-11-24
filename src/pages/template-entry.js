// A literal import may outlive the deployment's asset retention period.
export function unavailable(error) {
  const recovery = document.querySelector("[data-saba-recover]");
  if (recovery) recovery.hidden = false;
  throw error;
}

export function startPage(generation, route, locale, attach) {
  const host = document.getElementById("app");
  const recovery = document.querySelector("[data-saba-recover]");
  if (!host || host.dataset.generation !== generation || host.dataset.route !== route ||
      document.documentElement.lang !== locale || !recovery) throw new Error("Incompatible page document.");
  const parts = location.pathname.slice(1).split("/").map(decodeURIComponent);
  const pattern = route.slice(1).split("/");
  if (parts.length !== pattern.length) throw new Error("Unexpected page path.");
  const params = Object.create(null);
  for (const [index, name] of pattern.entries()) {
    const value = parts[index];
    if (name.startsWith(":") && value && !value.includes("/") && !value.includes("\\")) params[name.slice(1)] = value;
    else if (value !== name) throw new Error("Unexpected page segment.");
  }
  let dispose;
  try {
    dispose = attach(host, {params: Object.freeze(params)});
  } catch (error) {
    // The static document stays as served. It is no longer waiting for anything.
    host.removeAttribute("aria-busy");
    recovery.hidden = false;
    throw error;
  }
  host.inert = false;
  host.removeAttribute("aria-busy");
  host.removeAttribute("data-saba-pending");
  recovery.hidden = true;
  addEventListener("pagehide", event => { if (!event.persisted) dispose(); });
}
