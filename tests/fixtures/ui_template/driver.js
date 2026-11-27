import {__sabaAttach} from "./page.js";
import {createReadPartition} from "/__saba/reads.js";

function check(condition, message) {
  if (!condition) throw new Error(message);
}

export async function verifyTemplates() {
  const response = await fetch("/template-test/fragment");
  check(response.ok, "Compiled template response failed");
  const bytes = await response.text();
  const host = document.body.appendChild(document.createElement("section"));
  const counters = () => {
    const state = {setups:0, cleanups:0, starts:0, loads:0};
    state.partition = createReadPartition(async () => ++state.loads);
    return state;
  };
  try {
    host.innerHTML = bytes;
    const heading = host.querySelector("h1"), input = host.querySelector("input");
    const badges = [...host.querySelectorAll("output")];
    const score = host.querySelector(".score");
    check(heading.textContent === "Inbox & activity" && badges.length === 2 && badges.every(item => !item.textContent), "First response omitted static UI or contained private counts");
    const chart = host.querySelector("aside");
    check(!chart.querySelector("svg"), "A foreign subtree must start in a client-owned range");
    input.focus();
    const run = counters();
    const release = __sabaAttach(host, {run});
    await Promise.resolve();
    const foreign = chart.querySelector("foreignObject"), inner = foreign.firstElementChild;
    check(foreign.namespaceURI === "http://www.w3.org/2000/svg" && inner.namespaceURI === "http://www.w3.org/1999/xhtml" && inner.firstElementChild.namespaceURI === foreign.namespaceURI && chart.querySelector("mi").namespaceURI === "http://www.w3.org/1998/Math/MathML", "Foreign insertion namespaces changed in a compiled template");
    check(run.loads === 1, "Two active instances should share one initial request");
    const second = [...badges[1].childNodes].find(node => node.nodeType === Node.TEXT_NODE);
    const scoreText = [...score.childNodes].find(node => node.nodeType === Node.TEXT_NODE);
    check(scoreText?.data === "Score 9", "Template string child did not attach");
    host.querySelector("button").click();
    check(host.querySelector(".score") === score && score.contains(scoreText) && scoreText.data === "Score 10",
      "Template string child lost its original element or text on update");
    check(heading === host.querySelector("h1") && document.activeElement === input, "Template activation replaced heading or focus");
    check(badges[0].textContent === "2" && badges[1].textContent === "10" && second.data === "10", "Repeated badge ownership or text identity failed");
    check(host.querySelector("td").textContent === "2" && run.setups === 2 && run.starts === 2, "Table binding or activation count failed");
    release();
    check(run.cleanups === 2, "Template disposal failed");
    for (const mode of ["corrupt", "setup", "commit"]) {
      host.innerHTML = bytes;
      const state = counters();
      host.inert = true;
      if (mode === "corrupt") host.querySelectorAll("output")[1].firstChild.data += ":corrupt";
      if (mode === "commit") {
        const target = host.querySelector("input");
        target.setAttribute = function(name, value) {
          if (name === "data-ready") {
            delete this.setAttribute;
            throw new Error("fixture native DOM write failure");
          }
          return Element.prototype.setAttribute.call(this, name, value);
        };
      }
      const oldHeading = host.querySelector("h1");
      const before = host.innerHTML;
      let failure;
      try { __sabaAttach(host, {run:state, fail:mode === "setup"}); } catch (error) { failure = error; }
      await Promise.resolve();
      check(state.loads === 0 && host.inert, "Failed attachment started a request or enabled controls");
      check(failure && host.innerHTML === before && host.querySelector("h1") === oldHeading, "Failed attachment changed the initial DOM");
      host.querySelector("button").click();
      check(state.starts === 0 && state.cleanups === state.setups && state.setups === (mode === "corrupt" ? 0 : 2), "Failed setup leaked work or ran before preflight");
    }
    return true;
  } finally { host.remove(); }
}
