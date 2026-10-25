// script → voice → scene code → render (fix ×2) → fallback → mux. Emits SSE events as it goes.
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { MANIM_DIR, OUT_DIR, env } from '../env.js';
import { emit, type Job } from '../jobs.js';
import { mux } from './mux.js';
import { renderScene, type RenderResult } from './render.js';
import { fixScene, writeScene } from './scene.js';
import { writeScript } from './script.js';
import type { ExplainRequest, Script } from './types.js';
import { resolveTTSProvider, voiceBeats } from './voice.js';

const MAX_FIXES = 2;
const RENDER_TIMEOUT_MS = 90_000;
const GIVE_UP_AFTER_MS = 150_000; // past this, stop retrying and use the fallback

export async function runJob(job: Job, req: ExplainRequest): Promise<void> {
  const t0 = Date.now();
  const mark = (k: string, since: number) => (job.timings[k] = round((Date.now() - since) / 1000));
  const dir = join(OUT_DIR, job.id);
  await mkdir(dir, { recursive: true });
  await writeFile(join(dir, 'request.json'), JSON.stringify(req, null, 2));

  try {
    // 1. Script
    emit(job, 'stage', { stage: 'script', label: 'Writing the explanation' });
    let t = Date.now();
    let script: Script;
    try {
      script = await writeScript(req);
    } catch (e) {
      job.errors.push(`script: ${msg(e)}`);
      script = await writeScript(req);
    }
    mark('script', t);
    await writeFile(join(dir, 'script.json'), JSON.stringify(script, null, 2));
    emit(job, 'script', { title: script.title, beats: script.beats });

    // 2. Voice
    emit(job, 'stage', { stage: 'voice', label: 'Recording narration' });
    t = Date.now();
    const ttsProvider = resolveTTSProvider(req.ttsProvider);
    job.ttsProvider = ttsProvider;
    const beats = await voiceBeats(script.beats, dir, ttsProvider);
    mark('voice', t);
    await writeFile(
      join(dir, 'beats.json'),
      JSON.stringify({ title: script.title, beats: beats.map((b) => ({ ...b, end: b.end })) }, null, 2),
    );

    // Fallback renders in the background right away, so it's ready if everything else fails.
    const fallback = renderScene(join(MANIM_DIR, 'fallback.py'), join(dir, 'fallback'), {
      timeoutMs: RENDER_TIMEOUT_MS,
      extraEnv: { STUDIO_BEATS: join(dir, 'beats.json') },
    });

    // 3. Scene code + render, with up to MAX_FIXES repair rounds
    emit(job, 'stage', { stage: 'render', label: 'Animating', attempt: 1 });
    t = Date.now();
    let result: RenderResult | null = null;
    let code: string | null = null;
    let attempt = 1;
    try {
      code = await writeScene(req.question, req.brief, script, beats);
      mark('sceneLLM', t);
    } catch (e) {
      job.errors.push(`scene: ${msg(e)}`);
    }
    while (code) {
      const file = join(dir, `scene_${attempt}.py`);
      await writeFile(file, code);
      const r = await renderScene(file, join(dir, `media_${attempt}`), { timeoutMs: RENDER_TIMEOUT_MS });
      job.timings[`render${attempt}`] = round(r.seconds);
      if (r.ok) {
        result = r;
        break;
      }
      job.errors.push(`render ${attempt}: ${r.error?.split('\n').filter(Boolean).slice(-1)[0] ?? 'failed'}`);
      await writeFile(join(dir, `error_${attempt}.txt`), r.error ?? '');
      if (attempt > MAX_FIXES || Date.now() - t0 > GIVE_UP_AFTER_MS) break;
      attempt++;
      emit(job, 'stage', { stage: 'render', label: 'Fixing animation', attempt });
      try {
        const tf = Date.now();
        code = await fixScene(code, r.error ?? '');
        mark(`fixLLM${attempt}`, tf);
      } catch (e) {
        job.errors.push(`fix: ${msg(e)}`);
        code = null;
      }
    }
    job.attempts = attempt;
    let usedFallback = false;
    if (!result) {
      usedFallback = true;
      result = await fallback;
      if (!result.ok) throw new Error(`fallback render failed: ${result.error}`);
    } else {
      fallback.catch(() => {}); // let it finish quietly
    }
    job.outcome = usedFallback ? 'fallback' : attempt === 1 ? 'first' : 'fixed';
    mark('renderTotal', t);

    // 4. Mux
    t = Date.now();
    const videoPath = join(dir, 'video.mp4');
    const { duration, captions } = await mux(result.video!, beats, result.marks, videoPath);
    mark('mux', t);
    job.videoPath = videoPath;
    job.timings.total = round((Date.now() - t0) / 1000);
    await writeFile(join(dir, 'job.json'), JSON.stringify({ outcome: job.outcome, attempts: job.attempts, ttsProvider: job.ttsProvider, timings: job.timings, errors: job.errors }, null, 2));
    console.log(`[job ${job.id}] done in ${job.timings.total}s (${job.outcome}, ${duration}s video)`);
    emit(job, 'done', {
      url: `${env.publicBase}/jobs/${job.id}/video.mp4`,
      duration,
      captions,
      fallback: usedFallback,
    });
  } catch (e) {
    job.errors.push(msg(e));
    job.timings.total = round((Date.now() - t0) / 1000);
    console.error(`[job ${job.id}] failed:`, msg(e));
    emit(job, 'error', { message: msg(e) });
  }
}

const msg = (e: unknown) => (e instanceof Error ? e.message : String(e));
const round = (x: number) => Math.round(x * 10) / 10;
