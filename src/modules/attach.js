import { templateElement, templateRange, templateRoot } from "/__saba/dom.js";

const html = "http://www.w3.org/1999/xhtml";
const mounted = new WeakSet();
let activation;

// Saba's own nodes carry a marker. Anything else inside the host was put there
// by someone else: a browser extension, a translation service, a password
// manager. Those nodes are not targets and must not prevent attachment.
function marked(node) {
  return node.nodeType === Node.ELEMENT_NODE
    ? node.hasAttribute("data-saba-node")
    : node.data.startsWith("saba:");
}

// The nearest marked element above a node, looking through foreign wrappers.
function owningTarget(node, host) {
  for (let parent = node.parentNode; parent && parent !== host; parent = parent.parentNode) {
    if (parent.nodeType === Node.ELEMENT_NODE && parent.hasAttribute("data-saba-node")) return parent;
  }
  return host;
}

// Validate the browser's parsed DOM and resolve every target before entering
// any application setup. HTML parsing can insert parents or reparent children.
// A marked node that is missing, duplicated, misplaced or altered still fails.
function resolveTargets(host, manifest) {
  const found = [];
  const instances = new Map();
  let open;
  const walker = host.ownerDocument.createTreeWalker(host, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_COMMENT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (!marked(node)) continue;
    if (open) {
      // Foreign siblings between the boundaries are replaced by the range's
      // first write. The boundaries themselves must still be siblings.
      if (node.nodeType !== Node.COMMENT_NODE || node.data !== `saba:${manifest[found.length - 1].local}:end` ||
          node.parentNode !== open.start.parentNode) {
        throw new Error("Invalid Saba range boundary.");
      }
      open.end = node;
      open = undefined;
      continue;
    }
    const id = found.length;
    const spec = manifest[id];
    if (!spec || owningTarget(node, host) !== (spec.parent === -1 ? host : found[spec.parent])) {
      throw new Error("Unexpected Saba target or parent.");
    }
    if (spec.local === 0) {
      if (node.nodeType !== Node.ELEMENT_NODE || instances.has(spec.instance) ||
          node.getAttribute("data-saba-instance") !== String(spec.instance)) {
        throw new Error("Missing or duplicate Saba component boundary.");
      }
      instances.set(spec.instance, node);
    } else if (node.parentElement?.closest("[data-saba-instance]") !== instances.get(spec.instance)) {
      throw new Error("Saba target belongs to a different component.");
    }
    if (spec.tag) {
      if (node.nodeType !== Node.ELEMENT_NODE || node.localName !== spec.tag || node.namespaceURI !== html ||
          node.getAttribute("data-saba-node") !== String(spec.local)) {
        throw new Error(`Mismatched Saba element ${id}.`);
      }
      found.push(node);
    } else {
      if (node.nodeType !== Node.COMMENT_NODE || node.data !== `saba:${spec.local}:start`) {
        throw new Error(`Missing Saba range ${id}.`);
      }
      open = { start: node, end: null };
      found.push(open);
    }
  }
  if (open || found.length !== manifest.length) throw new Error("Incomplete Saba template.");
  return found;
}

// Record only writes made during this synchronous activation. takeRecords()
// returns them before the observer callback could run. Rollback puts the actual
// removed nodes back, preserving outside references to static DOM.
function activationJournal(host) {
  const root = host.ownerDocument;
  const focus = host.contains(root.activeElement) ? root.activeElement : null;
  const selection = focus?.selectionStart == null ? null : [focus.selectionStart, focus.selectionEnd, focus.selectionDirection];
  const observer = new MutationObserver(() => {});
  observer.observe(host, {subtree: true, attributes: true, attributeOldValue: true,
    childList: true, characterData: true, characterDataOldValue: true});
  const form = [];
  return {
    remember(element) {
      // Live form state can diverge from the corresponding HTML attribute.
      for (const key of ["value", "checked", "selected", "muted"]) {
        if (key in element && typeof element[key] !== "object") form.push([element, key, element[key]]);
      }
    },
    close() { observer.disconnect(); },
    restore() {
      const records = observer.takeRecords();
      observer.disconnect();
      for (const record of records.reverse()) {
        const {type, target, oldValue, attributeName} = record;
        if (type === "attributes") {
          if (oldValue === null) target.removeAttribute(attributeName);
          else target.setAttribute(attributeName, oldValue);
        } else if (type === "characterData") {
          target.data = oldValue;
        } else {
          for (const node of record.addedNodes) if (node.parentNode === target) node.remove();
          const anchor = record.nextSibling?.parentNode === target ? record.nextSibling : null;
          for (const node of record.removedNodes) target.insertBefore(node, anchor);
        }
      }
      for (const [element, key, value] of form) if (element[key] !== value) element[key] = value;
      if (focus) {
        if (root.activeElement !== focus) focus.focus({preventScroll: true});
        if (selection) focus.setSelectionRange(...selection);
      }
    }
  };
}

export function attach(host, manifest, setup) {
  if (!host || mounted.has(host)) throw new Error("Missing or already active Saba template host.");
  const resolved = resolveTargets(host, manifest);
  const journal = activationJournal(host);
  const previous = activation;
  activation = {targets: resolved, journal};
  mounted.add(host);
  try {
    const release = templateRoot(host, setup, () => enable(host));
    journal.close();
    return () => {
      try { release(); } finally { mounted.delete(host); }
    };
  } catch (error) {
    mounted.delete(host);
    journal.restore();
    throw error;
  } finally {
    activation = previous;
  }
}

// The served host announces that it is waiting for its module. It may also be
// inert when an application or an older build asked for that.
export function enable(host) {
  host.inert = false;
  host.removeAttribute("aria-busy");
  host.removeAttribute("data-saba-pending");
}

// Targets exist only while attach() runs its setup. Code that runs later, such
// as a branch rendered after activation, creates its nodes with JSX instead.
function targets() {
  if (!activation) throw new Error("Saba template targets are only available while attach() runs its setup.");
  return activation;
}

export function element(id, props) {
  const {targets: resolved, journal} = targets();
  const target = resolved[id];
  if (Object.keys(props).length) journal.remember(target);
  return templateElement(target, props);
}

export function range(id, value) {
  const {start, end} = targets().targets[id];
  templateRange(start, end, value);
}
