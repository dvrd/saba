import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdir, mkdtemp, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';
import { transform as compileSolid } from '@solidjs/compiler';
import { compile as compileSvelte } from 'svelte/compiler';

const directory = path.dirname(fileURLToPath(import.meta.url));
const rich = process.argv.includes('--rich');
const scale = process.argv.includes('--scale');
const compiledSaba = process.argv.includes('--compiled-saba');
if (rich && scale) throw Error('Select one benchmark workload per build');
if (compiledSaba && !scale) throw Error('--compiled-saba requires --scale');
const output = path.join(directory, 'dist', scale ? 'scale' : rich ? 'rich' : '');
const sabaDOM = path.resolve(directory, '../../src/modules/dom.js');
const entries = scale ? {
  react: 'rich/scale-react.jsx',
  solid: 'rich/scale-solid.jsx',
  svelte: 'rich/scale-svelte.js',
  ...(compiledSaba ? {
    'saba-compiled': 'rich/scale-saba.jsx',
    'saba-compiled-window': 'rich/scale-saba-window.jsx',
  } : {}),
} : rich ? {
  'saba-current': 'rich/saba-current.js',
  'saba-planned': 'rich/saba-planned.js',
  vanilla: 'rich/vanilla.js',
  react: 'rich/react.jsx',
  solid: 'rich/solid.jsx',
  svelte: 'rich/svelte.js',
  htmx: 'rich/htmx.js',
} : {
  'saba-current': '../../benchmarks/mesa/entry.js',
  'saba-planned': '../../benchmarks/mesa/planned.js',
  vanilla: 'src/vanilla.js',
  react: 'src/react.jsx',
  solid: 'src/solid.jsx',
  svelte: 'src/svelte.js',
  htmx: 'src/htmx.js',
};
const sha256 = data => createHash('sha256').update(data).digest('hex');
const config = JSON.parse(await readFile(path.join(directory, 'package.json'), 'utf8'));

const resolveSabaRuntime = {
  name: 'saba-runtime',
  setup(builder) {
    builder.onResolve({ filter: /^\/__saba\/dom\.js$/ }, () => ({ path: sabaDOM }));
    builder.onResolve({ filter: /^\/__saba\/slot-window\.js$/ }, () => ({
      path: path.resolve(directory, '../../src/modules/slot-window.js'),
    }));
  },
};
const root = path.resolve(directory, '../..');
const sabaCompiler = {
  name: 'saba-jsx',
  setup(builder) {
    builder.onLoad({ filter: /\.jsx$/ }, async ({ path: filename }) => {
      const temp = await mkdtemp(path.join(tmpdir(), 'saba-grid-compile-'));
      try {
        let shared = process.env.WEBTOOLS_SHARED;
        if (!shared) {
          execFileSync('krs', ['install', '--frozen', '--root=' + temp], { cwd: root, stdio: 'inherit' });
          shared = path.join(temp, 'shared');
        }
        const generated = path.join(temp, 'grid.js');
        execFileSync(process.env.ODIN || 'odin', [
          'run', path.join(directory, 'operations/compile'), '-collection:shared=' + shared,
          '-out:' + path.join(temp, 'compiler'), '--', filename, generated,
        ], { cwd: root, stdio: 'inherit' });
        return { contents: await readFile(generated, 'utf8'), loader: 'js' };
      } finally {
        await rm(temp, { recursive: true, force: true });
      }
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
      if (result.css?.code) throw Error('Frameworks must use the shared editor stylesheet');
      return { contents: result.js.code, loader: 'js' };
    });
  },
};

await mkdir(output, { recursive: true });
const manifest = {
  versions: config.dependencies,
  lockSha256: sha256(await readFile(path.join(directory, 'package-lock.json'))),
  bundles: {},
};
if (compiledSaba) {
  const sources = ['.krs/packages.json', 'src/modules/dom.js', 'src/modules/slot-window.js',
    'src/modules/scalar-records.js', 'benchmarks/frameworks/operations/compile/main.odin',
    'benchmarks/frameworks/rich/scale-saba.jsx', 'benchmarks/frameworks/rich/scale-saba-window.jsx'];
  for (const file of (await readdir(path.join(root, 'src/jsx'))).sort()) {
    if (file.endsWith('.odin')) sources.push('src/jsx/' + file);
  }
  manifest.sabaSourceSha256 = {};
  for (const file of sources) manifest.sabaSourceSha256[file] = sha256(await readFile(path.join(root, file)));
}
for (const [name, file] of Object.entries(entries)) {
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
    define: { 'process.env.NODE_ENV': '"production"' },
    plugins: [resolveSabaRuntime, ...(name === 'solid' ? [solidCompiler] : []),
      ...(name.startsWith('saba-compiled') ? [sabaCompiler] : []),
      ...(name === 'svelte' ? [svelteCompiler] : [])],
    metafile: true,
    write: false,
  });
  const outputs = Object.values(result.metafile.outputs);
  if (outputs.length !== 1 || outputs[0].imports.length) {
    throw Error('Expected one self-contained JavaScript module for ' + name);
  }
  const bytes = result.outputFiles[0].contents;
  await writeFile(outfile, bytes);
  manifest.bundles[name] = { file: name + '.js', bytes: bytes.length, sha256: sha256(bytes) };
  console.log(name, bytes.length, 'bytes');
}
await writeFile(path.join(output, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
