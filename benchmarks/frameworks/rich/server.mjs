import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { gzipSync } from 'node:zlib';
import { applyBoardAction, boardSnapshot, createBoard } from './board-model.js';
import { renderDashboardHTML } from './dashboard-html.js';

const base = new URL('../dist/rich/', import.meta.url);
export const modes = ['saba-current', 'saba-planned', 'vanilla', 'solid', 'react', 'svelte', 'htmx'];

export async function startServer() {
  const manifest = JSON.parse(await readFile(new URL('manifest.json', base), 'utf8'));
  const css = await readFile(new URL('dashboard.css', import.meta.url));
  const files = new Map([['/dashboard.css', ['text/css', css]]]);
  for (const mode of modes) {
    const bundle = manifest.bundles[mode];
    const body = await readFile(new URL(bundle.file, base));
    if (createHash('sha256').update(body).digest('hex') !== bundle.sha256) throw Error('Bundle changed: ' + mode);
    files.set('/'+mode+'.js', ['text/javascript', body]);
    const html = '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Project board</title><link rel="icon" href="data:,"><link rel="stylesheet" href="/dashboard.css"></head><body><div id="bench-status" role="status"></div><main id="app"></main><script type="module" src="/'+mode+'.js"></script></body></html>';
    files.set('/'+mode, ['text/html; charset=utf-8', Buffer.from(html)]);
  }
  const staticFiles = new Map([...files].map(([key,[type,body]]) => [key, {type,body,gzip:gzipSync(body)}]));
  const sessions = new Map();
  const server = createServer(async (req,res) => {
    try {
      if (req.method === 'GET' && staticFiles.has(req.url)) {
        const asset = staticFiles.get(req.url);
        const gzip = /\bgzip\b/.test(req.headers['accept-encoding'] || '');
        res.writeHead(200, {'Content-Type':asset.type, 'Cache-Control':'no-store', 'Vary':'Accept-Encoding', ...(gzip ? {'Content-Encoding':'gzip'} : {})});
        res.end(gzip ? asset.gzip : asset.body);
        return;
      }
      if (req.method !== 'POST' || req.url !== '/board') { res.writeHead(404).end(); return; }
      const chunks = []; let size = 0;
      for await (const chunk of req) {
        size += chunk.length;
        if (size > 4096) { res.writeHead(413).end(); return; }
        chunks.push(chunk);
      }
      const fields = new URLSearchParams(Buffer.concat(chunks).toString());
      const token = fields.get('token');
      if (!/^[\da-f-]{36}$/.test(token || '')) { res.writeHead(400).end(); return; }
      const action = JSON.parse(fields.get('action'));
      if (action.type !== 'init' && !sessions.has(token)) { res.writeHead(404).end(); return; }
      const board = action.type === 'init' ? createBoard() : applyBoardAction(sessions.get(token), action);
      const snapshot = boardSnapshot(board);
      if (String(snapshot.revision) !== fields.get('revision')) { res.writeHead(409).end(); return; }
      if (sessions.size > 128) sessions.delete(sessions.keys().next().value);
      sessions.set(token,board);
      const html = Buffer.from(renderDashboardHTML(snapshot));
      const gzip = /\bgzip\b/.test(req.headers['accept-encoding'] || '');
      res.writeHead(200, {'Content-Type':'text/html; charset=utf-8','Cache-Control':'no-store',
        ...(gzip ? {'Content-Encoding':'gzip'} : {})});
      res.end(gzip ? gzipSync(html) : html);
    } catch (error) { console.error(error); if (!res.headersSent) res.writeHead(500); res.end(); }
  });
  await new Promise((resolve,reject) => { server.once('error',reject); server.listen(0,'127.0.0.1',resolve); });
  return {origin:'http://127.0.0.1:'+server.address().port,manifest,
    close:()=>new Promise(resolve=>{server.close(resolve);server.closeAllConnections();})};
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const {origin} = await startServer();
  for (const mode of modes) console.log(origin+'/'+mode);
}
