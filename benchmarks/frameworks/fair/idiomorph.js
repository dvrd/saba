// Client half of the htmx strategy. The clock includes building the fragment
// and morphing it. There is no network and no server render in this number.
import { Idiomorph } from 'idiomorph';

export const kind = 'morph';

function html(records) {
  let out = '';
  for (let i = 0; i < records.length; i++) {
    const record = records[i];
    out += '<div class="cell" id="r' + record.id + '" data-id="' + record.id + '">' +
      record.id + ' · ' + record.score + '</div>';
  }
  return out;
}

export function mountBand(host, records) {
  function replace(next) {
    Idiomorph.morph(host, html(next), { morphStyle: 'innerHTML' });
  }
  replace(records);
  return { replace, dispose() { host.replaceChildren(); } };
}
