// Chromium records these stage ends using presentation feedback timestamps.
// Match the enclosing pipeline's final state so skipped/dropped frames do
// not become displayed frames. Trace timestamps are monotonic microseconds.
const stage = 'SwapEndToPresentationCompositorFrame';
const pipeline = 'PipelineReporter';
const startMark = 'rich-drop-commit';
const finishMark = 'rich-drop-finish';

function missing(reason, windowMs = null) {
  return {available: false, event: stage, reason, count: 0, timestampsMs: [], maxGapMs: null,
    medianGapMs: null, windowMs, firstMs: null, tailMs: null};
}

function summarize(events) {
  const start = events.find(e => e.name === startMark);
  const finish = events.find(e => e.name === finishMark && e.pid === start?.pid);
  if (!start || !finish || finish.ts <= start.ts) return missing('Animation boundary mark missing');
  const windowMs = (finish.ts - start.ts) / 1000;
  const frameEvents = events.filter(e => e.pid === start.pid).sort((a, b) => a.ts - b.ts);
  const states = new Map();
  const presentedEnds = new Set();
  const stageEnds = [];
  // Local trace IDs are recycled after a pipeline ends and are scoped to this process.
  for (const e of frameEvents) {
    const id = e.id2?.local;
    if (id === undefined) continue;
    if (e.name === pipeline && e.ph === 'b') {
      states.set(id, e.args?.frame_reporter?.state);
    } else if (e.name === pipeline && e.ph === 'e') {
      if (states.get(id)?.startsWith('STATE_PRESENTED_')) presentedEnds.add(id + '/' + e.ts);
      states.delete(id);
    } else if (e.name === stage && e.ph === 'e' && e.ts >= start.ts && e.ts <= finish.ts) {
      stageEnds.push([id, e.ts]);
    }
  }
  const timestampsMs = [...new Set(stageEnds.filter(([id, ts]) => presentedEnds.has(id + '/' + ts))
    .map(([, ts]) => (ts - start.ts) / 1000))].sort((a, b) => a - b);
  if (!timestampsMs.length) return missing('No matched presented compositor frames', windowMs);
  const gaps = timestampsMs.slice(1).map((v, i) => v - timestampsMs[i]).sort((a, b) => a - b);
  const middle = Math.floor(gaps.length / 2);
  const medianGapMs = gaps.length % 2 ? gaps[middle] : (gaps[middle - 1] + gaps[middle]) / 2;
  return {available: true, event: stage, count: timestampsMs.length, timestampsMs,
    maxGapMs: gaps.at(-1) ?? null, medianGapMs: gaps.length ? medianGapMs : null,
    windowMs, firstMs: timestampsMs[0], tailMs: windowMs - timestampsMs.at(-1)};
}

export async function startPresentation(cdp) {
  const events = [];
  function collect({value}) {
    for (const e of value) {
      if (e.name === stage || e.name === pipeline || e.name === startMark || e.name === finishMark) {
        events.push(e);
      }
    }
  }
  cdp.on('Tracing.dataCollected', collect);
  try {
    await cdp.send('Tracing.start', {categories: 'blink.user_timing,disabled-by-default-devtools.timeline.frame',
      transferMode: 'ReportEvents'});
  } catch (error) {
    cdp.off('Tracing.dataCollected', collect);
    return async () => missing(String(error));
  }
  return async function finish() {
    let complete, timer;
    try {
      const ended = new Promise(resolve => {
        complete = () => resolve(true);
        cdp.once('Tracing.tracingComplete', complete);
        timer = setTimeout(() => resolve(false), 6000);
      });
      await cdp.send('Tracing.end');
      if (!await ended) return missing('Timed out waiting for the compositor trace');
      return summarize(events);
    } catch (error) {
      return missing(String(error));
    } finally {
      clearTimeout(timer);
      cdp.off('Tracing.tracingComplete', complete);
      cdp.off('Tracing.dataCollected', collect);
    }
  };
}
