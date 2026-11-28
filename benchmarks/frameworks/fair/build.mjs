import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';
import { transform as compileSolid } from '@solidjs/compiler';
import { compile as compileSvelte } from 'svelte/compiler';

const directory = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const root = path.resolve(directory, '../..');
const output = path.join(directory, 'dist', 'fair');
const sha256 = data => createHash('sha256').update(data).digest('hex');
const config = JSON.parse(await readFile(path.join(directory, 'package.json'), 'utf8'));

let shared = process.env.WEBTOOLS_SHARED;
let sharedRoot;
if (!shared) {
  sharedRoot = await mkdtemp(path.join(tmpdir(), 'saba-fair-root-'));
  execFileSync('krs', ['install', '--frozen', '--root=' + sharedRoot], { cwd: root, stdio: 'inherit' });
  shared = path.join(sharedRoot, 'shared');
}

const compileDir = await mkdtemp(path.join(tmpdir(), 'saba-fair-jsx-'));
const compilerBin = path.join(compileDir, 'saba-jsx-compiler');
await mkdir(output, { recursive: true });
execFileSync(process.env.ODIN || 'odin', [
  'build', path.join(directory, 'operations/compile'),
  '-collection:shared=' + shared,
  '-out:' + compilerBin,
], { cwd: root, stdio: 'inherit' });

const resolveSabaRuntime = {
  name: 'saba-runtime',
  setup(builder) {
    builder.onResolve({ filter: /^\/__saba\/dom\.js$/ }, () => ({
      path: path.join(root, 'src/modules/dom.js'),
    }));
    builder.onResolve({ filter: /^\/__saba\/slot-window\.js$/ }, () => ({
      path: path.join(root, 'src/modules/slot-window.js'),
    }));
  },
};

const sabaCompiler = {
  name: 'saba-jsx',
  setup(builder) {
    builder.onLoad({ filter: /\.jsx$/ }, async ({ path: filename }) => {
      const generated = path.join(compileDir, path.basename(filename, '.jsx') + '.compiled.js');
      execFileSync(compilerBin, [filename, generated], { cwd: root, stdio: 'inherit' });
      return { contents: await readFile(generated, 'utf8'), loader: 'js' };
    });
  },
};

const solidCompiler = {
  name: 'solid-browser',
  setup(builder) {
    builder.onLoad({ filter: /\.jsx$/ }, async ({ path: filename }) => {
      const module = compileSolid(await readFile(filename, 'utf8'), {
        filename, generate: 'dom', hydratable: false, dev: false,
      });
      return { contents: module.code, loader: 'js' };
    });
  },
};

const svelteCompiler = {
  name: 'svelte-browser',
  setup(builder) {
    builder.onLoad({ filter: /\.svelte$/ }, async ({ path: filename }) => {
      const result = compileSvelte(await readFile(filename, 'utf8'), {
        filename, generate: 'client', dev: false,
      });
      if (result.css?.code) throw new Error(filename + ' must use the shared bench stylesheet');
      return { contents: result.js.code, loader: 'js' };
    });
  },
};

const entries = {
  'vanilla-keyed': ['fair/vanilla-keyed.js'],
  'vanilla-slot': ['fair/vanilla-slot.js', resolveSabaRuntime],
  'saba-keyed': ['fair/saba-keyed.jsx', resolveSabaRuntime, sabaCompiler],
  'saba-slot': ['fair/saba-slot.jsx', resolveSabaRuntime, sabaCompiler],
  react: ['fair/react.jsx'],
  preact: ['fair/preact.jsx'],
  solid: ['fair/solid.jsx', solidCompiler],
  svelte: ['fair/svelte.js', svelteCompiler],
  idiomorph: ['fair/idiomorph.js'],
};

const manifest = {
  versions: config.dependencies,
  bundles: {},
  sources: {},
};
const sourceFiles = [
  'src/modules/dom.js',
  'src/modules/slot-window.js',
  'src/modules/scalar-records.js',
];
for (const file of sourceFiles) {
  manifest.sources[file] = sha256(await readFile(path.join(root, file)));
}

for (const [name, [file, ...plugins]] of Object.entries(entries)) {
  const outfile = path.join(output, name + '.js');
  const result = await build({
    absWorkingDir: directory,
    entryPoints: [file],
    outfile,
    bundle: true,
    minify: true,
    format: 'esm',
    platform: 'browser',
    conditions: ['browser', 'production'],
    target: 'es2022',
    jsx: 'automatic',
    jsxImportSource: name === 'preact' ? 'preact' : 'react',
    define: { 'process.env.NODE_ENV': '"production"' },
    plugins,
    metafile: true,
    write: false,
  });
  const outputs = Object.values(result.metafile.outputs);
  if (outputs.length !== 1 || outputs[0].imports.length) {
    throw new Error('Expected one self-contained module for ' + name);
  }
  const bytes = result.outputFiles[0].contents;
  await writeFile(outfile, bytes);
  manifest.bundles[name] = { bytes: bytes.length, sha256: sha256(bytes) };
  console.log(name, bytes.length);
}

await writeFile(path.join(output, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
await rm(compileDir, { recursive: true, force: true });
if (sharedRoot) await rm(sharedRoot, { recursive: true, force: true });
