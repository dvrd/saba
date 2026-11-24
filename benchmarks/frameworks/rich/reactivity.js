// The hand-authored signal/effect design used in testdata/mesa_perf/planned.js.
let tracking = null;

export function signal(initial) {
  let value = initial;
  const effects = new Set();
  return {
    read() {
      if (tracking) {
        effects.add(tracking);
        tracking.dependencies.add(effects);
      }
      return value;
    },
    write(next) {
      if (Object.is(value, next)) return;
      value = next;
      for (const effect of [...effects]) effect.run();
    },
  };
}

export function effect(callback) {
  const owner = {
    dependencies: new Set(),
    dispose() {
      for (const subscribers of owner.dependencies) subscribers.delete(owner);
      owner.dependencies.clear();
    },
    run() {
      owner.dispose();
      const outer = tracking;
      tracking = owner;
      try { callback(); }
      finally { tracking = outer; }
    },
  };
  owner.run();
  return owner;
}
