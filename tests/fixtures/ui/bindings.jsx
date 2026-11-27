import { batch, computed, effect, mount, signal, untrack } from "/__saba/dom.js";

export function observeScheduler(host) {
  const source = signal(1), side = signal(0), branch = signal(true);
  const values = [], cutoffValues = [];
  let readDiamond, currentInBatch, cycleCaught = false, untrackCaught = false;
  const dispose = mount(host, () => {
    const left = computed(() => source() * 2);
    const right = computed(() => source() + 1);
    readDiamond = computed(() => left() + right());
    const parity = computed(() => source() % 2);
    effect(() => {
      untrack(() => side());
      try { untrack(() => { throw new Error("untrack"); }); }
      catch (error) { untrackCaught = error.message === "untrack"; }
      values.push(branch() ? readDiamond() : side());
    });
    effect(() => cutoffValues.push(parity()));
    return <div/>;
  });
  try {
    side.set(9);
    try {
      batch(() => {
        source.set(2);
        batch(() => { source.set(3); });
        currentInBatch = readDiamond();
        throw new Error("end batch");
      });
    } catch (error) {
      if (error.message !== "end batch") throw error;
    }
    branch.set(false);
    source.set(4);
    side.set(10);
    const loop = signal(0);
    let disposeLoop;
    try {
      disposeLoop = mount(host, () => {
        effect(() => { const n = loop(); if (n > 0) loop.set(n + 1); });
        return <span/>;
      });
      loop.set(1);
    } catch (error) {
      cycleCaught = error instanceof Error;
    } finally {
      if (disposeLoop) disposeLoop();
    }
    side.set(11);
    return {values: values.join(","), cutoff: cutoffValues.join(","), currentInBatch, untrackCaught, cycleCaught};
  } finally {
    dispose();
  }
}

export function observeDOM(host) {
  const enabled = signal(false), text = signal("hello"), refresh = signal(0);
  function readText() { refresh(); return text(); }
  function Glyph() { return <><path id="glyph"/></>; }
  function Panel() { return <div id="panel"><svg><circle id="circle"/></svg></div>; }
  function Layer(props) { return <g>{props.children}</g>; }
  function MathName() { return <mi id="math-name">x</mi>; }
  const dispose = mount(host, () => <main>
    <input id="field" value={readText()} disabled={!enabled()} aria-invalid={!enabled()}
      aria-describedby={enabled() ? null : "help"} style={enabled() ? {color: "green"} : {color: "red", opacity: "0.5"}}/>
    <svg><Glyph/><foreignObject><Panel/></foreignObject><Layer><circle id="forwarded"/></Layer></svg>
    <math><MathName/></math>
  </main>);
  try {
    const input = host.querySelector("#field");
    const ariaBefore = input.getAttribute("aria-invalid");
    enabled.set(true);
    input.focus();
    input.setSelectionRange(1, 4, "backward");
    refresh.set(1);
    const selection = [input.selectionStart, input.selectionEnd, input.selectionDirection].join(",");
    text.set(null);
    const namespace = selector => host.querySelector(selector).namespaceURI;
    return {
      ariaBefore, ariaAfter: input.getAttribute("aria-invalid"), described: input.hasAttribute("aria-describedby"),
      disabled: input.disabled, opacity: input.style.opacity, value: input.value, selection,
      svg: namespace("#glyph"), html: namespace("#panel"), nestedSVG: namespace("#circle"),
      forwardedSVG: namespace("#forwarded"), math: namespace("#math-name")
    };
  } finally {
    dispose();
  }
}

export async function observeExpressions() {
  const source = signal("a");
  const host = document.createElement("div");
  const order = [];
  let hiddenReads = 0, coercions = 0;
  function tagged() { return source(); }
  const value = {valueOf() { coercions++; return source(); }};
  const ignored = {get count() { hiddenReads++; return "wrong"; }};
  function LastWins(props) { return <output>{props.count}</output>; }
  const dispose = mount(host, () => <>
    <b>{tagged`read`}</b><i>{"" + value}</i><LastWins {...ignored} count="fixed"/>
  </>);
  try {
    source.set("b");
    async function load() { order.push("load"); return "2"; }
    function mark(name) { order.push(name); return name; }
    async function snapshots() {
      return <p>{await Promise.resolve(mark("1"))}{await load()}{await Promise.resolve(mark("3"))}</p>;
    }
    const resolved = await snapshots();
    const cells = ["x", ["y"]];
    const spread = <div>{...cells}</div>;
    return {
      tagged: host.querySelector("b").textContent, coerced: host.querySelector("i").textContent,
      coercions, overridden: host.querySelector("output").textContent, hiddenReads,
      resolved: resolved.textContent, order: order.join(","), spread: spread.textContent
    };
  } finally {
    dispose();
  }
}
