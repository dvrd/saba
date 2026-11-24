import { batch, mount, onCleanup, signal } from "/__saba/dom.js";

export function observeForwarding(host) {
  const setups = [0, 0, 0];
  let cleanups = 0, reads = 0;
  const callback = () => "callback";
  let passedCallback;

  function Badge(props) {
    setups[2]++;
    const snapshot = props.count;
    passedCallback = props.callback;
    onCleanup(() => cleanups++);
    function readCount() {
      reads++;
      return props.count;
    }
    return <span><output>{readCount()}</output><small>{snapshot}</small></span>;
  }
  function Forward(props) {
    setups[1]++;
    return <Badge {...props}/>;
  }
  function Parent() {
    setups[0]++;
    const count = signal(2);
    const visible = signal(true);
    return <main>
      <button id="increment" onClick={() => count.set(count() + 1)}>Increment</button>
      <button id="remove" onClick={() => batch(() => {
        visible.set(false);
        count.set(4);
      })}>Remove</button>
      {visible() && <Forward count={count()} callback={callback}/>}
    </main>;
  }

  const dispose = mount(host, Parent);
  try {
    const output = host.querySelector("output");
    const text = Array.from(output.childNodes).find(n => n.nodeType === Node.TEXT_NODE);
    const initial = text.data;
    host.querySelector("#increment").click();
    const after = text.data;
    const sameNode = host.querySelector("output") === output && output.contains(text);
    const snapshot = host.querySelector("small").textContent;
    const beforeRemoval = reads;
    host.querySelector("#remove").click();
    host.querySelector("#increment").click();
    return {
      initial, after, sameNode, snapshot, setups, cleanups,
      readsAfterRemoval: reads - beforeRemoval,
      connectedAfterRemoval: output.isConnected,
      finalDetachedText: text.data,
      callbackIdentity: passedCallback === callback
    };
  } finally {
    dispose();
  }
}
