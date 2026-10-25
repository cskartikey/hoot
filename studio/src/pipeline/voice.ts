// TTS per beat (in parallel; Cartesia Sonic by default, ElevenLabs Flash when asked), then exact clip durations via ffprobe.
import { execFile } from 'node:child_process';
import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { env } from '../env.js';
import type { Beat, TTSProvider, VoicedBeat } from './types.js';

const run = promisify(execFile);

export const BEAT_GAP = 0.35; // pause after each beat's narration
export const LEAD_IN = 0.3; // silence before the first beat
export const TAIL = 0.8; // hold after the last beat

/** The request's provider wins; otherwise STUDIO_TTS_PROVIDER; otherwise Cartesia. */
export function resolveTTSProvider(requested?: string): TTSProvider {
  if (requested === 'elevenlabs' || requested === 'cartesia') return requested;
  return env.ttsProvider;
}

// Lowest-latency ElevenLabs model the account can use; same one the worker's /tts uses.
const ELEVENLABS_MODEL_ID = 'eleven_flash_v2_5';

async function fetchCartesiaClip(text: string): Promise<Response> {
  return fetch('https://api.cartesia.ai/tts/bytes', {
    method: 'POST',
    signal: AbortSignal.timeout(30_000),
    headers: {
      'X-API-Key': env.cartesiaKey,
      'Cartesia-Version': '2026-08-14',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model_id: 'sonic-3.6',
      transcript: text,
      voice: { mode: 'id', id: env.cartesiaVoice },
      language: 'en',
      output_format: { container: 'mp3', sample_rate: 44100, bit_rate: 128000 },
    }),
  });
}

// Same container/sample rate/bit rate as Cartesia, so ffprobe and the mux see identical clips.
async function fetchElevenLabsClip(text: string): Promise<Response> {
  return fetch(`https://api.elevenlabs.io/v1/text-to-speech/${encodeURIComponent(env.elevenLabsVoice)}?output_format=mp3_44100_128`, {
    method: 'POST',
    signal: AbortSignal.timeout(30_000),
    headers: { 'xi-api-key': env.elevenLabsKey, 'Content-Type': 'application/json' },
    body: JSON.stringify({ text, model_id: ELEVENLABS_MODEL_ID }),
  });
}

async function tts(text: string, path: string, provider: TTSProvider): Promise<void> {
  let lastErr: unknown;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const res = provider === 'elevenlabs' ? await fetchElevenLabsClip(text) : await fetchCartesiaClip(text);
      if (!res.ok) throw new Error(`${provider === 'elevenlabs' ? 'ElevenLabs' : 'Cartesia'} ${res.status}: ${(await res.text()).slice(0, 300)}`);
      await writeFile(path, Buffer.from(await res.arrayBuffer()));
      return;
    } catch (e) {
      lastErr = e;
      await new Promise((r) => setTimeout(r, 400 * (attempt + 1)));
    }
  }
  throw lastErr;
}

export async function probeDuration(path: string): Promise<number> {
  const { stdout } = await run('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', path]);
  const d = parseFloat(stdout.trim());
  if (!Number.isFinite(d)) throw new Error(`ffprobe could not read ${path}`);
  return d;
}

export async function voiceBeats(beats: Beat[], dir: string, provider: TTSProvider = env.ttsProvider): Promise<VoicedBeat[]> {
  if (provider === 'elevenlabs' && !env.elevenLabsKey) throw new Error('ELEVENLABS_API_KEY is not set');
  if (provider === 'cartesia' && !env.cartesiaKey) throw new Error('CARTESIA_API_KEY is not set');
  const clips = await Promise.all(
    beats.map(async (b) => {
      const audioPath = join(dir, `beat${b.id}.mp3`);
      await tts(b.narration, audioPath, provider);
      return { ...b, audioPath, audioDur: await probeDuration(audioPath) };
    }),
  );
  let t = 0;
  return clips.map((c, i) => {
    const start = t;
    const lead = i === 0 ? LEAD_IN : 0;
    const end = start + lead + c.audioDur + (i === clips.length - 1 ? TAIL : BEAT_GAP);
    t = end;
    return { ...c, start, end: round(end) };
  });
}

const round = (x: number) => Math.round(x * 100) / 100;
