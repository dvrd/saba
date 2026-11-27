import { keyed, mount, signal } from "/__saba/dom.js";
import { mountSlotWindow, scalarRecord } from "/__saba/slot-window.js";

// Every shape appears twice with identical row markup. The Direct mount has the
// exact form the compiler lowers to a DOM loop. The Runtime mount carries one
// more statement, so it stays on the signal runtime. observeLowered drives both
// through the same records and requires the same DOM after every step: on a
// host of their own, on a shared host, under an owning component, and on hosts
// that are not HTML elements.

function FlatDirect(record) {
  return <div class="cell &amp; row" data-id={record().id} title={record().tip} aria-label={record().label}>{record().id + " · " + record().label}</div>;
}
function FlatRuntime(record) {
  return <div class="cell &amp; row" data-id={record().id} title={record().tip} aria-label={record().label}>{record().id + " · " + record().label}</div>;
}
export function flatDirect(host, records) {
  const rows = signal(records);
  const list = keyed(rows, record => record.id, FlatDirect);
  const dispose = mount(host, () => <>{list}</>);
  return { replace: rows.set, dispose };
}
export function flatRuntime(host, records) {
  const rows = signal(records);
  const list = keyed(rows, record => record.id, FlatRuntime);
  const dispose = mount(host, () => <>{list}</>);
  void 0;
  return { replace: rows.set, dispose };
}

function TreeDirect(record) {
  return <li class="card" data-id={record().id} title={record().tip}><img src={record().src} alt={record().label} /><span>Tom &amp; Jerry &lt;{`${record().label}`}&gt;</span>{record().vip ? <div class="vip"><span><b>deep {`${record().label}`}</b></span></div> : null}<em>{record().id + "/" + record().score}</em>{record().off ? null : <i>on</i>}<input type="checkbox" checked={record().on} /></li>;
}
function TreeRuntime(record) {
  return <li class="card" data-id={record().id} title={record().tip}><img src={record().src} alt={record().label} /><span>Tom &amp; Jerry &lt;{`${record().label}`}&gt;</span>{record().vip ? <div class="vip"><span><b>deep {`${record().label}`}</b></span></div> : null}<em>{record().id + "/" + record().score}</em>{record().off ? null : <i>on</i>}<input type="checkbox" checked={record().on} /></li>;
}
export function treeDirect(host, records) {
  const rows = signal(records);
  const list = keyed(rows, record => record.id, TreeDirect);
  const dispose = mount(host, () => <>{list}</>);
  return { replace: rows.set, dispose };
}
export function treeRuntime(host, records) {
  const rows = signal(records);
  const list = keyed(rows, record => record.id, TreeRuntime);
  const dispose = mount(host, () => <>{list}</>);
  void 0;
  return { replace: rows.set, dispose };
}

function BoxDirect(record) {
  return <input type="checkbox" class="box" data-id={record().id} title={record().label} checked={record().on} />;
}
function BoxRuntime(record) {
  return <input type="checkbox" class="box" data-id={record().id} title={record().label} checked={record().on} />;
}
export function boxDirect(host, records) {
  const rows = signal(records);
  const list = keyed(rows, record => record.id, BoxDirect);
  const dispose = mount(host, () => <>{list}</>);
  return { replace: rows.set, dispose };
}
export function boxRuntime(host, records) {
  const rows = signal(records);
  const list = keyed(rows, record => record.id, BoxRuntime);
  const dispose = mount(host, () => <>{list}</>);
  void 0;
  return { replace: rows.set, dispose };
}

// A slot window is not lowered: the runtime window owns its host, validates
// ranges and recovers from foreign mutation. The first row is one the compiler
// registers, so the window writes it directly. The second has one more child,
// which keeps it on tracked bindings. Both must build the same DOM.
function SlotRegistered(record) {
  return <div class="slot" data-id={record().id} title={record().text}>{record().element + " · " + record().text}</div>;
}
function SlotTracked(record) {
  return <div class="slot" data-id={record().id} title={record().text}>{record().element + " · " + record().text}{""}</div>;
}
export function slotRegistered(host, records, first = 0) {
  const view = mountSlotWindow(host, SlotRegistered);
  const replace = (next, nextFirst = 0) => view.replace(nextFirst, next);
  replace(records, first);
  return { replace, dispose: view.dispose };
}
export function slotTracked(host, records, first = 0) {
  const view = mountSlotWindow(host, SlotTracked);
  const replace = (next, nextFirst = 0) => view.replace(nextFirst, next);
  replace(records, first);
  return { replace, dispose: view.dispose };
}

