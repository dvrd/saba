// Run from any directory. Pass an output JSON path to save the results.
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFile, writeFile} from 'node:fs/promises';
import {brotliCompressSync, constants, gzipSync} from 'node:zlib';
import {build, version as esbuildVersion} from 'esbuild';

const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const read = filename => readFile(new URL(filename, import.meta.url), 'utf8');
const [fixed, scale, band, lock] = await Promise.all([
  read('./fixed-cell.js'), read('../rich/scale.js'), read('./text-band.js'), read('../package-lock.json'),
]);
assert.equal(esbuildVersion, JSON.parse(lock).packages['node_modules/esbuild'].version);

// Extract the same baseline band and setter used by the scale experiment.
// Give each standalone entry one public export with the same name.
const bandStart = 'if (mountCell) mountBand = ';
const bandEnd = '\n\nfunction makeBand()';
function replaceOnce(source, before, after) {
  assert.equal(source.split(before).length, 2, 'Expected one fixture marker: ' + before);
  return source.replace(before, after);
}
assert.equal(scale.split(bandStart).length, 2);
assert.equal(scale.split(bandEnd).length, 2);
const oldBand = scale.slice(scale.indexOf(bandStart) + bandStart.length, scale.indexOf(bandEnd));
const withAttribute = replaceOnce(fixed, 'this.node.dataset.id = String(record.id);',
  "this.node.setAttribute('data-id', String(record.id));");
const privateCell = replaceOnce(withAttribute, 'export const mountCell', 'const mountCell');
const privateBand = replaceOnce(replaceOnce(band, 'export function mountTextBand', 'function mountTextBand'),
  'export function mountDomBand', 'function mountDomBand');
const entries = {
  'saba-fixed-input-attr': privateCell + '\nexport const mount = ' + oldBand + '\n',
  'saba-band-text': privateBand + '\nexport {mountTextBand as mount};\n',
  'saba-band-dom': privateBand + '\nexport {mountDomBand as mount};\n',
};
const options = {
  format: 'esm', platform: 'browser', target: 'es2022', charset: 'ascii',
  bundle: true, treeShaking: true, legalComments: 'none',
};
const report = {
  scope: 'One standalone renderer module exporting mount(host, records), with replace and dispose. Includes keyed structural fallback. Excludes page, data, styles, benchmark driver and HTTP headers. The shared workload uses immutable normalized records with contiguous numeric keys.',
  esbuildVersion, options, compression: {brotliQuality: 11, gzipLevel: 9},
  zlibVersion: process.versions.zlib, brotliVersion: process.versions.brotli,
  sourceSha256: {'fixed-cell.js': sha256(fixed), 'rich/scale.js': sha256(scale), 'text-band.js': sha256(band)},
  entries: {},
};
for (const [name, contents] of Object.entries(entries)) {
  const sizes = {inputBytes: Buffer.byteLength(contents)};
  for (const minify of [false, true]) {
    const {outputFiles, metafile} = await build({
      ...options, minify, stdin: {contents, sourcefile: 'renderer.js'},
      metafile: true, write: false,
    });
    assert.equal(outputFiles.length, 1);
    const [output] = Object.values(metafile.outputs);
    assert.deepEqual(output.exports, ['mount']);
    assert.deepEqual(output.imports, []);
    const bytes = outputFiles[0].contents;
    sizes[minify ? 'minified' : 'unminified'] = {
      bytes: bytes.length,
      brotliBytes: brotliCompressSync(bytes, {params: {[constants.BROTLI_PARAM_QUALITY]: 11}}).length,
      gzipBytes: gzipSync(bytes, {level: 9}).length,
      sha256: sha256(bytes),
    };
  }
  report.entries[name] = sizes;
}

const json = JSON.stringify(report, null, 2) + '\n';
if (process.argv[2]) await writeFile(process.argv[2], json);
else process.stdout.write(json);
