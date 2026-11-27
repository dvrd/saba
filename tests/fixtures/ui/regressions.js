// Behaviour that needs a real DOM: attachment to a document other software has
// touched, physical row moves, attribute sinks and staged template writes.
import {binding, effect, jsx, keyed, mount, onCleanup, run, signal, trusted} from "/__saba/dom.js";
import * as template from "/template-test/attach.js";

function check(condition, message) {
  if (!condition) throw new Error(message);
}
function caught(callback) {
  try { callback(); } catch (error) { return error; }
  return null;
}

const HTML = '<section data-saba-node="0" data-saba-instance="0"><h1 data-saba-node="1">Inbox</h1>' +
  '<output data-saba-node="2"><!--saba:3:start--><!--saba:3:end--></output><button data-saba-node="4">Add</button></section>';
const manifest = [
  {tag: "section", parent: -1, instance: 0, local: 0}, {tag: "h1", parent: 0, instance: 0, local: 1},
  {tag: "output", parent: 0, instance: 0, local: 2}, {parent: 2, instance: 0, local: 3},
  {tag: "button", parent: 0, instance: 0, local: 4},
];
function served(html = HTML) {
  const host = document.body.appendChild(document.createElement("div"));
  host.setAttribute("aria-busy", "true");
  host.setAttribute("data-saba-pending", "");
  host.innerHTML = html;
  return host;
}
function setupOf(count, clicks, extra) {
  return () => {
    template.element(0, {});
    template.element(1, {title: binding(() => "count " + count())});
    template.element(2, {});
    template.range(3, binding(() => count()));
    template.element(4, {onClick: () => clicks.push(count())});
    extra?.();
  };
}

function foreignNodes() {
  const count = signal(1), clicks = [];
  const host = served();
  const section = host.firstElementChild, heading = host.querySelector("h1"), output = host.querySelector("output");
  // A translation service wraps text, an extension appends its own element and
  // comment, a password manager wraps a control, and something writes into a range.
  const font = document.createElement("font");
  font.textContent = heading.firstChild.data;
  heading.firstChild.replaceWith(font);
  section.append(document.createElement("grammarly-extension"), document.createComment("extension"));
  const wrapper = document.createElement("span");
  host.querySelector("button").replaceWith(wrapper);
  wrapper.append(clicks.button = document.createElement("button"));
  clicks.button.setAttribute("data-saba-node", "4");
  output.firstChild.after(document.createElement("i"), "stray");
  const release = template.attach(host, manifest, setupOf(count, clicks));
  try {
    check(!host.hasAttribute("aria-busy") && !host.hasAttribute("data-saba-pending") && !host.inert,
      "an attached host still announced itself as pending");
    check(heading.title === "count 1" && output.textContent === "1" && heading.firstChild === font,
      "attachment beside foreign nodes lost a binding or replaced foreign content");
    count.set(2);
    clicks.button.click();
    check(heading.title === "count 2" && output.textContent === "2" && clicks.join() === "2",
      "bindings attached beside foreign nodes did not stay live");
  } finally { release(); }
  host.remove();

  // Saba's own markers still have to be exactly what the build emitted.
  const failures = {
    missing: html => html.replace('<h1 data-saba-node="1">Inbox</h1>', ""),
    renumbered: html => html.replace('data-saba-node="1"', 'data-saba-node="9"'),
    retagged: html => html.replace(/<(\/?)h1/g, "<$1h2"),
    duplicated: html => html.replace("</section>", '<button data-saba-node="4">Again</button></section>'),
    unclosed: html => html.replace("<!--saba:3:end-->", ""),
    misplaced: html => html.replace('<button data-saba-node="4">Add</button>', "").replace("</h1>", '<button data-saba-node="4">Add</button></h1>'),
  };
  for (const [name, corrupt] of Object.entries(failures)) {
    const broken = served(corrupt(HTML)), before = broken.innerHTML;
    const error = caught(() => template.attach(broken, manifest, setupOf(signal(1), [])));
    check(error && broken.innerHTML === before && broken.hasAttribute("data-saba-pending"),
      "a " + name + " Saba marker attached or changed the document");
    broken.remove();
  }

  // A write that fails after others have landed takes all of them back,
  // including an attribute the served document did not have.
  const partial = served(), before = partial.innerHTML;
  const rejected = caught(() => template.attach(partial, manifest, () => {
    template.element(0, {});
    template.element(1, {title: "added"});
    template.element(2, {});
    template.range(3, binding(() => 1));
    template.element(4, {formAction: "javascript:void 0"});
  }));
  check(rejected && /javascript: URL/.test(rejected.message), "expected the javascript: URL to be refused");
  check(partial.innerHTML === before && !partial.querySelector("h1").hasAttribute("title"),
    "a rolled-back activation left an attribute behind");
  partial.remove();
}

