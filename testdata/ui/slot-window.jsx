import {mount, onCleanup, run, signal} from "/__saba/dom.js";
import {mountSlotWindow, scalarRecord} from "/__saba/slot-window.js";

function Tile(record) {
  return <div class="cell" data-id={record().id}>{record().id + " · " + record().score}</div>;
}

function Caption(record) {
  return <span data-id={record().id}>{"score " + record().score}</span>;
}

function check(ok, message) {
  if (!ok) throw new Error(message);
}

function checkCells(host, records) {
  const cells = [...host.children];
  check(cells.length === records.length, "incorrect slot count");
  for (let i = 0; i < cells.length; i++) {
    const {id, score} = records[i], cell = cells[i];
    check(cell.className === "cell" && cell.getAttribute("data-id") === String(id) &&
      cell.childNodes.length === 1 && cell.firstChild.nodeType === Node.TEXT_NODE &&
      cell.firstChild.data === id + " · " + score, "incorrect slot at position " + i);
  }
  return cells;
}

function checkWindowChanges(host) {
  const model = Array.from({length: 1024}, (_, i) => scalarRecord({id: i * 13 + 3, score: i % 11}));
  const view = mountSlotWindow(host, Tile);
  const observer = new MutationObserver(() => {});
  observer.observe(host, {childList: true});
  const show = (first, count) => {
    const values = model.slice(first, first + count);
    // The scroll controller positions the host before asking for new rows.
    host.style.top = first * 24 + "px";
    view.replace(first, values);
    return checkCells(host, values);
  };
  function movedElements() {
    return observer.takeRecords().flatMap(mutation => [...mutation.addedNodes])
      .filter(node => node.nodeType === Node.ELEMENT_NODE);
  }
  try {
    const first = show(0, 192), texts = first.map(cell => cell.firstChild);
    observer.takeRecords();
    const last = show(768, 192);
    check(last.every((cell, i) => cell === first[i] && cell.firstChild === texts[i]) &&
      movedElements().length === 0, "disjoint jump remounted or moved a physical slot");

    const left = show(400, 256);
    const labels = new Map(left.map(cell => [cell, cell.firstChild]));
    observer.takeRecords();
    const right = show(464, 256);
    const movedForward = movedElements(), outgoingLeft = new Set(left.slice(0, 64));
    check(right.slice(0, 192).every((cell, i) => cell === left[i + 64]) &&
      right.every(cell => cell.firstChild === labels.get(cell)) &&
      movedForward.length === 64 && movedForward.every(cell => outgoingLeft.delete(cell)),
      "forward refill moved retained slots or failed to recycle the outgoing edge");
    const back = show(400, 256);
    const movedBackward = movedElements(), outgoingRight = new Set(right.slice(192));
    check(back.slice(64).every((cell, i) => cell === right[i]) &&
      back.every(cell => cell.firstChild === labels.get(cell)) &&
      movedBackward.length === 64 && movedBackward.every(cell => outgoingRight.delete(cell)),
      "backward refill moved retained slots or failed to recycle the outgoing edge");

    const cropped = show(410, 3);
    check(cropped.every((cell, i) => cell === back[i + 10]), "shrinking the pool replaced overlapping cells");
    let refused = false;
    try { view.replace(Number.MAX_SAFE_INTEGER, [model[0]]); } catch (error) { refused = error instanceof RangeError; }
    check(refused && host.children.length === 3 && host.firstElementChild === cropped[0],
      "invalid window bounds changed the committed rows");
    const duplicates = [scalarRecord({id: 5, score: 1}), scalarRecord({id: 5, score: 2})];
    view.replace(410, duplicates);
    const samePositions = checkCells(host, duplicates);
    check(samePositions.every((cell, i) => cell === cropped[i]),
      "replacing data at the same positions recreated slots with repeated record IDs");
    show(0, 0);
    show(31, 1);
  } finally { observer.disconnect(); view.dispose(); }
  check(host.childNodes.length === 0, "slot pool left DOM after disposal");
}

