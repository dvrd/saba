// JSX constructs real nodes once. State changes update those nodes explicitly.
export const Fragment = Symbol("Fragment");
let activeScope = null;
const nodeScopes = new WeakMap();
const nodeRefs = new WeakMap();
const references = new WeakMap();
const styles = new Map();

function append(parent, child) {
  if (child == null || typeof child === "boolean") return;

  if (Array.isArray(child)) {
    for (const item of child) append(parent, item);
    return
  }

  if (child instanceof Node) {
    parent.append(child);
    return
  }

  if (
    typeof child === "string" ||
    typeof child === "number" ||
    typeof child === "bigint"
  ) {
    parent.append(document.createTextNode(String(child)));
    return
  }

  throw new TypeError(
    "JSX children must be nodes, text, numbers, or arrays.",
  );
}

// JSX event props use onClick/onPointerDown; DOM listeners use click/pointerdown.
function domEventName(eventProp) {
  return eventProp.slice(2).toLowerCase();
}

export function jsx(tag, properties, ...children) {
  const props = properties || {};
  const { ref: reference, ...attributes } = props;

  if (reference != null && !references.has(reference)) {
    throw new TypeError("ref must be an object created by ref(name).");
  }

  if (typeof tag === "function") {
    const previous = activeScope;
    const scope = createScope(previous);
    activeScope = scope;
    try {
      const node = tag({ ...attributes, children });
      if (!(node instanceof Node)) {
        throw new TypeError("Components must synchronously return a DOM node.");
      }

      if (node instanceof DocumentFragment && !node.childNodes.length) {
        node.append(document.createComment(""));
      }

      scope.roots =
        node instanceof DocumentFragment ? [...node.childNodes] : [node];

      for (const root of scope.roots) {
        if (!nodeScopes.has(root)) {
          nodeScopes.set(root, new Set());
        }
        nodeScopes.get(root).add(scope);
      }

      captureRef(reference, node);

      return node;
    } catch (error) {
      disposeScope(scope, []);
      throw error;
    } finally {
      activeScope = previous;
    }
  }

  if (tag === "svg" || tag === "math") {
    throw new TypeError(
      "This JSX runtime currently supports HTML elements only.",
    );
  }

  const node =
    tag === Fragment
      ? document.createDocumentFragment()
      : document.createElement(tag);

  const inputProperties = [];
  for (let [name, value] of Object.entries(attributes)) {
    if (name === "children") continue;

    if (
      name === "innerHTML" ||
      name === "outerHTML" ||
      name === "textContent"
    ) {
      throw new TypeError(`Use JSX children instead of ${name}.`);
    }

    if (name.startsWith("on") && name.length > 2) {
      if (value == null) continue;
      if (typeof value !== "function") {
        throw new TypeError(`${name} must be an event handler function.`);
      }

      node.addEventListener(domEventName(name), value);
      continue;
    }

    if (name === "style") {
      if (typeof value === "string") {
        node.style.cssText = value;
        continue;
      }

      if (value != null) {
        for (const [property, setting] of Object.entries(value)) {
          if (property.startsWith("--") || property.includes("-")) {
            node.style.setProperty(property, setting);
          } else {
            node.style[property] = setting;
          }
        }

        continue;
      }
    }

    name = { className: "class", htmlFor: "for" }[name] || name;

    // ARIA and data values are strings, including the meaningful value "false".
    if (value != null) {
      if (["value", "checked", "selected", "muted"].includes(name)) {
        inputProperties.push([name, value]);
      } else if (
        name.startsWith("aria-") ||
        name.startsWith("data-") ||
        ["contenteditable", "draggable", "spellcheck"].includes(
          name.toLowerCase(),
        )
      ) {
        node.setAttribute(name, String(value));
      } else if (value !== false) {
        node.setAttribute(name, value === true ? "" : String(value));
      }
    }
  }

  for (const child of children) append(node, child);

  // Select values depend on the options already being present.
  for (const [name, value] of inputProperties) node[name] = value;

  captureRef(reference, node);

  return node;
}

function currentScope() {
  if (!activeScope) {
    throw new Error(
      "Component lifetimes must be declared while a component is constructed.",
    );
  }

  return activeScope;
}

function createScope(parent) {
  const controller = new AbortController();
  const scope = {
    parent,
    controller,
    roots: [],
    children: new Set(),
    refs: new Map(),
    cleanup: [],
    pending: [],
    mounted: false,
    disposed: false,
  };
  parent?.children.add(scope);

  scope.lifetime = Object.freeze({
    abort: controller.signal,
    get root() {
      return scope.roots[0] || null;
    },
    run: (callback) => schedule(scope, callback),
  });

  return scope;
}

// Every declaration belongs to one component instance, including repeated fields.
export function ref(name) {
  const scope = currentScope();

  if (typeof name !== "string" || !/^[A-Za-z_$][\w$]*$/.test(name)) {
    throw new TypeError("ref requires a nonempty identifier name.");
  }

  if (scope.refs.has(name)) {
    throw new Error(`Duplicate component reference: ${name}`);
  }

  const state = { owner: scope, node: null };

  const reference = Object.freeze({
    name,
    get current() {
      return state.node;
    },
  });

  references.set(reference, state);
  scope.refs.set(name, state);

  return reference;
}

