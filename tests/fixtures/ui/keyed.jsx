import { effect, keyed, lifetime, mount, onCleanup, ref, run, signal, update } from "/__saba/dom.js";

function check(condition, message) {
  if (!condition) throw new Error(message);
}

export async function observeKeyed(host) {
  const rows = signal([{ id: "a", label: "A" }, { id: "b", label: "B" }, { id: "empty" }]);
  const setups = [], cleanups = [], starts = [], effects = [];
  const childStarts = [], childStops = [];
  let bLifetime, bRunLifetime;
  const bDisposal = [];
  function RowShell({id, fields}) {
    run(() => { childStarts.push(id); });
    onCleanup(() => childStops.push(id));
    return <div>{fields}</div>;
  }
  function renderRow(record) {
    const id = record().id;
    setups.push(id);
    if (id === "b") {
      bLifetime = lifetime();
      check(Object.isFrozen(bLifetime) && lifetime() === bLifetime, "row lifetime identity changed");
      bLifetime.abort.addEventListener("abort", () => bDisposal.push("abort"));
      onCleanup(() => bDisposal.push("cleanup"));
    }
    onCleanup(() => cleanups.push(id));
    effect(() => effects.push(id));
    run((scope) => {
      if (id === "b") bRunLifetime = scope;
      starts.push(id);
    });
    if (id === "bad") throw new Error("row setup failed");
    if (id === "empty") return null;
    const fields = (
      <>
        <label data-label={id}>{record().label}</label>
        <input data-row={id} />
      </>
    );
    if (id === "a" || id === "c") return <RowShell id={id} fields={fields}/>;
    return fields;
  }
  const dispose = mount(host, () => <section>{keyed(rows(), (row) => row.id, renderRow)}</section>);
  try {
    const getInput = (id) => host.querySelector('[data-row="' + id + '"]');
    const getLabel = (id) => host.querySelector('[data-label="' + id + '"]');
    const a = getInput("a"), b = getInput("b");
    a.value = "my draft";
    a.focus();
    a.setSelectionRange(2, 5, "backward");

    rows.set([{ id: "b", label: "B2" }, { id: "empty" }, { id: "a", label: "A2" }]);
    check(getInput("a") === a && getInput("b") === b, "reorder replaced inputs");
    check(
      host.querySelector("input") === b && getLabel("a").textContent === "A2",
      "fresh records or multi-root row order lost",
    );
    check(
      document.activeElement === a && a.value === "my draft" && a.selectionStart === 2 &&
        a.selectionEnd === 5 && a.selectionDirection === "backward",
      "reorder lost focus, draft or selection",
    );
    check(setups.join(",") === "a,b,empty", "retained key ran setup again");

    let duplicate = false;
    try {
      rows.set([{ id: "a", label: "wrong" }, { id: "a", label: "duplicate" }]);
    } catch (error) {
      duplicate = /duplicate/i.test(error.message);
    }
    check(
      duplicate && getLabel("a").textContent === "A2" && getInput("b") === b,
      "duplicate key changed committed rows",
    );

    let failed = false;
    try {
      rows.set([{ id: "a", label: "wrong" }, { id: "c", label: "C" }, { id: "bad" }]);
    } catch (error) {
      failed = error.message === "row setup failed";
    }
    await Promise.resolve();
    check(
      failed && getLabel("a").textContent === "A2" && getInput("b") === b &&
        getInput("c") === null && document.activeElement === a,
      "failed insertion changed committed rows",
    );
    check(
      cleanups.filter((id) => id === "c").length === 1 && !starts.includes("c") &&
        !effects.includes("c") && childStops.join(",") === "c" && !childStarts.includes("c"),
      "staged row leaked",
    );

    rows.set([{ id: "a", label: "A3" }, { id: "c", label: "C" }]);
    check(bRunLifetime === bLifetime && bLifetime.root === null &&
      bLifetime.abort.aborted && bDisposal.join(",") === "abort,cleanup",
      "row startup and removal did not share one lifetime");
    check(
      getInput("a") === a && getLabel("a").textContent === "A3" && getInput("c") &&
        cleanups.filter((id) => id === "b").length === 1,
      "valid retry failed",
    );
    await Promise.resolve();
    check(childStarts.join(",") === "a,c", "single-root child startup lost or repeated");
  } finally {
    dispose();
  }
  check(
    host.childNodes.length === 0 && cleanups.filter((id) => id === "a").length === 1,
    "list teardown failed",
  );
  check(childStops.sort().join(",") === "a,c,c", "single-root child cleanup lost or repeated");
  checkPassiveRows(host);
  await checkBadgeOnConnection(host);
  await checkForeignOwnersOnTiles(host);
  checkTextBranch(host);
  checkNormalizedText(host);
  checkLateLifetime(host);
  return true;
}