function stagedWrites() {
  const count = signal(1);
  const first = served();
  const release = template.attach(first, manifest, setupOf(count, []));
  const second = served();
  // Another template writes a shared signal during its own setup and fails.
  const error = caught(() => template.attach(second, manifest, setupOf(count, [], () => {
    count.set(2);
    throw new Error("second template failed");
  })));
  check(error?.message === "second template failed", "expected the second attachment to fail");
  check(first.querySelector("h1").title === "count 2" && first.querySelector("output").textContent === "2",
    "a committed template lost a write to another template's rolled-back activation");
  // A write staged during a template's own setup still lands after its first one.
  const third = served();
  const releaseThird = template.attach(third, manifest, setupOf(count, [], () => count.set(3)));
  check(third.querySelector("h1").title === "count 3" && third.querySelector("output").textContent === "3",
    "a write made during setup was applied out of order");
  // A range the server rendered as text goes to an element and back to text
  // before the activation commits; the last write no longer has that text node.
  for (const initial of ["1", null]) {
    const view = signal(initial);
    const fourth = served(HTML.replace("<!--saba:3:start-->", "<!--saba:3:start-->1"));
    const releaseFourth = template.attach(fourth, manifest, () => {
      template.element(0, {});
      template.element(1, {});
      template.element(2, {});
      template.range(3, binding(() => view() ?? jsx("i", null, "none")));
      template.element(4, {});
      if (initial !== null) view.set(jsx("b", null, "bold"));
      view.set("again");
    });
    check(fourth.querySelector("output").textContent === "again" && !fourth.querySelector("output").firstElementChild,
      "a text write staged after a structural one did not land");
    view.set("later");
    check(fourth.querySelector("output").textContent === "later", "the range stopped following its signal");
    releaseFourth();
    fourth.remove();
  }
  const late = caught(() => template.element(0, {}));
  check(late && /only available while attach/.test(late.message), "a target lookup after attachment did not explain itself");
  release(); releaseThird();
  first.remove(); second.remove(); third.remove();
}

function minimalMoves(host) {
  const order = ids => ids.map(id => ({id}));
  const rows = signal(order([1, 2, 3, 4, 5, 6]));
  let focusEvents = 0;
  const release = mount(host, () => jsx("ul", null, keyed(rows, row => row.id, row =>
    jsx("li", {"data-id": binding(() => row().id)}, jsx("input", {onFocus: () => focusEvents++})))));
  try {
    const list = host.querySelector("ul");
    const moved = [];
    for (const method of ["insertBefore", "moveBefore"]) {
      if (typeof list[method] !== "function") continue;
      const native = list[method].bind(list);
      list[method] = (node, before) => {
        if (node.nodeType === Node.ELEMENT_NODE) moved.push(Number(node.dataset.id));
        return native(node, before);
      };
    }
    const item = id => list.querySelector('[data-id="' + id + '"]');
    const input = item(3).firstChild;
    input.focus();
    input.value = "draft";
    input.setSelectionRange(1, 3, "backward");
    const focusedOnce = focusEvents;
    const expect = (ids, moves, message) => {
      moved.length = 0;
      rows.set(order(ids));
      check([...list.children].map(node => Number(node.dataset.id)).join() === ids.join(), message + ": wrong order");
      const expected = typeof moves === "number" ? moved.length === moves : moved.slice().sort().join() === moves.join();
      check(expected, message + ": moved " + moved.join());
    };
    expect([6, 1, 2, 3, 4, 5], [6], "last row to the front");
    expect([1, 2, 3, 4, 5, 6], [6], "first row to the back");
    expect([1, 2, 4, 5, 3, 6], [3], "one row moved past two others");
    expect([1, 2, 3, 4, 5, 6], [3], "and back again");
    expect([2, 1, 3, 4, 6, 5], 2, "two independent swaps");
    expect([2, 3, 6, 7, 5], [7], "removals and an insertion without moving kept rows");
    check(document.activeElement === input && input.value === "draft" && input.selectionStart === 1 &&
      input.selectionEnd === 3 && input.selectionDirection === "backward", "reorders disturbed the focused row");
    // Row 3 kept its place in the last four updates, so nothing refocused it.
    check(focusEvents === focusedOnce || typeof list.moveBefore !== "function",
      "the focused row received another focus event");
    rows.set(order([5, 7, 6, 3, 2]));
    check([...list.children].map(node => Number(node.dataset.id)).join() === "5,7,6,3,2" &&
      document.activeElement === input && input.value === "draft", "a full reversal lost order, focus or the draft");
  } finally { release(); }
}

