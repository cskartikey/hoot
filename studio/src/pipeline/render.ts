// Run Manim on a scene file via manim/runner.py (plain tracebacks, 720p30, no cache), with a timeout.
import { spawn } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { MANIM_DIR } from '../env.js';

const PYTHON = join(MANIM_DIR, '.venv', 'bin', 'python');
const RUNNER = join(MANIM_DIR, 'runner.py');

export interface RenderResult {
  ok: boolean;
  video?: string;
  marks?: number[]; // scene time at each wait_until (actual beat ends)
  error?: string;
  seconds: number;
}

export async function renderScene(
  sceneFile: string,
  mediaDir: string,
  opts: { timeoutMs?: number; extraEnv?: Record<string, string> } = {},
): Promise<RenderResult> {
  const t0 = Date.now();
  await mkdir(mediaDir, { recursive: true });
  const marksPath = join(mediaDir, 'marks.json');
  await writeFile(marksPath, '[]');
  return new Promise((resolve) => {
    const child = spawn(PYTHON, [RUNNER, sceneFile, mediaDir], {
      cwd: mediaDir,
      env: {
        ...process.env,
        // MacTeX lives outside the PATH of a server started from an app or a plain shell; the kit
        // also adds it, but the renderer puts it first so `latex`/`dvisvgm` are found either way.
        PATH: ['/Library/TeX/texbin', process.env.PATH ?? ''].filter(Boolean).join(':'),
        PYTHONPATH: MANIM_DIR,
        PYTHONWARNINGS: 'ignore',
        PYTHONDONTWRITEBYTECODE: '1',
        STUDIO_MARKS: marksPath,
        ...opts.extraEnv,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let out = '';
    let err = '';
    child.stdout.on('data', (d) => (out += d));
    child.stderr.on('data', (d) => (err += d));
    const timer = setTimeout(() => {
      err += `\nTimeoutError: render took longer than ${(opts.timeoutMs ?? 90_000) / 1000}s (scene too long or an infinite loop/updater)`;
      child.kill('SIGKILL');
    }, opts.timeoutMs ?? 90_000);
    child.on('close', (code) => {
      clearTimeout(timer);
      const seconds = (Date.now() - t0) / 1000;
      const m = out.match(/RENDERED (.+\.mp4)/);
      if (code === 0 && m && existsSync(m[1].trim())) {
        let marks: number[] = [];
        try {
          marks = JSON.parse(readFileSync(marksPath, 'utf8'));
        } catch {}
        resolve({ ok: true, video: m[1].trim(), marks, seconds });
      } else {
        resolve({ ok: false, error: trimTraceback(err || `manim exited with code ${code}`, sceneFile), seconds });
      }
    });
  });
}

/** Keep the parts of the traceback that matter to the model: frames in the scene file and the last lines. */
export function trimTraceback(tb: string, sceneFile: string): string {
  const lines = tb.split('\n').filter((l) => !/^\s*\^+\s*$/.test(l));
  const keep: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].includes(sceneFile) || lines[i].includes('scene.py"')) {
      keep.push(lines[i].replace(/File ".*\/([^/]+)"/, 'File "$1"'), lines[i + 1] ?? '');
    }
  }
  const tail = lines.slice(-12).map((l) => l.replace(/File ".*\/site-packages\//, 'File "'));
  return [...keep, '...', ...tail].join('\n').slice(-3500);
}

/** Render a trivial scene so the OS has Python, Manim, Cairo and the fonts warm. */
export async function prewarm(dir: string): Promise<RenderResult> {
  await mkdir(dir, { recursive: true });
  const file = join(dir, 'warm.py');
  await writeFile(
    file,
    'from manim import *\nfrom kit import *\n\nclass Explainer(Scene):\n    def construct(self):\n' +
      '        t = title_card("warm", "up")\n        self.play(FadeIn(t), run_time=0.3)\n        wait_until(self, 0.5)\n',
  );
  return renderScene(file, join(dir, 'media'), { timeoutMs: 120_000 });
}