function checkPassiveRows(host) {
  const NativeController = globalThis.AbortController;
  let controllers = 0;
  let dispose;
  const score = signal(10);
  const first = {id: 1, get score() { return score(); }};
  const second = {id: 2, score: 20};
  const rows = signal([first, second]);
  function tile(record) {
    const id = record().id;
    return <div class="cell" data-id={id}>{id + ' · ' + record().score}</div>;
  }
  try {
    globalThis.AbortController = class extends NativeController {
      constructor(...args) {
        super(...args);
        controllers++;
      }
    };
    const tiles = keyed(rows, record => record.id, tile);
    dispose = mount(host, () => <>{tiles}</>);
    const cell = host.firstElementChild, label = cell.firstChild;
    check(host.childNodes.length === 4 && host.firstChild.nodeType === Node.COMMENT_NODE &&
      host.lastChild.nodeType === Node.COMMENT_NODE && cell.childNodes.length === 1 &&
      label.nodeType === Node.TEXT_NODE, "expected just the list boundaries and one text node per tile");
    check(label.data === "1 · 10", "initial tile label missing");
    score.set(11);
    check(cell.firstChild === label && label.data === "1 · 11", "independent getter signal lost");
    rows.set([second, {id: 1, score: 12}]);
    check(host.lastElementChild === cell && cell.firstChild === label && label.data === "1 · 12",
      "retained tile or text replaced on reorder");
    score.set(99);
    check(label.data === "1 · 12", "replaced record retained its old getter");
    let invalid = false;
    try { rows.set([{id: null, score: 30}]); }
    catch (error) { invalid = error instanceof TypeError; }
    check(invalid && host.lastElementChild === cell && label.data === "1 · 12",
      "invalid key changed the committed tile");
    let provisionalReads = 0, failed = false;
    const provisional = {id: 3, get score() { provisionalReads++; return score(); }};
    const broken = {id: 4, get score() { throw new Error("tile failed"); }};
    try { rows.set([{id: 1, score: 50}, provisional, broken]); }
    catch (error) { failed = error.message === "tile failed"; }
    score.set(100);
    check(failed && provisionalReads === 1 && host.childNodes.length === 4 &&
      host.lastElementChild === cell && label.data === "1 · 12",
      "failed tile insertion changed committed tiles or left a staged reader subscribed");
    rows.set([{id: 3, score: 30}, {id: 4, score: 40}]);
    check(host.firstElementChild.textContent === "3 · 30" && host.lastElementChild.textContent === "4 · 40" &&
      !cell.isConnected, "disjoint keyed replacement failed");
  } finally {
    try { dispose?.(); }
    finally { globalThis.AbortController = NativeController; }
  }
  check(host.childNodes.length === 0, "passive keyed disposal failed");
  check(controllers === 0, "passive keyed rows constructed " + controllers + " AbortControllers");
}

async function checkBadgeOnConnection(host) {
  if (!customElements.get("saba-badge-cell")) {
    customElements.define("saba-badge-cell", class extends HTMLElement {
      connectedCallback() { this.append(this.badge); }
    });
  }
  const rows = signal([]), score = signal(1);
  let starts = 0, cleanups = 0, siblingCleanups = 0;
  const staging = document.createElement("div");
  const movedSiblings = [];
  const releaseBadge = mount(staging, () => {
    run(() => { starts++; });
    onCleanup(() => {
      cleanups++;
      staging.append(...movedSiblings);
    });
    return <span>{"badge " + score()}</span>;
  });
  const badge = staging.firstChild;
  const cells = keyed(rows, id => id, record => {
    const cell = <saba-badge-cell>{"cell " + record()}</saba-badge-cell>;
    cell.badge = badge;
    return cell;
  });
  const release = mount(host, () => <>{cells}</>);
  try {
    rows.set([1]);
    await Promise.resolve();
    check(starts === 1 && host.firstElementChild.lastChild === badge,
      "a component appended during row connection missed startup");
    const cell = host.firstElementChild;
    for (let i = 0; i < 2; i++) {
      mount(cell, () => {
        onCleanup(() => { siblingCleanups++; });
        return <i/>;
      });
      movedSiblings.push(cell.lastChild);
    }
    rows.set([]);
    score.set(2);
    check(cleanups === 1 && badge.textContent === "badge 1",
      "removing a cell leaked its independently mounted badge");
    check(siblingCleanups === 2 && staging.childElementCount === 2,
      "siblings moved by an earlier cleanup missed disposal");
  } finally { release(); releaseBadge(); }
}

