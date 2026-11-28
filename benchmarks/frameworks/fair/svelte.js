import { flushSync, mount, unmount } from 'svelte';
import Band from './FairBand.svelte';

export const kind = 'keyed';

export function mountBand(host, records) {
  const band = mount(Band, { target: host });
  const replace = next => flushSync(() => band.replace(next));
  replace(records);
  return { replace, dispose: () => unmount(band) };
}
