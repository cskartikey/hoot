// studio HTTP server: POST /explain, GET /jobs/:id/events (SSE), GET /jobs/:id/video.mp4, GET /health,
// and hoot's memory search on Moss: GET /memory/health, POST /memory/{upsert,query,reset}.
import { createReadStream, statSync } from 'node:fs';
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { join } from 'node:path';
import { OUT_DIR, env, keyStatus } from './env.js';
import { DEFAULT_ALPHA, MossMemoryIndex, type MemoryDocument } from './memory/moss.js';
import { createJob, getJob, jobCount, summary, type JobEvent } from './jobs.js';
import { runJob } from './pipeline/index.js';
import { prewarm } from './pipeline/render.js';
import type { ExplainRequest } from './pipeline/types.js';

let warm: 'pending' | 'ready' | 'failed' = 'pending';
const memoryIndex = new MossMemoryIndex(env.mossProjectId, env.mossProjectKey, env.mossMemoryIndex);

function json(res: ServerResponse, status: number, body: unknown) {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
}

async function readBody(req: IncomingMessage, limit = 2 * 1024 * 1024): Promise<string> {
  let size = 0;
  const chunks: Buffer[] = [];
  for await (const c of req) {
    size += c.length;
    if (size > limit) throw new Error('body too large');
    chunks.push(c as Buffer);
  }
  return Buffer.concat(chunks).toString('utf8');
}

async function explain(req: IncomingMessage, res: ServerResponse) {
  let body: ExplainRequest;
  try {
    body = JSON.parse(await readBody(req));
  } catch {
    return json(res, 400, { error: 'invalid JSON body' });
  }
  if (!body || typeof body.question !== 'string' || !body.question.trim()) {
    return json(res, 400, { error: '"question" (string) is required' });
  }
  const job = createJob();
  console.log(`[job ${job.id}] ${body.question.slice(0, 100)}`);
  void runJob(job, body);
  json(res, 200, { jobId: job.id });
}

async function readJson(req: IncomingMessage): Promise<any> {
  try {
    return JSON.parse((await readBody(req)) || '{}');
  } catch {
    return null;
  }
}

function memoryDocument(raw: any): MemoryDocument | null {
  if (!raw || typeof raw.id !== 'string' || !raw.id || typeof raw.text !== 'string' || !raw.text.trim()) return null;
  const metadata: Record<string, string> = {};
  for (const [k, v] of Object.entries(raw.metadata ?? {})) if (v !== undefined && v !== null) metadata[k] = String(v);
  return { id: raw.id, text: raw.text.trim().slice(0, 4000), metadata };
}

/** Memory routes. Without Moss credentials each answers { enabled: false } right away. */
async function memoryRoute(req: IncomingMessage, res: ServerResponse, p: string) {
  if (req.method === 'GET' && p === '/memory/health') return json(res, 200, await memoryIndex.health());
  if (req.method !== 'POST') return json(res, 404, { error: 'not found' });
  if (!memoryIndex.enabled) return json(res, 200, { enabled: false, results: [] });
  const body = await readJson(req);
  if (body === null) return json(res, 400, { error: 'invalid JSON body' });
  if (p === '/memory/upsert') {
    // One memory ({id, text, metadata}) or a batch ({documents: [...]}) for the backfill.
    const rawDocs = Array.isArray(body.documents) ? body.documents : [body];
    const documents = rawDocs.map(memoryDocument).filter((d: MemoryDocument | null): d is MemoryDocument => d !== null);
    if (!documents.length) return json(res, 400, { error: '"id" and "text" (strings) are required' });
    return json(res, 200, await memoryIndex.upsert(documents));
  }
  if (p === '/memory/query') {
    const texts: string[] = (Array.isArray(body.texts) ? body.texts : [body.text])
      .filter((t: unknown): t is string => typeof t === 'string' && t.trim().length > 0)
      .map((t: string) => t.trim().slice(0, 1000))
      .slice(0, 6);
    if (!texts.length) return json(res, 400, { error: '"text" (string) or "texts" (string[]) is required' });
    const topK = Math.min(Math.max(Number(body.topK) || 5, 1), 20);
    const alpha = typeof body.alpha === 'number' && body.alpha >= 0 && body.alpha <= 1 ? body.alpha : DEFAULT_ALPHA;
    return json(res, 200, await memoryIndex.query(texts, topK, alpha));
  }
  if (p === '/memory/reset') return json(res, 200, await memoryIndex.reset());
  json(res, 404, { error: 'not found' });
}

