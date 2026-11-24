import {signal, effect, onCleanup} from "/__saba/dom.js";

export const title = "Inbox & activity";

function observe(props) {
  props.run.setups++;
  props.run.partition.read(["badges"]);
  onCleanup(() => props.run.cleanups++);
  effect(() => props.run.starts++);
  if (props.fail) throw new Error("fixture setup failure");
}

function Badge(props) {
  observe(props);
  return <output className="badge">{props.count}{props.suffix}</output>;
}

export default function Inbox(props) {
  const first = signal(2), second = signal(9);
  return <main>
    <h1>Inbox &amp; activity</h1>
    <Badge count={first()} suffix="" run={props.run}/>
    <Badge count={second()} suffix="" run={props.run} fail={props.fail}/>
    <p class="score">{'Score ' + second()}</p>
    <input aria-label="Search" data-ready={first() > 0}/>
    <button onClick={() => second.set(second() + 1)}>Increase</button>
    <aside><svg><foreignObject><div><svg><title>Activity</title></svg></div></foreignObject></svg><math><mi>k</mi></math></aside>
    <table><tbody><tr><td>{first()}</td></tr></tbody></table>
  </main>;
}
