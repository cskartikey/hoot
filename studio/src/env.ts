// Loads keys without ever printing them. Precedence: process.env > studio/.env > worker/.dev.vars.
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const STUDIO = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const MANIM_DIR = join(STUDIO, 'manim');
export const OUT_DIR = join(STUDIO, 'out');
export const PROMPTS_DIR = join(STUDIO, 'src', 'prompts');

function parse(path: string): Record<string, string> {
  if (!existsSync(path)) return {};
  const vars: Record<string, string> = {};
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const m = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/);
    if (!m) continue;
    let v = m[2];
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
    vars[m[1]] = v;
  }
  return vars;
}

const files = [join(STUDIO, '.env'), join(STUDIO, '..', 'worker', '.dev.vars')];
for (const f of files) {
  for (const [k, v] of Object.entries(parse(f))) {
    if (process.env[k] === undefined || process.env[k] === '') process.env[k] = v;
  }
}

export const env = {
  port: Number(process.env.STUDIO_PORT || 7777),
  host: process.env.STUDIO_HOST || '127.0.0.1',
  publicBase: process.env.STUDIO_PUBLIC_URL || `http://localhost:${process.env.STUDIO_PORT || 7777}`,
  brain: (process.env.STUDIO_BRAIN || process.env.BRAIN || 'openai').toLowerCase() as 'openai' | 'anthropic',
  openaiKey: process.env.OPENAI_API_KEY || '',
  openaiModel: process.env.OPENAI_MODEL || 'gpt-6.1-sol',
  anthropicKey: process.env.ANTHROPIC_API_KEY || '',
  anthropicModel: process.env.ANTHROPIC_MODEL || 'claude-opus-5-5',
  cartesiaKey: process.env.CARTESIA_API_KEY || '',
  cartesiaVoice: process.env.CARTESIA_VOICE_ID || 'db6b0ed5-d5d3-463d-ae85-518a07d3c2b4',
  mossProjectId: process.env.MOSS_PROJECT_ID || '',
  mossProjectKey: process.env.MOSS_PROJECT_KEY || '',
  mossMemoryIndex: process.env.MOSS_MEMORY_INDEX || 'hoot-memory',
};

/** Which keys are present (never the values). */
export function keyStatus() {
  return {
    brain: env.brain,
    model: env.brain === 'anthropic' ? env.anthropicModel : env.openaiModel,
    openai: Boolean(env.openaiKey),
    anthropic: Boolean(env.anthropicKey),
    cartesia: Boolean(env.cartesiaKey),
    moss: Boolean(env.mossProjectId && env.mossProjectKey),
  };
}