// The first component compiles to a direct hole. The second has one more
// child, which keeps it on comment ranges and bindings.
function PanelDirect(props) {
  return <div class="panel" title="p &amp; q"><span>before</span>{props.open ? <p className="note">shown {`${props.label}`}</p> : null}<span>after</span></div>;
}
function PanelRuntime(props) {
  return <div class="panel" title="p &amp; q"><span>before</span>{props.open ? <p className="note">shown {`${props.label}`}</p> : null}<span>after</span>{""}</div>;
}
function CardDirect(record) {
  return <li class="card"><span>before</span>{record().caption ? <em>{`${record().caption}`}</em> : null}<span>after</span></li>;
}
function CardRuntime(record) {
  return <li class="card"><span>before</span>{record().caption ? <em>{`${record().caption}`}</em> : null}<span>after</span>{""}</li>;
}
function mountCards(host, records, Card) {
  const rows = signal(records);
  const dispose = mount(host, () => <ul>{keyed(rows, record => record.id, Card)}</ul>);
  return { replace: rows.set, dispose };
}
function mountPanel(host, Panel) {
  const open = signal(false);
  const label = signal("one");
  const dispose = mount(host, () => <section><Panel open={open()} label={label()} /></section>);
  return { open, label, dispose };
}

// Comment markers and empty text nodes belong to the runtime's bookkeeping.
// Everything a reader or a stylesheet can observe is compared.
function snapshot(node) {
  let text = "";
  for (const child of node.childNodes) {
    if (child.nodeType === Node.TEXT_NODE) text += "[" + child.data + "]";
    else if (child.nodeType === Node.ELEMENT_NODE) {
      const attributes = [...child.attributes].map(a => a.name + "=" + JSON.stringify(a.value)).sort().join(" ");
      const live = "checked" in child ? " checked:" + child.checked : "";
      text += "<" + child.namespaceURI.slice(-5) + ":" + child.localName + " " + attributes + live + ">" + snapshot(child) + "</>";
    }
  }
  return text.replaceAll("][", "").replaceAll("[]", "");
}

function outcome(action) {
  try {
    action();
    return "ok";
  } catch (error) {
    return error.constructor.name + ": " + error.message;
  }
}

// setup, when given, prepares each host before its list is mounted. A step
// may carry a fourth entry: a function run on both hosts before the step.
function compare(label, host, direct, runtime, steps, detached, setup, make) {
  const left = make ? make() : document.createElement("div"), right = make ? make() : document.createElement("div");
  if (!detached) host.append(left, right);
  if (setup) { setup(left); setup(right); }
  const empty = snapshot(left);
  let a, b;
  const check = (step, first, second) => {
    if (first !== second) throw new Error(label + " " + step + " outcome differs: " + first + " | " + second);
    if (snapshot(left) !== snapshot(right)) {
      throw new Error(label + " " + step + " differs:\n" + snapshot(left) + "\n" + snapshot(right));
    }
  };
  steps.forEach(([name, records, first, poke], index) => {
    if (poke) { poke(left); poke(right); }
    if (index === 0) {
      check(name, outcome(() => { a = direct(left, records, first); }), outcome(() => { b = runtime(right, records, first); }));
    } else {
      check(name, outcome(() => a.replace(records, first)), outcome(() => b.replace(records, first)));
    }
  });
  if (snapshot(left) === empty) throw new Error(label + " rendered nothing before disposal");
  check("dispose", outcome(() => a.dispose()), outcome(() => b.dispose()));
  check("dispose again", outcome(() => a.dispose()), outcome(() => b.dispose()));
  check("replace after dispose", outcome(() => a.replace(steps[0][1], steps[0][2])), outcome(() => b.replace(steps[0][1], steps[0][2])));
  left.remove();
  right.remove();
}

const one = { id: "a", label: "A", tip: "first", score: 1, src: "/a.png", vip: true, on: true, off: false };
const two = { id: "b", label: "B", tip: "second", score: 2, src: "/b.png", vip: false, on: false, off: true };
const three = { id: 3, label: "C", tip: "third", score: 3, src: "/c.png", vip: true, on: true, off: false };

