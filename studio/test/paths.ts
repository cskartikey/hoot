// Exercise the repair and fallback paths on a finished job's files without the server.
// usage: tsx test/paths.ts <jobId>
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { MANIM_DIR, OUT_DIR } from '../src/env.js';
import { mux } from '../src/pipeline/mux.js';
import { renderScene } from '../src/pipeline/render.js';
import { fixScene } from '../src/pipeline/scene.js';

const id = process.argv[2];
const dir = join(OUT_DIR, id);
const beats = JSON.parse(await readFile(join(dir, 'beats.json'), 'utf8')).beats;

// 1. Break a good scene the way models often do, then ask for a fix.
const good = await readFile(join(dir, 'scene_1.py'), 'utf8');
const broken = good.replace(/def construct\(self\):\n/, 'def construct(self):\n        lbl = MathTex(r"\\det(A)=0").next_to(ORIGIN, UP, buf=0.3)\n        self.play(Write(lbl, run_time=1)\n');
await writeFile(join(dir, 'broken.py'), broken);
const r1 = await renderScene(join(dir, 'broken.py'), join(dir, 'media_broken'));
console.log('broken renders?', r1.ok, '\n', r1.error?.split('\n').slice(-4).join('\n'));
const fixed = await fixScene(broken, r1.error ?? '');
await writeFile(join(dir, 'fixed.py'), fixed);
const r2 = await renderScene(join(dir, 'fixed.py'), join(dir, 'media_fixed'));
console.log('fixed renders?', r2.ok, r2.seconds.toFixed(1) + 's', r2.error?.split('\n').slice(-2).join('\n') ?? '');

// 2. Fallback + mux.
const t = Date.now();
const fb = await renderScene(join(MANIM_DIR, 'fallback.py'), join(dir, 'fallback_test'), { extraEnv: { STUDIO_BEATS: join(dir, 'beats.json') } });
console.log('fallback ok?', fb.ok, ((Date.now() - t) / 1000).toFixed(1) + 's', 'marks', fb.marks);
const m = await mux(fb.video!, beats, fb.marks, join(dir, 'fallback_test.mp4'));
console.log('fallback mux', m.duration, 's,', m.captions.length, 'captions');
