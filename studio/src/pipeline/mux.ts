// Place each beat's narration at the time its beat actually starts in the video, mux to H.264/AAC mp4.
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { probeDuration, LEAD_IN } from './voice.js';
import type { Caption, VoicedBeat } from './types.js';

const run = promisify(execFile);

export interface MuxResult {
  duration: number;
  captions: Caption[];
}

export async function mux(video: string, beats: VoicedBeat[], marks: number[] | undefined, outPath: string): Promise<MuxResult> {
  const videoDur = await probeDuration(video);
  // Actual beat start times. marks[i] is where beat i really ended (wait_until never shortens).
  const useMarks = marks && marks.length === beats.length && marks.every((m, i) => i === 0 || m >= marks[i - 1]);
  const starts = beats.map((b, i) => (useMarks ? (i === 0 ? 0 : marks![i - 1]) : b.start));
  const offsets = starts.map((s, i) => s + (i === 0 ? LEAD_IN : 0));
  const audioEnd = offsets[offsets.length - 1] + beats[beats.length - 1].audioDur;
  const total = round(Math.max(videoDur, audioEnd + 0.4));

  const args = ['-v', 'error', '-y', '-i', video];
  for (const b of beats) args.push('-i', b.audioPath);
  const delays = beats.map((_, i) => {
    const ms = Math.round(offsets[i] * 1000);
    return `[${i + 1}:a]aresample=44100,aformat=channel_layouts=stereo,adelay=${ms}|${ms}[a${i}]`;
  });
  const mix = `${beats.map((_, i) => `[a${i}]`).join('')}amix=inputs=${beats.length}:normalize=0:dropout_transition=0,apad,atrim=0:${total}[aout]`;
  const padV = total - videoDur > 0.02 ? `tpad=stop_mode=clone:stop_duration=${(total - videoDur).toFixed(3)},` : '';
  const vf = `[0:v]${padV}format=yuv420p[vout]`;
  args.push(
    '-filter_complex', [...delays, mix, vf].join(';'),
    '-map', '[vout]', '-map', '[aout]',
    '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20', '-profile:v', 'high', '-pix_fmt', 'yuv420p',
    '-r', '30', '-c:a', 'aac', '-b:a', '160k', '-ar', '44100',
    '-t', String(total), '-movflags', '+faststart', outPath,
  );
  await run('ffmpeg', args, { maxBuffer: 10 * 1024 * 1024 });

  const captions: Caption[] = [];
  beats.forEach((b, i) => captions.push(...sentenceCaptions(b.narration, offsets[i], b.audioDur)));
  return { duration: round(await probeDuration(outPath)), captions };
}

/** Split narration into sentences and spread the clip's time across them by length. */
function sentenceCaptions(text: string, start: number, dur: number): Caption[] {
  const parts = text.match(/[^.!?]+[.!?]+["')\]]*|[^.!?]+$/g)?.map((s) => s.trim()).filter(Boolean) ?? [text];
  const total = parts.reduce((n, p) => n + p.length, 0) || 1;
  let t = start;
  return parts.map((p) => {
    const d = (dur * p.length) / total;
    const c = { start: round(t), end: round(t + d), text: p };
    t += d;
    return c;
  });
}

const round = (x: number) => Math.round(x * 100) / 100;
