// LLM → one Manim file (class Explainer) that uses the kit and hits each beat's end time.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { MANIM_DIR, PROMPTS_DIR } from '../env.js';
import { complete, extractPython } from '../llm.js';
import type { Script, VoicedBeat } from './types.js';

const read = (p: string) => readFileSync(p, 'utf8');

export function sceneSystemPrompt(template: string): string {
  return read(join(PROMPTS_DIR, 'scene.md'))
    .replace('{{KIT_API}}', read(join(MANIM_DIR, 'KIT_API.md')))
    .replace('{{TEMPLATE}}', read(join(MANIM_DIR, 'templates', `${template}.py`)).trim());
}

export function beatTable(beats: VoicedBeat[]): string {
  return beats
    .map(
      (b, i) =>
        `Beat ${i + 1}: ${b.start.toFixed(2)}s → ${b.end.toFixed(2)}s (${(b.end - b.start).toFixed(2)}s)\n` +
        `  narration: ${b.narration}\n  visual: ${b.visual}`,
    )
    .join('\n');
}

export async function writeScene(question: string, brief: string | undefined, script: Script, beats: VoicedBeat[]) {
  const T = beats.map((b) => b.end.toFixed(2));
  const user = [
    `Question: ${question}`,
    brief ? `Brief: ${brief}` : '',
    `Title: ${script.title}`,
    `Beats (times are cumulative seconds from the start of the video):\n${beatTable(beats)}`,
    `Use exactly: T = [${T.join(', ')}]`,
    `Total length: ${beats[beats.length - 1].end.toFixed(2)}s.`,
  ]
    .filter(Boolean)
    .join('\n\n');
  const text = await complete({
    label: 'scene',
    system: sceneSystemPrompt(script.template),
    user,
    maxTokens: 6000,
    effort: 'low',
    timeoutMs: 120_000,
  });
  return ensureTimes(extractPython(text), T);
}

export async function fixScene(code: string, error: string): Promise<string> {
  const user = read(join(PROMPTS_DIR, 'fix.md')).replace('{{ERROR}}', error).replace('{{CODE}}', code);
  const text = await complete({
    label: 'fix',
    system: 'You fix Manim Community Edition scenes so they render. LaTeX is installed (tex strings must be raw, balanced, standard amsmath, no Unicode inside). Reply with code only.\n\n' +
      read(join(MANIM_DIR, 'KIT_API.md')),
    user,
    maxTokens: 6000,
    effort: 'low',
    timeoutMs: 120_000,
  });
  return extractPython(text);
}

/** Make sure the imports and the T list are exactly what we planned, whatever the model wrote. */
function ensureTimes(code: string, T: string[]): string {
  let c = code;
  if (!/from kit import \*/.test(c)) c = c.replace(/(from manim import \*\s*\n)/, '$1from kit import *\n');
  if (!/from manim import \*/.test(c)) c = 'from manim import *\nfrom kit import *\n' + c;
  const line = `T = [${T.join(', ')}]`;
  if (/^T\s*=\s*\[[^\]]*\]/m.test(c)) c = c.replace(/^T\s*=\s*\[[^\]]*\]/m, line);
  else c = c.replace(/(from kit import \*\s*\n)/, `$1\n${line}\n`);
  return c;
}
