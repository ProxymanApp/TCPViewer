import { build } from 'esbuild';
import { copyFile, mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('.', import.meta.url));
const output = new URL('MonacoDiff/', import.meta.url);
const common = { absWorkingDir: root, bundle: true, minify: true, format: 'iife', target: 'safari18', legalComments: 'eof' };
await mkdir(output, { recursive: true });

// A self-contained blob worker works in WKWebView's file origin without a server or network access.
const worker = await build({ ...common, entryPoints: ['node_modules/monaco-editor/esm/vs/editor/editor.worker.js'], write: false });
const result = await build({
  ...common,
  entryPoints: ['src/index.js'],
  outfile: 'MonacoDiff/diff.js',
  loader: { '.ttf': 'dataurl' },
  metafile: true,
  plugins: [{
    name: 'bundled-diff-worker',
    setup(build) {
      build.onResolve({ filter: /^diff-worker-source$/ }, () => ({ path: 'worker', namespace: 'inline-worker' }));
      build.onLoad({ filter: /.*/, namespace: 'inline-worker' }, () => ({ contents: `export default ${JSON.stringify(worker.outputFiles[0].text)}` }));
    }
  }]
});

// Fail upgrades that accidentally pull language services or scripting features into the diff bundle.
const inputs = Object.keys(result.metafile.inputs);
if (inputs.some(path => /\/languages\/definitions\/|\/language\/|\/contrib\/(suggest|inlineCompletions)\//.test(path))) {
  throw new Error('The diff bundle unexpectedly includes language or completion services.');
}
await copyFile(new URL('src/index.html', import.meta.url), new URL('index.html', output));
await copyFile(new URL('node_modules/monaco-editor/LICENSE', import.meta.url), new URL('LICENSE.txt', output));
await copyFile(new URL('node_modules/monaco-editor/ThirdPartyNotices.txt', import.meta.url), new URL('ThirdPartyNotices.txt', output));
await writeFile(new URL('VERSION', output), 'monaco-editor 0.57.0\nesbuild 0.28.2\n');
for (const [path, info] of Object.entries(result.metafile.outputs)) {
  console.log(`${path}: ${(info.bytes / 1024 / 1024).toFixed(2)} MiB`);
}