function events(res: ServerResponse, id: string) {
  const job = getJob(id);
  if (!job) return json(res, 404, { error: 'no such job' });
  res.writeHead(200, {
    'content-type': 'text/event-stream',
    'cache-control': 'no-cache',
    connection: 'keep-alive',
    'x-accel-buffering': 'no',
  });
  res.flushHeaders();
  const send = (e: JobEvent) => res.write(`event: ${e.event}\ndata: ${JSON.stringify(e.data)}\n\n`);
  for (const e of job.events) send(e);
  if (job.status !== 'running') return res.end();
  const ping = setInterval(() => res.write(': ping\n\n'), 15_000);
  const listener = (e: JobEvent) => {
    send(e);
    if (e.event === 'done' || e.event === 'error') cleanup(true);
  };
  const cleanup = (end: boolean) => {
    clearInterval(ping);
    job.listeners.delete(listener);
    if (end) res.end();
  };
  job.listeners.add(listener);
  res.on('close', () => cleanup(false));
}

function video(req: IncomingMessage, res: ServerResponse, id: string) {
  const job = getJob(id);
  // Also serve finished videos from disk after a restart.
  const path = job?.videoPath ?? join(OUT_DIR, id.replace(/[^a-z0-9]/gi, ''), 'video.mp4');
  let size: number;
  try {
    size = statSync(path).size;
  } catch {
    return json(res, job ? 409 : 404, { error: job ? 'video not ready' : 'no such job' });
  }
  const range = req.headers.range?.match(/bytes=(\d*)-(\d*)/);
  const common = { 'content-type': 'video/mp4', 'accept-ranges': 'bytes', 'cache-control': 'no-cache' };
  if (range) {
    let start = range[1] ? parseInt(range[1], 10) : 0;
    let end = range[2] ? parseInt(range[2], 10) : size - 1;
    if (!range[1] && range[2]) {
      start = Math.max(0, size - parseInt(range[2], 10));
      end = size - 1;
    }
    if (start >= size || end < start) {
      res.writeHead(416, { 'content-range': `bytes */${size}` });
      return res.end();
    }
    end = Math.min(end, size - 1);
    res.writeHead(206, { ...common, 'content-range': `bytes ${start}-${end}/${size}`, 'content-length': end - start + 1 });
    if (req.method === 'HEAD') return res.end();
    return createReadStream(path, { start, end }).pipe(res);
  }
  res.writeHead(200, { ...common, 'content-length': size });
  if (req.method === 'HEAD') return res.end();
  createReadStream(path).pipe(res);
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? '/', 'http://localhost');
  const p = url.pathname;
  try {
    if (req.method === 'GET' && p === '/health') return json(res, 200, { ok: true, warm, jobs: jobCount(), ...keyStatus() });
    if (req.method === 'POST' && p === '/explain') return await explain(req, res);
    if (p.startsWith('/memory/')) return await memoryRoute(req, res, p);
    let m = p.match(/^\/jobs\/([A-Za-z0-9]+)\/events$/);
    if (req.method === 'GET' && m) return events(res, m[1]);
    m = p.match(/^\/jobs\/([A-Za-z0-9]+)\/video\.mp4$/);
    if ((req.method === 'GET' || req.method === 'HEAD') && m) return video(req, res, m[1]);
    m = p.match(/^\/jobs\/([A-Za-z0-9]+)$/);
    if (req.method === 'GET' && m) {
      const job = getJob(m[1]);
      return job ? json(res, 200, summary(job)) : json(res, 404, { error: 'no such job' });
    }
    json(res, 404, { error: 'not found' });
  } catch (e) {
    console.error(e);
    if (!res.headersSent) json(res, 500, { error: e instanceof Error ? e.message : String(e) });
  }
});

server.listen(env.port, env.host, () => {
  const k = keyStatus();
  console.log(`studio on http://localhost:${env.port}  brain=${k.brain} (${k.model})  keys: openai=${k.openai} anthropic=${k.anthropic} cartesia=${k.cartesia} moss=${k.moss}`);
  memoryIndex.start();
  const t = Date.now();
  prewarm(join(OUT_DIR, '_warm'))
    .then((r) => {
      warm = r.ok ? 'ready' : 'failed';
      console.log(`[warm] manim ${warm} in ${((Date.now() - t) / 1000).toFixed(1)}s${r.ok ? '' : `: ${r.error}`}`);
    })
    .catch(() => (warm = 'failed'));
});

// Push unsaved memories to Moss before exiting (pkill sends SIGTERM). Capped so a stuck push can't hang shutdown.
let shuttingDown = false;
for (const signal of ['SIGTERM', 'SIGINT'] as const) {
  process.on(signal, () => {
    if (shuttingDown) process.exit(0);
    shuttingDown = true;
    setTimeout(() => process.exit(0), 8000).unref();
    memoryIndex.close().finally(() => process.exit(0));
  });
}
