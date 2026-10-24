// One text-in/text-out call, switchable by BRAIN: OpenAI Chat Completions (stopgap) or Anthropic Messages.
import Anthropic from '@anthropic-ai/sdk';
import { env } from './env.js';

export type Effort = 'low' | 'medium' | 'high';

export interface LLMRequest {
  system: string;
  user: string;
  maxTokens?: number;
  effort?: Effort;
  json?: boolean; // ask for a JSON object (OpenAI response_format; prompt-enforced on Anthropic)
  timeoutMs?: number;
  label?: string;
}

let anthropic: Anthropic | null = null;

export async function complete(req: LLMRequest): Promise<string> {
  const t0 = Date.now();
  const out = env.brain === 'anthropic' ? await viaAnthropic(req) : await viaOpenAI(req);
  console.log(`[llm] ${req.label ?? 'call'} ${env.brain} ${((Date.now() - t0) / 1000).toFixed(1)}s, ${out.length} chars`);
  return out;
}

async function viaOpenAI(req: LLMRequest): Promise<string> {
  if (!env.openaiKey) throw new Error('OPENAI_API_KEY is not set');
  const res = await fetch('https://api.openai.com/v1/chat/completions', {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${env.openaiKey}` },
    signal: AbortSignal.timeout(req.timeoutMs ?? 120_000),
    body: JSON.stringify({
      model: env.openaiModel,
      messages: [
        { role: 'system', content: req.system },
        { role: 'user', content: req.user },
      ],
      // Reasoning tokens count against this limit, so leave headroom.
      max_completion_tokens: (req.maxTokens ?? 8000) + 8000,
      reasoning_effort: req.effort ?? 'low',
      ...(req.json ? { response_format: { type: 'json_object' } } : {}),
    }),
  });
  if (!res.ok) throw new Error(`OpenAI ${res.status}: ${(await res.text()).slice(0, 500)}`);
  const data = (await res.json()) as { choices?: { message?: { content?: string }; finish_reason?: string }[] };
  const text = data.choices?.[0]?.message?.content ?? '';
  if (!text) throw new Error(`OpenAI returned no text (finish_reason=${data.choices?.[0]?.finish_reason})`);
  return text;
}

async function viaAnthropic(req: LLMRequest): Promise<string> {
  if (!env.anthropicKey) throw new Error('ANTHROPIC_API_KEY is not set');
  anthropic ??= new Anthropic({ apiKey: env.anthropicKey, maxRetries: 1 });
  const params = {
    model: env.anthropicModel,
    max_tokens: Math.max(req.maxTokens ?? 8000, 16000),
    betas: ['server-side-fallback-2026-07-01'],
    fallbacks: 'default',
    thinking: { type: 'adaptive' },
    output_config: { effort: req.effort ?? 'medium' },
    system: req.system + (req.json ? '\n\nRespond with a single JSON object and nothing else.' : ''),
    messages: [{ role: 'user', content: req.user }],
  };
  // Cast: fallbacks/output_config may be newer than the installed SDK's types.
  const msg = (await anthropic.beta.messages.create(params as never, { timeout: req.timeoutMs ?? 180_000 })) as unknown as {
    stop_reason: string;
    content: { type: string; text?: string }[];
  };
  if (msg.stop_reason === 'refusal') throw new Error('Claude declined this request');
  const text = msg.content.filter((b) => b.type === 'text').map((b) => b.text ?? '').join('');
  if (!text) throw new Error(`Claude returned no text (stop_reason=${msg.stop_reason})`);
  return text;
}

/** Pull a JSON object out of a reply that may be fenced or have stray prose. */
export function extractJSON<T>(text: string): T {
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/);
  const raw = fenced ? fenced[1] : text;
  const start = raw.indexOf('{');
  const end = raw.lastIndexOf('}');
  if (start < 0 || end < start) throw new Error('no JSON object in reply');
  return JSON.parse(raw.slice(start, end + 1)) as T;
}

/** Pull Python code out of a reply (```python fences, or the whole reply). */
export function extractPython(text: string): string {
  const blocks = [...text.matchAll(/```(?:python|py)?\s*\n([\s\S]*?)```/g)].map((m) => m[1]);
  const code = blocks.length ? blocks.sort((a, b) => b.length - a.length)[0] : text;
  return code.trim() + '\n';
}
