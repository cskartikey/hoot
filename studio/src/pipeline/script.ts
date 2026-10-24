// LLM → title + 3-6 beats of narration and visuals.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { PROMPTS_DIR } from '../env.js';
import { complete, extractJSON } from '../llm.js';
import type { ExplainRequest, Script, TemplateName } from './types.js';

const TEMPLATES: TemplateName[] = ['transform', 'derivation', 'process', 'compare'];

export function describeRequest(req: ExplainRequest): string {
  const parts = [`Learner's question: ${req.question}`];
  if (req.brief) parts.push(`What the tutor wants the animation to show: ${req.brief}`);
  if (req.spokenAnswer) parts.push(`What the tutor already said out loud: ${req.spokenAnswer}`);
  const yt = req.context?.youtube;
  if (yt?.title) parts.push(`They were watching: "${yt.title}"${yt.t != null ? ` at ${Math.round(yt.t)}s` : ''}`);
  if (yt?.transcriptWindow) parts.push(`Recent transcript:\n${yt.transcriptWindow.slice(-2500)}`);
  if (req.context?.screenText) parts.push(`Text on their screen:\n${req.context.screenText.slice(0, 2000)}`);
  if (req.context?.app) parts.push(`App in front: ${req.context.app}`);
  if (req.memory?.length)
    parts.push(
      'Things this learner was confused about before (mention only if genuinely related):\n' +
        req.memory.map((m) => `- ${m.concept}: ${m.summary}`).join('\n'),
    );
  return parts.join('\n\n');
}

export async function writeScript(req: ExplainRequest): Promise<Script> {
  const system = readFileSync(join(PROMPTS_DIR, 'script.md'), 'utf8');
  const text = await complete({
    label: 'script',
    system,
    user: describeRequest(req),
    maxTokens: 2000,
    effort: 'low',
    json: true,
    timeoutMs: 60_000,
  });
  const raw = extractJSON<{ title?: string; template?: string; beats?: unknown[] }>(text);
  const beats = (raw.beats ?? [])
    .map((b, i) => {
      const o = (b ?? {}) as Record<string, unknown>;
      return { id: i + 1, narration: String(o.narration ?? '').trim(), visual: String(o.visual ?? '').trim() };
    })
    .filter((b) => b.narration)
    .slice(0, 6);
  if (beats.length < 2) throw new Error('script had fewer than 2 beats');
  const template = TEMPLATES.includes(raw.template as TemplateName) ? (raw.template as TemplateName) : 'process';
  return { title: String(raw.title ?? req.question).slice(0, 60), template, beats };
}
