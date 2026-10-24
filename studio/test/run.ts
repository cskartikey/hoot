// Run the test questions through a running studio server and report render outcomes and wall time.
// usage: pnpm test:questions [--parallel] [--only name1,name2] [--server http://localhost:7777]
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const args = process.argv.slice(2);
const flag = (n: string) => args.includes(n);
const opt = (n: string) => (args.includes(n) ? args[args.indexOf(n) + 1] : undefined);
const SERVER = opt('--server') ?? 'http://localhost:7777';
const only = opt('--only')?.split(',');

const here = dirname(fileURLToPath(import.meta.url));
const all = JSON.parse(readFileSync(join(here, 'questions.json'), 'utf8')) as ({ name: string } & Record<string, unknown>)[];
const questions = only ? all.filter((q) => only.includes(q.name)) : all;

interface Row {
  name: string;
  outcome: string;
  seconds: number;
  duration?: number;
  attempts?: number;
  timings?: Record<string, number>;
  errors?: string[];
  url?: string;
}

async function runOne(q: { name: string } & Record<string, unknown>): Promise<Row> {
  const t0 = Date.now();
  const { name, ...body } = q;
  const r = await fetch(`${SERVER}/explain`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
  const { jobId } = (await r.json()) as { jobId: string };
  const res = await fetch(`${SERVER}/jobs/${jobId}/events`);
  const reader = res.body!.getReader();
  const dec = new TextDecoder();
  let buf = '';
  let final: { event: string; data: Record<string, unknown> } | null = null;
  while (!final) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    let i;
    while ((i = buf.indexOf('\n\n')) >= 0) {
      const chunk = buf.slice(0, i);
      buf = buf.slice(i + 2);
      const ev = chunk.match(/^event: (.+)$/m)?.[1];
      const data = chunk.match(/^data: (.+)$/m)?.[1];
      if (!ev || !data) continue;
      const d = JSON.parse(data);
      const s = ((Date.now() - t0) / 1000).toFixed(1);
      if (ev === 'stage') console.log(`  [${name} ${s}s] ${d.stage}: ${d.label}${d.attempt ? ` (#${d.attempt})` : ''}`);
      if (ev === 'script') console.log(`  [${name} ${s}s] script: ${d.beats.length} beats "${d.title}"`);
      if (ev === 'done' || ev === 'error') final = { event: ev, data: d };
    }
  }
  const seconds = (Date.now() - t0) / 1000;
  const info = (await (await fetch(`${SERVER}/jobs/${jobId}`)).json()) as Row & { outcome?: string };
  if (!final || final.event === 'error') {
    return { name, outcome: 'error', seconds, errors: [String(final?.data.message ?? 'stream ended')], timings: info.timings };
  }
  return {
    name,
    outcome: info.outcome ?? '?',
    seconds,
    duration: final.data.duration as number,
    attempts: info.attempts,
    timings: info.timings,
    errors: info.errors,
    url: final.data.url as string,
  };
}

const rows: Row[] = flag('--parallel')
  ? await Promise.all(questions.map(runOne))
  : await (async () => {
      const out: Row[] = [];
      for (const q of questions) out.push(await runOne(q));
      return out;
    })();

console.log('\nname          outcome    wall    video  timings');
for (const r of rows) {
  const t = r.timings ? Object.entries(r.timings).map(([k, v]) => `${k}=${v}`).join(' ') : '';
  console.log(`${r.name.padEnd(13)} ${r.outcome.padEnd(10)} ${r.seconds.toFixed(1).padStart(5)}s ${String(r.duration ?? '-').padStart(6)}s  ${t}`);
  for (const e of r.errors ?? []) console.log(`${''.padEnd(14)}! ${e.slice(0, 160)}`);
}
const count = (o: string) => rows.filter((r) => r.outcome === o).length;
console.log(`\nfirst try ${count('first')}/${rows.length}, after fix ${count('fixed')}, fallback ${count('fallback')}, error ${count('error')}`);
console.log(`mean wall ${(rows.reduce((n, r) => n + r.seconds, 0) / rows.length).toFixed(1)}s, max ${Math.max(...rows.map((r) => r.seconds)).toFixed(1)}s`);
for (const r of rows) if (r.url) console.log(`${r.name}: ${r.url}`);