export function uiRefs(...names) {
  currentScope();
  return Object.freeze(
    Object.fromEntries(names.map((name) => [name, ref(name)])),
  );
}

function captureRef(reference, node) {
  if (reference == null) return;

  const state = references.get(reference);

  if (!(node instanceof Element)) {
    throw new TypeError("A ref must identify one DOM element.");
  }

  if (state.owner.disposed) {
    throw new Error("Cannot bind a disposed component reference.");
  }

  if (state.node) {
    throw new Error(`Reference is already bound: ${reference.name}`);
  }

  state.node = node;
  if (!nodeRefs.has(node)) {
    nodeRefs.set(node, new Set());
  }

  nodeRefs.get(node).add(state);
}

export function lifetime() {
  return currentScope().lifetime;
}

// Startup is registered during construction and begins after DOM insertion.
export function run(callback) {
  schedule(currentScope(), callback);
}

function schedule(scope, callback) {
  if (typeof callback !== "function") {
    throw new TypeError("run requires a function.");
  }

  if (scope.disposed) return;

  scope.pending.push(callback);

  if (scope.mounted) {
    queueMicrotask(() => start(scope));
  }
}

function start(scope) {
  if (scope.disposed || !scope.roots.some((node) => node.isConnected)) return;

  scope.mounted = true;

  for (const callback of scope.pending.splice(0)) {
    Promise.resolve()
      .then(() => {
        if (!scope.disposed) return callback(scope.lifetime);
      })
      .then((cleanup) => {
        if (typeof cleanup !== "function") return;
        if (scope.disposed) cleanup();
        else scope.cleanup.push(cleanup);
      })
      .catch((error) => {
        if (!scope.disposed) reportError(error);
      });
  }
}

function activate(nodes) {
  for (const node of nodes) {
    for (const scope of nodeScopes.get(node) || []) {
      start(scope);
    }

    activate([...node.childNodes]);
  }
}

function clearRef(state) {
  if (!state.node) return;

  nodeRefs.get(state.node)?.delete(state);

  state.node = null;
}

function disposeScope(scope, errors) {
  if (scope.disposed) return;

  scope.disposed = true;
  scope.controller.abort();
  scope.pending.length = 0;

  for (const child of [...scope.children]) disposeScope(child, errors);

  for (const callback of scope.cleanup.splice(0).reverse()) {
    try {
      callback();
    } catch (error) {
      errors.push(error);
    }
  }

  for (const state of scope.refs.values()) clearRef(state);

  for (const root of scope.roots) nodeScopes.get(root)?.delete(scope);

  scope.parent?.children.delete(scope);
  scope.parent = null;
  scope.roots.length = 0;
  scope.refs.clear();
}

function disposeNodes(nodes, errors) {
  for (const node of nodes) {
    disposeNodes([...node.childNodes], errors);

    for (const scope of [...(nodeScopes.get(node) || [])]) {
      disposeScope(scope, errors);
    }

    for (const state of [...(nodeRefs.get(node) || [])]) {
      clearRef(state);
    }
  }
}

function resolveElement(target) {
  const state = references.get(target);
  if (state) {
    if (!state.node) {
      const reason = state.owner.disposed ? "disposed" : "unbound";
      throw new Error(`Cannot use ${reason} ref: ${target.name}`);
    }

    return state.node;
  }

  if (!(target instanceof Element)) {
    throw new TypeError("Expected a DOM element or a ref(name) reference.");
  }
  return target;
}

// Replacing a region disposes its previous components and mounts its new ones.
export function update(target, content) {
  target = resolveElement(target);
  const fragment = document.createDocumentFragment();
  append(fragment, content);

  const errors = [];
  disposeNodes([...target.childNodes], errors);

  target.replaceChildren(fragment);
  activate([...target.childNodes]);

  if (errors.length) {
    throw new AggregateError(errors, "Component cleanup failed.");
  }
}

export function show(element, visible = true) {
  resolveElement(element).hidden = !visible;
}

export function hide(element) {
  show(element, false);
}

export function onCleanup(callback) {
  if (typeof callback !== "function")
    throw new TypeError("Cleanup must be a function.");
  currentScope().cleanup.push(callback);
}

export function mount(parent, Component, properties = {}) {
  parent = resolveElement(parent);

  const content = document.createDocumentFragment();
  append(content, jsx(Component, properties));

  const nodes = [...content.childNodes];

  parent.append(content);
  activate(nodes);

  let disposed = false;

  return () => {
    if (disposed) return;

    disposed = true;
    const errors = [];
    disposeNodes(nodes, errors);

    for (const node of nodes) node.remove();

    if (errors.length) {
      throw new AggregateError(errors, "Component cleanup failed.");
    }
  };
}

export function defineStyle(id, css) {
  if (styles.has(id)) {
    if (styles.get(id) !== css) {
      throw new Error(`Conflicting component style: ${id}`);
    }

    return;
  }

  const style = document.createElement("style");
  style.dataset.component = id;
  style.textContent = css;
  document.head.append(style);
  styles.set(id, css);
}
