import { keyed, mount, signal } from "/__saba/dom.js";
import { mountSlotWindow, scalarRecord } from "/__saba/slot-window.js";

// Every shape appears twice with identical row markup. The Direct mount has the
// exact form the compiler lowers to a DOM loop. The Runtime mount carries one
// more statement, so it stays on the signal runtime. observeLowered drives both
// through the same records and requires the same DOM after every step.

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

function SlotDirect(record) {
  return <div class="slot" data-id={record().id} title={record().text}>{record().element + " · " + record().text}</div>;
}
function SlotRuntime(record) {
  return <div class="slot" data-id={record().id} title={record().text}>{record().element + " · " + record().text}</div>;
}
export function slotDirect(host, records, first = 0) {
  const view = mountSlotWindow(host, SlotDirect);
  const replace = (next, nextFirst = 0) => view.replace(nextFirst, next);
  replace(records, first);
  return { replace, dispose: view.dispose };
}
export function slotRuntime(host, records, first = 0) {
  const view = mountSlotWindow(host, SlotRuntime);
  const replace = (next, nextFirst = 0) => view.replace(nextFirst, next);
  replace(records, first);
  void 0;
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

function compare(label, host, direct, runtime, steps, detached) {
  const left = document.createElement("div"), right = document.createElement("div");
  if (!detached) host.append(left, right);
  let a, b;
  const check = (step, first, second) => {
    if (first !== second) throw new Error(label + " " + step + " outcome differs: " + first + " | " + second);
    if (snapshot(left) !== snapshot(right)) {
      throw new Error(label + " " + step + " differs:\n" + snapshot(left) + "\n" + snapshot(right));
    }
  };
  steps.forEach(([name, records, first], index) => {
    if (index === 0) {
      check(name, outcome(() => { a = direct(left, records, first); }), outcome(() => { b = runtime(right, records, first); }));
    } else {
      check(name, outcome(() => a.replace(records, first)), outcome(() => b.replace(records, first)));
    }
  });
  if (!snapshot(left)) throw new Error(label + " rendered nothing before disposal");
  check("dispose", outcome(() => a.dispose()), outcome(() => b.dispose()));
  if (snapshot(left)) throw new Error(label + " left nodes after disposal: " + snapshot(left));
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

export async function observeLowered(host) {
  for (const detached of [false, true]) {
    const where = detached ? " (detached)" : "";
    compare("flat" + where, host, flatDirect, flatRuntime, keyedSteps(), detached);
    compare("tree" + where, host, treeDirect, treeRuntime, keyedSteps(), detached);
    compare("checkbox" + where, host, boxDirect, boxRuntime, keyedSteps(), detached);
    compare("slot" + where, host, slotDirect, slotRuntime, slotSteps(), detached);
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
