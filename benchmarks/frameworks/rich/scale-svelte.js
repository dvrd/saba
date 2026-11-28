import { flushSync, mount, unmount } from 'svelte';
import Band from './ScaleBand.svelte';

export function mountScaleBand(host, initialRecords) {
  const band = mount(Band, {target:host});
  const replace = records => flushSync(() => band.replace(records));
  replace(initialRecords);
  return {replace, dispose:() => unmount(band)};
}