function checkTrackedRecords(host) {
  const view = mountSlotWindow(host, Tile);
  const input = {id: 21, score: 5}, plain = scalarRecord(input);
  input.score = 500;
  const current = signal(6);
  let reads = 0, provisionalReads = 0;
  const live = Object.freeze({id: "live", get score() { reads++; return current(); }});
  try {
    let refused = false;
    try { scalarRecord(live); } catch (error) { refused = error instanceof TypeError; }
    check(refused && reads === 0, "certifying a record executed its getter");
    view.replace(10, [plain]);
    const [cell] = checkCells(host, [{id: 21, score: 5}]), text = cell.firstChild;
    view.replace(80, [live]);
    check(cell === host.firstElementChild && cell.firstChild === text && text.data === "live · 6" &&
      cell.dataset.id === "live" && reads === 1, "promoting a plain slot lost identity or repeated the getter");
    current.set(7);
    check(text.data === "live · 7" && reads === 2, "independent score signal did not update the slot");

    const staged = {id: 14, get score() { provisionalReads++; return current(); }};
    const broken = {id: 17, get score() { throw new Error("slot preparation failed"); }};
    let failed = false;
    try { view.replace(200, [staged, broken]); } catch (error) { failed = error.message === "slot preparation failed"; }
    check(failed && host.children.length === 1 && host.firstElementChild === cell &&
      text.data === "live · 7" && cell.dataset.id === "live", "failed rebind changed the committed slot");
    const before = provisionalReads;
    current.set(8);
    check(provisionalReads === before && text.data === "live · 8", "failed rebind leaked or disconnected a binding");
    const idWithBadAttribute = {
      [Symbol.toPrimitive](hint) {
        if (hint === "string") throw new Error("attribute coercion failed");
        return "id";
      },
    };
    failed = false;
    try { view.replace(200, [plain, {id: idWithBadAttribute, score: 1}]); }
    catch (error) { failed = error.message === "attribute coercion failed"; }
    check(failed && host.children.length === 1 && host.firstElementChild === cell &&
      cell.dataset.id === "live" && text.data === "live · 8", "attribute coercion partially committed a new window");
    view.replace(300, [plain]);
    const retired = reads;
    current.set(9);
    check(reads === retired && cell === host.firstElementChild && cell.firstChild === text &&
      text.data === "21 · 5", "reusing a tracked slot retained its previous dependency");
    const liveAttribute = {[Symbol.toPrimitive](hint) { return hint === "string" ? current() : "text"; }};
    view.replace(320, [{id: liveAttribute, score: 0}]);
    current.set(10);
    check(cell.dataset.id === "10" && text.data === "text · 0", "attribute coercion missed its own signal");
    view.replace(321, [live]);
  } finally { view.dispose(); }
  const retired = reads;
  current.set(11);
  check(host.childNodes.length === 0 && reads === retired, "disposing the pool leaked a getter subscription");
}

function checkOwnership(host) {
  const view = mountSlotWindow(host, Tile);
  const score = signal(10);
  let cleanups = 0, releaseBadge;
  function attachBadge() {
    releaseBadge = mount(host.firstElementChild, () => {
      onCleanup(() => { cleanups++; });
      return <span>{"badge " + score()}</span>;
    });
    return host.querySelector("span");
  }
  try {
    const first = scalarRecord({id: 1, score: 1});
    view.replace(0, [first]);
    const cell = host.firstElementChild;
    cell.replaceChildren(document.createTextNode("outside change"));
    const broken = [first];
    Object.defineProperty(broken, "0", {get() { throw new Error("array read failed"); }});
    let failed = false;
    try { view.replace(0, broken); } catch (error) { failed = error.message === "array read failed"; }
    check(failed, "the source array error was swallowed");
    view.replace(0, [first]);
    checkCells(host, [first]);
    view.replace(100, [scalarRecord({id: 2, score: 2})]);
    checkCells(host, [{id: 2, score: 2}]);
    const badge = attachBadge();
    view.replace(200, [scalarRecord({id: 3, score: 3})]);
    score.set(11);
    checkCells(host, [{id: 3, score: 3}]);
    check(cleanups === 1 && !badge.isConnected && badge.textContent === "badge 10",
      "recycling a slot carried its previous record's nested mount to the next record");
    releaseBadge();
    const finalBadge = attachBadge();
    view.replace(0, []);
    score.set(12);
    check(cleanups === 2 && !finalBadge.isConnected && finalBadge.textContent === "badge 11",
      "removing a slot leaked an independently mounted child");
  } finally { view.dispose(); releaseBadge?.(); }
}