async function checkForeignOwnersOnTiles(host) {
  const rows = signal(["ref", "text"]);
  const staging = document.createElement("div");
  let parentRef, starts = 0, cleanups = 0, releaseText, disconnect;
  const release = mount(staging, () => {
    parentRef = ref("firstTile");
    const tiles = keyed(rows, id => id, record => {
      if (record() === "ref") return <p ref={parentRef}>{"row " + record()}</p>;
      return <p>{"row " + record()}</p>;
    });
    return <>{tiles}</>;
  });
  try {
    check(parentRef.current === staging.firstElementChild, "tile did not bind its parent's ref");
    const cell = staging.lastElementChild, text = cell.firstChild;
    // The component adopts the existing Text, so the tile keeps its exact DOM shape.
    releaseText = mount(cell, () => {
      run(() => { starts++; });
      onCleanup(() => { cleanups++; });
      return text;
    });
    check(cell.firstChild === text && cell.lastChild === text, "adopting the text changed the tile");
    await Promise.resolve();
    check(starts === 0, "a detached text-rooted component started before connection");
    disconnect = mount(host, () => staging);
    await Promise.resolve();
    check(starts === 1, "a component rooted on a tile's only Text missed startup");
    rows.set([]);
    check(parentRef.current === null, "removing a passive tile left its parent's ref bound");
    check(cleanups === 1, "removing a passive tile leaked a second owner on its original text");
  } finally { release(); releaseText?.(); disconnect?.(); }
}

function checkTextBranch(host) {
  const version = signal(0), disposed = [];
  const value = {
    [Symbol.toPrimitive]() {
      const current = version();
      onCleanup(() => disposed.push(current));
      if (current === 1) throw new Error("text coercion failed");
      return current === 0 ? "" : "v" + current;
    },
  };
  const release = mount(host, () => <p>{"" + value}</p>);
  try {
    const empty = [...host.firstElementChild.childNodes].find(node => node.nodeType === Node.TEXT_NODE);
    check(empty?.data === "", "an empty string did not produce a text node");
    let failed = false;
    try { version.set(1); } catch (error) { failed = error.message === "text coercion failed"; }
    check(failed && empty.isConnected && empty.data === "" && disposed.join(",") === "1",
      "failed text evaluation changed the committed branch or leaked its cleanup");
    version.set(2);
    check(host.textContent === "v2" && disposed.join(",") === "1,0",
      "text binding did not recover or release its previous branch");
  } finally { release(); }
  check(disposed.join(",") === "1,0,2" && host.childNodes.length === 0,
    "text branch outlived its root");
}

function checkNormalizedText(host) {
  const left = signal(1), right = signal(2), value = signal("");
  let reads = 0;
  const source = {get value() { reads++; return value(); }};
  const dispose = mount(host, () => <section>
    <p>{"a" + left()}{"b" + right()}</p>
    <output>{"" + source.value}</output>
  </section>);
  try {
    const pair = host.querySelector("p"), only = host.querySelector("output");
    check(pair.textContent === "a1b2" && only.textContent === "", "initial string children missing");
    host.normalize();
    left.set(3);
    check(pair.textContent === "a3b2", "normalized left binding overwrote its neighbor");
    right.set(4);
    check(pair.textContent === "a3b4", "normalized right binding lost its position");
    value.set("restored");
    check(only.textContent === "restored", "normalized empty text child did not become visible");
    value.set("");
    only.normalize();
    update(only, null);
    const readsAfterRemoval = reads;
    value.set("stale");
    check(only.childNodes.length === 0 && reads === readsAfterRemoval,
      "replacing normalized content left its text binding active");
  } finally { dispose(); }
}

function checkLateLifetime(host) {
  const remove = signal(false);
  let late;
  // Disposal from this effect keeps the component's own scope current through cleanup.
  const dispose = mount(host, () => {
    onCleanup(() => { late = lifetime(); });
    effect(() => { if (remove()) dispose(); });
    return <span>Late lifetime</span>;
  });
  remove.set(true);
  check(late.abort.aborted && late.root === null, "first lifetime read during disposal was still live");
}
