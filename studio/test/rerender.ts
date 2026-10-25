// Re-render a finished job's last scene with the current kit (e.g. after a kit fix) and mux it
// with the job's existing narration, without touching the original video.mp4.
// usage: tsx test/rerender.ts <jobId>   → out/<jobId>/video-rerendered.mp4
import { readFile, readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { OUT_DIR } from '../src/env.js';
import { mux } from '../src/pipeline/mux.js';
import { renderScene } from '../src/pipeline/render.js';

const jobId = process.argv[2];
if (!jobId) throw new Error('usage: tsx test/rerender.ts <jobId>');
const dir = join(OUT_DIR, jobId);
const beats = JSON.parse(await readFile(join(dir, 'beats.json'), 'utf8')).beats;
const sceneFiles = (await readdir(dir)).filter((f) => /^scene_\d+\.py$/.test(f)).sort();
const lastScene = sceneFiles[sceneFiles.length - 1];
if (!lastScene) throw new Error(`no scene_N.py in ${dir}`);

const t = Date.now();
const r = await renderScene(join(dir, lastScene), join(dir, 'media_rerender'), { timeoutMs: 180_000 });
console.log(`render ${lastScene}: ok=${r.ok} ${((Date.now() - t) / 1000).toFixed(1)}s`, r.ok ? '' : r.error?.split('\n').slice(-4).join('\n'));
if (!r.ok) process.exit(1);
const m = await mux(r.video!, beats, r.marks, join(dir, 'video-rerendered.mp4'));
console.log(`muxed ${m.duration}s, ${m.captions.length} captions → ${join(dir, 'video-rerendered.mp4')}`);
