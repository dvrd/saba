import htmx from 'htmx.org';
import 'idiomorph/htmx';
import { startDashboard } from './dashboard.js';

// The interaction controller owns pointer geometry. The server independently
// applies each action to its board and returns the HTML that htmx displays.
startDashboard(async (host, initial) => {
  const token = crypto.randomUUID();
  host.setAttribute('hx-ext', 'morph');
  htmx.process(host);
  async function request(snapshot, action) {
    const payload = {token, revision: String(snapshot.revision), action: JSON.stringify(action)};
    await htmx.ajax('POST', '/board', {
      source: host, target: host, swap: 'morph:innerHTML settle:0ms', values: payload,
    });
    if (host.querySelector('#board')?.dataset.revision !== String(snapshot.revision)) {
      throw new Error('The server board revision did not reach the DOM');
    }
  }
  await request(initial, {type: 'init'});
  return request;
});
