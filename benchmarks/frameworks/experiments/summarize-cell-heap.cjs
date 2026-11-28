'use strict';

// node summarize-cell-heap.cjs <output JSON> <snapshot directory> [more directories]
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

function inspect(file, inspectBandReferences) {
  const {nodes, edges, strings, snapshot: {meta}} = JSON.parse(fs.readFileSync(file, 'utf8'));
  const nodeWidth = meta.node_fields.length;
  const edgeWidth = meta.edge_fields.length;
  const nodeTypes = meta.node_types[0], edgeTypes = meta.edge_types[0];
  assert.deepEqual(meta.node_fields.slice(0, 5), ['type', 'name', 'id', 'self_size', 'edge_count']);
  assert.deepEqual(meta.edge_fields, ['type', 'name_or_index', 'to_node']);
  const totals = {};
  const add = (key, size) => {
    const tally = totals[key] ||= {count: 0, shallowBytes: 0};
    tally.count++;
    tally.shallowBytes += size;
  };
  const type = node => nodeTypes[nodes[node]];
  const name = node => strings[nodes[node + 1]];
  const describe = node => type(node) + ':' + name(node);
  // Nodes store only the number of outgoing edges. Build offsets for following named references.
  const starts = new Uint32Array(nodes.length / nodeWidth + 1);
  let cursor = 0;
  for (let n = 0; n < nodes.length; n += nodeWidth) {
    starts[n / nodeWidth] = cursor;
    cursor += nodes[n + 4] * edgeWidth;
  }
  starts[starts.length - 1] = cursor;
  const slot = (node, edgeType, edgeName) => {
    if (node == null) return undefined;
    for (let e = starts[node / nodeWidth]; e < starts[node / nodeWidth + 1]; e += edgeWidth) {
      if (edgeTypes[edges[e]] === edgeType && strings[edges[e + 1]] === edgeName) return edges[e + 2];
    }
  };
  const setTables = new Set();
  const sample = {};
  const references = {arrayEntriesPointingToText: 0, fixedCellLabelPropertiesPointingToText: 0};
  for (let n = 0; n < nodes.length; n += nodeWidth) {
    const kind = type(n), label = name(n), bytes = nodes[n + 3];
    if (kind === 'native') {
      if (['DOMStringMap', 'Comment', 'Text'].includes(label)) add(label, bytes);
      else if (label.startsWith('<div class="cell"')) add('cellElement', bytes);
    } else if (kind === 'closure') {
      add('allClosures', bytes);
      if (['', 'read', 'write', 'dispose', 'run'].includes(label)) add('closure.' + (label || '(anonymous)'), bytes);
    } else if (kind === 'object') {
      if (label === 'Set') {
        add('Set', bytes);
        const table = slot(n, 'internal', 'table');
        if (table != null && !setTables.has(table)) {
          setTables.add(table);
          add('distinctSetBackingTables', nodes[table + 3]);
        }
      } else if (label === 'system / Context') add('lexicalContext', bytes);
      else if (label === 'FixedTextCell') {
        add('fixedCell', bytes);
        const target = slot(n, 'property', 'label');
        if (inspectBandReferences && target != null && describe(target) === 'native:Text') {
          references.fixedCellLabelPropertiesPointingToText++;
        }
      } else if (inspectBandReferences && label === 'Array') {
        for (let e = starts[n / nodeWidth]; e < starts[n / nodeWidth + 1]; e += edgeWidth) {
          if (edgeTypes[edges[e]] === 'element' && describe(edges[e + 2]) === 'native:Text') {
            references.arrayEntriesPointingToText++;
          }
        }
      } else if (label === 'Object') {
        const read = slot(n, 'property', 'read'), run = slot(n, 'property', 'run'), update = slot(n, 'property', 'update');
        if (read != null && describe(read) === 'closure:read') {
          add('signal', bytes);
          const effects = slot(slot(read, 'internal', 'context'), 'context', 'effects');
          if (effects != null) sample.signalReadContextEffects = describe(effects);
        }
        if (run != null && describe(run) === 'closure:run') {
          const dependencies = slot(n, 'property', 'dependencies');
          if (dependencies != null && describe(dependencies) === 'object:Set') {
            add('effect', bytes);
            sample.effectDependencies = describe(dependencies);
          }
        }
        if (update != null && describe(update) === 'closure:write') {
          add('cellBinding', bytes);
          sample.cellBindingUpdate = describe(update);
        }
      } else if (slot(n, 'property', 'pendingProps') != null && slot(n, 'property', 'memoizedProps') != null &&
                 slot(n, 'property', 'stateNode') != null && slot(n, 'property', 'return') != null &&
                 slot(n, 'property', 'alternate') != null) {
        add('fiber', bytes);
        sample.fiberConstructor = label;
      }
    }
  }
  return {totals, sample, references};
}

assert.ok(process.argv.length >= 4, 'Specify an output JSON and at least one snapshot directory.');
const result = {
  method: [
    'One isolated Chromium process per mode. Allocate records with window.scale.start() before the baseline garbage collection.',
    'Mount and lay out five 4,096-cell bands with window.scale.step(). After two animation frames collect garbage, read CDP counters and capture the heap.',
    'Heap metrics and object counts are mounted minus baseline for each mode. JS and embedder counters come from CDP Runtime.getHeapUsage.',
    'Each shallow byte count excludes descendants. Named closure groups are subsets of allClosures. The process RSS benchmark is independent.',
  ],
  visits: [],
};
for (const directory of process.argv.slice(3)) {
  const metrics = JSON.parse(fs.readFileSync(path.join(directory, 'metrics.json'), 'utf8'));
  if (metrics.reproduce) (result.reproduce ||= []).push(metrics.reproduce);
  const inspectBandReferences = metrics.visits.some(({mode}) => mode.startsWith('saba-band-'));
  for (const {mode, cells, base, full, sourceHashes} of metrics.visits) {
    const before = inspect(path.join(directory, mode + '-base.heapsnapshot'), inspectBandReferences);
    const after = inspect(path.join(directory, mode + '-mount.heapsnapshot'), inspectBandReferences);
    const classes = {};
    for (const tag of new Set([...Object.keys(before.totals), ...Object.keys(after.totals)])) {
      const a = before.totals[tag], b = after.totals[tag];
      const count = (b?.count || 0) - (a?.count || 0);
      const shallowBytes = (b?.shallowBytes || 0) - (a?.shallowBytes || 0);
      if (count || shallowBytes) classes[tag] = {count, shallowBytes};
    }
    const heap = {};
    for (const key of ['usedSize', 'embedderHeapUsedSize']) {
      const bytes = full.heap[key] - base.heap[key];
      heap[key] = {bytes, bytesPerCell: bytes / cells};
    }
    const dom = {};
    for (const key of Object.keys(full.dom)) dom[key] = full.dom[key] - base.dom[key];
    const visit = {mode, cells, browser: metrics.browser, cpu: metrics.cpu, sourceHashes: sourceHashes || metrics.sourceHashes,
      base, full, heap, dom, classes, sampleEdges: after.sample};
    if (inspectBandReferences) {
      visit.directReferences = {};
      for (const key of Object.keys(after.references)) {
        visit.directReferences[key] = after.references[key] - before.references[key];
      }
    }
    result.visits.push(visit);
  }
}
result.visits.sort((a, b) => a.mode.localeCompare(b.mode));
fs.writeFileSync(process.argv[2], JSON.stringify(result, null, 2) + '\n');