function keyedSteps() {
  const same = [one, two, three];
  return [
    ["create", [one, two, three]],
    ["update", [{ ...one, label: "A2", tip: "changed", score: 10, vip: false, on: false, off: true }, two, { ...three, vip: false }]],
    ["reorder", [three, one, two]],
    ["null fields", [{ id: "a", label: null, tip: null, src: null, vip: null, on: null, off: null }, { id: "b" }, { id: 3, label: false, tip: false, src: false, score: ["x", "y"], vip: 0, on: "yes", off: "" }]],
    ["true fields", [{ id: "a", label: true, tip: true, src: true, vip: true, on: 1, off: 0 }, { id: "b", label: 0, tip: 0, src: "", score: 0 }]],
    ["removal", [two]],
    ["growth", [three, two, one, { id: "d", label: "D", tip: "", score: 4, src: "/d.png", vip: true, on: true }]],
    ["same array", same],
    ["same array again", same],
    ["duplicate keys", [one, { ...two, id: "a" }]],
    ["bad key", [one, { ...two, id: null }]],
    ["recovery", [two, one]],
    ["empty", []],
    ["refill", [one, three]],
  ];
}

function slotSteps() {
  const row = (index) => ({ id: index, element: "e" + index, text: "t" + index });
  const rows = (first, count) => Array.from({ length: count }, (_, index) => row(first + index));
  return [
    ["create", rows(0, 4), 0],
    ["same window", rows(0, 4), 0],
    ["update", rows(0, 4).map(record => ({ ...record, text: record.text + "!" })), 0],
    ["scroll forward", rows(2, 4), 2],
    ["scroll back", rows(1, 4), 1],
    ["jump", rows(40, 4), 40],
    ["shrink", rows(40, 2), 40],
    ["grow", rows(39, 5), 39],
    ["scalar records", rows(20, 4).map(scalarRecord), 20],
    ["scalar update", rows(21, 4).map(record => scalarRecord({ ...record, text: "s" })), 21],
    ["null fields", [{ id: 1, element: null, text: null }, { id: 2, element: false, text: true }, { id: 3, element: 0, text: "" }], 1],
    ["empty", [], 0],
    ["refill", rows(7, 3), 7],
  ];
}

function comparePanels(host, detached) {
  const left = document.createElement("div"), right = document.createElement("div");
  if (!detached) host.append(left, right);
  const a = mountPanel(left, PanelDirect), b = mountPanel(right, PanelRuntime);
  const check = (step) => {
    if (snapshot(left) !== snapshot(right)) {
      throw new Error("panel " + step + " differs:\n" + snapshot(left) + "\n" + snapshot(right));
    }
  };
  check("create");
  for (const [step, open, label] of [["open", true, "one"], ["label", true, "two"], ["close", false, "two"], ["reopen", true, "three"]]) {
    a.open.set(open); b.open.set(open);
    a.label.set(label); b.label.set(label);
    check(step);
    if (snapshot(left).includes("shown") !== open) throw new Error("panel " + step + " did not follow its prop");
  }
  a.dispose(); b.dispose();
  check("dispose");
  left.remove();
  right.remove();
}

// A host the list does not own alone: it has a child before the mount and
// gains one after it. The rows stay where the list was mounted.
function sharedSteps() {
  const tail = (target) => {
    const note = document.createElement("p");
    note.className = "after";
    note.textContent = "after";
    target.append(note);
  };
  return [
    ["create", [one, two]],
    ["sibling added, then growth", [one, two, three], undefined, tail],
    ["reorder", [three, one, two]],
    ["empty", []],
    ["refill beside siblings", [two, three]],
    ["second sibling, then removal", [three], undefined, tail],
  ];
}

// The user flips the second box. A reorder of the same records leaves that
// state with its record, because an element follows its key.
function toggledSteps() {
  const flip = (target) => {
    const box = target.querySelectorAll("input")[1];
    box.checked = !box.checked;
  };
  const records = [one, two, three];
  return [
    ["create", records],
    ["toggled, then reordered", [three, two, one], undefined, flip],
    ["same order, same records", [three, two, one]],
    ["same order, new records", [{ ...three }, { ...two }, { ...one }]],
    ["toggled, then a key replaced", [{ ...three }, { ...two, id: "z" }, { ...one }], undefined, flip],
    ["shrink", [{ ...one }]],
  ];
}