function checkDisposalDuringReplacement(host) {
  const view = mountSlotWindow(host, Tile);
  const score = signal(1);
  let reads = 0;
  view.replace(0, [scalarRecord({id: 1, score: 1})]);
  const remove = mount(host.firstElementChild, () => {
    onCleanup(() => view.dispose());
    return <i/>;
  });
  try {
    try { view.replace(100, [{id: 2, get score() { reads++; return score(); }}]); }
    catch (error) { check(/(ownership|disposed|closed)/i.test(error.message), "unexpected reentrant disposal error"); }
    const before = reads;
    score.set(2);
    check(host.childNodes.length === 0 && reads === before, "reentrant disposal left DOM or subscribed a staged getter");
    const next = mountSlotWindow(host, Tile);
    try { next.replace(0, [scalarRecord({id: 5, score: 0})]); checkCells(host, [{id: 5, score: 0}]); }
    finally { next.dispose(); }
  } finally { remove(); view.dispose(); }
}

async function checkTrackedStartup(host) {
  let starts = 0, root;
  const view = mountSlotWindow(host, Caption);
  try {
    view.replace(0, [{
      get id() {
        run(scope => { starts++; root = scope.root; });
        return 5;
      },
      score: 3,
    }]);
    await Promise.resolve();
    check(starts === 1 && root === host.firstElementChild && root.isConnected,
      "a tracked slot's startup missed the first connection to its host");
  } finally { view.dispose(); }
}

function checkStatefulRows(host) {
  const pulse = signal("a"), instances = [];
  function Stateful(record) {
    const clicks = signal(0), instance = {reads: 0, cleanups: 0};
    instances.push(instance);
    onCleanup(() => { instance.cleanups++; });
    const status = () => { instance.reads++; return pulse(); };
    return <button onClick={() => clicks.set(clicks() + 1)}>{record().id + ":" + clicks() + ":" + status()}</button>;
  }
  const view = mountSlotWindow(host, Stateful);
  try {
    view.replace(10, [{id: 1}, {id: 2}]);
    const retained = host.lastElementChild;
    retained.click();
    view.replace(11, [{id: 7}, {id: 8}]);
    check(host.firstElementChild === retained && retained.textContent === "7:1:a" &&
      instances.length === 3 && instances[0].cleanups === 1, "overlapping stateful row lost its local state");
    view.replace(80, [{id: 7}]);
    check(!retained.isConnected && host.firstElementChild.textContent === "7:0:a" && instances.length === 4,
      "disjoint stateful row carried local state across indices with the same record ID");
    const previous = instances.slice(0, 3), reads = previous.map(instance => instance.reads);
    pulse.set("b");
    check(host.firstElementChild.textContent === "7:0:b" &&
      previous.every((instance, i) => instance.cleanups === 1 && instance.reads === reads[i]),
      "retiring a stateful row leaked its signal subscription");
  } finally { view.dispose(); }
  const last = instances[3], reads = last.reads;
  pulse.set("c");
  check(last.cleanups === 1 && last.reads === reads && host.childNodes.length === 0, "stateful pool teardown leaked");
}

export async function observeSlots(host) {
  checkWindowChanges(host);
  checkTrackedRecords(host);
  checkOwnership(host);
  checkDisposalDuringReplacement(host);
  checkStatefulRows(host);
  await checkTrackedStartup(host);
  return true;
}