function attributeSinks(host) {
  const handled = [];
  const variants = jsx("button", {ONCLICK: () => handled.push("upper"), OnKeyDown: () => handled.push("mixed")});
  check(!variants.hasAttribute("onclick") && !variants.hasAttribute("onkeydown"), "an event spelling became an inline handler");
  variants.click();
  check(handled.join() === "upper", "an event spelling was not registered as a listener");
  for (const name of ["ONCLICK", "OnClick", "onclick", "oNmouseover"]) {
    check(caught(() => jsx("div", {[name]: "window.__sabaInjected = 1"})) instanceof TypeError,
      "a string was accepted for " + name);
  }
  const refused = [
    ["a", "href", "javascript:alert(1)"], ["a", "href", " \n\tJaVa\tScRiPt:alert(1)"], ["a", "HREF", "javascript:alert(1)"],
    ["iframe", "src", "javascript:alert(1)"], ["form", "action", "javascript:alert(1)"],
    ["button", "formAction", "javascript:alert(1)"], ["iframe", "srcdoc", "<script>alert(1)</script>"],
    ["iframe", "srcdoc", ["<script>alert(1)</script>"]], ["iframe", "srcdoc", {toString: () => "<script>alert(1)</script>"}],
  ];
  for (const [tag, name, value] of refused) {
    check(caught(() => jsx(tag, {[name]: value})) instanceof TypeError, tag + " accepted " + name + "=" + value);
  }
  check(caught(() => jsx("svg", null, jsx("a", {"xlink:href": "javascript:alert(1)"}))) instanceof TypeError,
    "an SVG link accepted a javascript: URL");
  const link = jsx("a", {href: "/items/42?next=javascript:1#javascript:"}, "ordinary");
  check(link.getAttribute("href") === "/items/42?next=javascript:1#javascript:", "an ordinary URL was refused");
  check(jsx("a", {href: trusted("javascript:void 0")}).getAttribute("href") === "javascript:void 0" &&
    jsx("iframe", {srcdoc: trusted("<p>preview</p>")}).getAttribute("srcdoc") === "<p>preview</p>",
    "an explicitly trusted value was refused");

  // A bound URL that turns hostile keeps the last safe value.
  const target = signal("/safe");
  const release = mount(host, () => jsx("a", {href: binding(() => target())}, "bound"));
  try {
    const bound = host.querySelector("a");
    check(caught(() => target.set("javascript:alert(1)")) instanceof TypeError && bound.getAttribute("href") === "/safe",
      "a bound href accepted a javascript: URL");
    target.set("/next");
    check(bound.getAttribute("href") === "/next", "the binding did not recover");
  } finally { release(); }
  check(window.__sabaInjected === undefined, "an injected handler ran");
}

function effectOwnership(host) {
  const key = signal(0), ticks = signal(0);
  let children = 0, cleanups = 0, innerRuns = 0;
  function Child() { children++; onCleanup(() => cleanups++); return jsx("i", null, binding(() => ticks())); }
  const stage = document.createElement("div");
  const release = mount(host, () => {
    effect(() => {
      key();
      effect(() => { ticks(); innerRuns++; });
      stage.replaceChildren(jsx(Child, null));
    });
    return stage;
  });
  try {
    for (let n = 1; n <= 4; n++) key.set(n);
    check(children === 5 && cleanups === 4, "components created by earlier evaluations were not released: " + cleanups);
    const before = innerRuns;
    ticks.set(1);
    check(innerRuns - before === 1 && stage.textContent === "1", "effects of earlier evaluations were still subscribed");
  } finally { release(); }
  check(cleanups === 5, "the last evaluation outlived its effect");
}

// Startup declared where no root node exists yet (a helper called from a row's
// child binding, one evaluation of an effect) begins with the nearest component.
async function rootlessStartup(host) {
  const seen = [], ticks = signal(0), items = signal([{id: 1}]);
  const cell = label => {
    effect(() => { seen.push(label + ":" + ticks()); });
    run(() => { seen.push(label + ":run"); });
    return jsx("span", null, label);
  };
  let inEffect = 0;
  const release = mount(host, () => {
    effect(() => { ticks(); run(() => { inEffect++; }); });
    return jsx("ul", null, binding(() => keyed(items, record => record.id,
      record => jsx("li", null, binding(() => cell("row" + record().id))))));
  });
  const settle = () => new Promise(resolve => setTimeout(resolve, 0));
  try {
    await settle();
    check(seen.includes("row1:0") && seen.includes("row1:run"), "an effect or run declared inside a row never started: " + seen);
    check(inEffect === 1, "run inside an effect never started");
    items.set([{id: 1}, {id: 2}]);
    await settle();
    check(seen.includes("row2:0") && seen.includes("row2:run"), "a row added after mount did not start its effect: " + seen);
    ticks.set(1);
    await settle();
    check(seen.includes("row1:1") && seen.includes("row2:1") && inEffect === 2, "row effects did not stay subscribed: " + seen);
  } finally { release(); }
  const before = seen.length;
  ticks.set(2);
  await settle();
  check(seen.length === before, "a row effect outlived its mount");
}

export async function verifyRegressions(host) {
  foreignNodes();
  stagedWrites();
  minimalMoves(host);
  attributeSinks(host);
  effectOwnership(host);
  await rootlessStartup(host);
  return true;
}