// A list mounted while a component is constructed belongs to that component:
// disposing the component releases the list.
function Owner(props) {
  const target = <div class="owned"></div>;
  props.out.target = target;
  props.out.list = props.mountList(target, props.records);
  return target;
}

function compareOwned(label, host, direct, runtime) {
  const sides = [direct, runtime].map((mountList) => {
    const side = document.createElement("div");
    host.append(side);
    const out = {};
    const dispose = mount(side, () => <Owner out={out} mountList={mountList} records={[one, two]} />);
    return { side, out, dispose };
  });
  const check = (step) => {
    const [a, b] = sides.map(({ out }) => snapshot(out.target));
    if (a !== b) throw new Error(label + " " + step + " differs:\n" + a + "\n" + b);
    return a;
  };
  if (!check("create")) throw new Error(label + " rendered nothing");
  for (const { out } of sides) out.list.replace([two, three, one]);
  check("replace");
  for (const { dispose } of sides) dispose();
  if (check("owner disposed")) throw new Error(label + " kept rows after its owner was disposed");
  const outcomes = sides.map(({ out }) => outcome(() => out.list.replace([one])));
  if (outcomes[0] !== outcomes[1]) throw new Error(label + " replace after owner disposal differs: " + outcomes.join(" | "));
  check("replace after owner disposed");
  for (const { side } of sides) side.remove();
}

// A host that is not an HTML element takes the authored statements, so the
// runtime decides: its error for a value that is no element, its namespace
// rules for an element outside HTML.
function compareHosts(host) {
  for (const value of [null, undefined, "#app", {}, document.createTextNode("x")]) {
    for (const [direct, runtime] of [[flatDirect, flatRuntime], [treeDirect, treeRuntime], [boxDirect, boxRuntime]]) {
      const a = outcome(() => direct(value, [one])), b = outcome(() => runtime(value, [one]));
      if (a !== b || a === "ok") throw new Error("host " + String(value) + " differs: " + a + " | " + b);
    }
  }
  const vector = () => document.createElementNS("http://www.w3.org/2000/svg", "g");
  compare("svg host", host, flatDirect, flatRuntime, [["create", [one, two]], ["reorder", [two, one]]], false, undefined, vector);
}

export async function observeLowered(host) {
  compareHosts(host);
  compareOwned("owned flat", host, flatDirect, flatRuntime);
  compareOwned("owned tree", host, treeDirect, treeRuntime);
  compareOwned("owned checkbox", host, boxDirect, boxRuntime);
  for (const detached of [false, true]) {
    const where = detached ? " (detached)" : "";
    compare("flat" + where, host, flatDirect, flatRuntime, keyedSteps(), detached);
    compare("tree" + where, host, treeDirect, treeRuntime, keyedSteps(), detached);
    compare("checkbox" + where, host, boxDirect, boxRuntime, keyedSteps(), detached);
    compare("slot" + where, host, slotRegistered, slotTracked, slotSteps(), detached);
    const sibling = (target) => {
      const note = document.createElement("p");
      note.className = "before";
      note.textContent = "before";
      target.append(note);
    };
    compare("shared flat" + where, host, flatDirect, flatRuntime, sharedSteps(), detached, sibling);
    compare("shared tree" + where, host, treeDirect, treeRuntime, sharedSteps(), detached, sibling);
    compare("shared checkbox" + where, host, boxDirect, boxRuntime, sharedSteps(), detached, sibling);
    compare("toggled checkbox" + where, host, boxDirect, boxRuntime, toggledSteps(), detached);
    comparePanels(host, detached);
    compare(
      "hole rows" + where,
      host,
      (target, records) => mountCards(target, records, CardDirect),
      (target, records) => mountCards(target, records, CardRuntime),
      [
        ["create", [{ id: 1, caption: "one" }, { id: 2 }]],
        ["update", [{ id: 1 }, { id: 2, caption: "two" }]],
        ["reorder", [{ id: 2, caption: "two" }, { id: 1, caption: "again" }]],
        ["removal", [{ id: 1, caption: "again" }]],
      ],
      detached,
    );
  }
  return true;
}
