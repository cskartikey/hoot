# studio

Turns a learner's question into a 20-45 second narrated Manim animation. The macOS app calls it when the tutor emits `[VIDEO:brief]`.

```
POST /explain → script (LLM, 3-6 beats) → Cartesia TTS per beat (parallel) → LLM writes a Manim scene
→ render 720p30 (up to 2 LLM fixes on error) → fallback slides scene if all else fails → ffmpeg mux → mp4
```

A typical job takes 35-55 s end to end (script ~10 s, voice ~1 s, scene code ~20-30 s, render ~5 s, mux ~1 s).

## Run

Needs Node 22+, pnpm, [uv](https://docs.astral.sh/uv/), ffmpeg/ffprobe, and Cairo/Pango (`brew install pkg-config cairo pango`). LaTeX is **not** needed: the kit draws all math as Unicode text.

```sh
cd studio
pnpm install
pnpm setup:manim  # uv sync: Manim into manim/.venv
pnpm start        # http://localhost:7777  (pnpm dev = restart on change)
```

To leave it running in the background:

```sh
mkdir -p out && nohup pnpm start > out/server.log 2>&1 &
```

On start it renders a tiny scene to warm Manim, Cairo and the fonts (`/health` shows `"warm":"ready"`).

## Environment

Read at startup from the process env, then `studio/.env`, then the repo's `worker/.dev.vars` (first one wins). Keys are never logged.

| var | default | |
|---|---|---|
| `BRAIN` (or `STUDIO_BRAIN`) | `openai` | `openai` or `anthropic` |
| `OPENAI_API_KEY`, `OPENAI_MODEL` | `gpt-6.1-sol` | Chat Completions with `reasoning_effort` |
| `ANTHROPIC_API_KEY`, `ANTHROPIC_MODEL` | `claude-opus-5-5` | Messages API, adaptive thinking |
| `CARTESIA_API_KEY`, `CARTESIA_VOICE_ID` | | Sonic 3.6, same voice as the app |
| `STUDIO_PORT` | `7777` | |
| `STUDIO_PUBLIC_URL` | `http://localhost:7777` | base of the `url` in `done` |

## API

### `POST /explain`
```json
{ "question": "why does det = 0 squish space?",
  "brief": "Show a 2D grid; …",
  "spokenAnswer": "Okay, look at this grid…",
  "context": { "app": "Google Chrome",
               "youtube": { "videoId": "…", "title": "…", "t": 412.3, "transcriptWindow": "…" },
               "screenText": "…" },
  "memory": [{ "concept": "linear transformation", "summary": "…" }] }
```
Only `question` is required. Returns `{"jobId":"abc123"}` immediately.

### `GET /jobs/:id/events` (Server-Sent Events)
Replays everything so far, then streams until `done` or `error`, then closes.
```
event: stage   data: {"stage":"script","label":"Writing the explanation"}
event: script  data: {"title":"…","beats":[{"id":1,"narration":"…","visual":"…"}]}
event: stage   data: {"stage":"voice","label":"Recording narration"}
event: stage   data: {"stage":"render","label":"Animating","attempt":1}
event: stage   data: {"stage":"render","label":"Fixing animation","attempt":2}      (only on a failed render)
event: done    data: {"url":"http://localhost:7777/jobs/abc123/video.mp4","duration":31.2,
                      "captions":[{"start":0.3,"end":2.1,"text":"…"}],"fallback":false}
event: error   data: {"message":"…"}
```
`captions` are sentence-level, timed to where each beat's audio actually sits in the video. `fallback: true` means the animated-text fallback was used.

### `GET /jobs/:id/video.mp4`
H.264 High / yuv420p / AAC 44.1 kHz, `+faststart`, 1280x720 30 fps. Supports `Range` (AVPlayer needs it). 409 while not ready.

### `GET /jobs/:id`
Debug summary: outcome (`first` / `fixed` / `fallback`), timings, errors, events.

### `GET /health`
`{"ok":true,"warm":"ready","brain":"openai","model":"…","openai":true,"anthropic":false,"cartesia":true}`

## How sync works

Each beat's slot is its narration length plus a short pause. The scene prompt gets the cumulative end times as `T = [...]`, and the generated code calls `wait_until(self, T[i])` at the end of every beat. `wait_until` pads with `self.wait` and records the scene time it actually reached. If a beat's animations run long, the mux places that beat's narration where the beat really starts instead of drifting, and the last frame is held if the audio runs past the video.

## Layout

```
src/server.ts            HTTP + SSE
src/jobs.ts              in-memory jobs with an event log
src/llm.ts               OpenAI / Anthropic switch
src/pipeline/            script, voice, scene, render, mux, index (orchestration)
src/prompts/             script.md, scene.md, fix.md
manim/kit.py             16:9 style kit (written at Cal Hacks 13.0): hoot palette, helpers, MathTex/DecimalNumber→Text shims
manim/fonts/             JetBrains Mono (OFL), same files as the app
manim/KIT_API.md         kit docs pasted into the scene prompt
manim/templates/*.py     transform, derivation, process, compare (few-shot examples)
manim/fallback.py        beats as animated text; never fails
manim/runner.py          renders a scene with plain tracebacks
test/questions.json      5 fixed test questions
test/run.ts              pnpm test:questions [--parallel] [--only a,b]
test/paths.ts            exercise the fix and fallback paths on a finished job
out/<jobId>/             per-job files: script, beats, audio, scene_N.py, error_N.txt, video.mp4
```

## Known limitations

- Jobs live in memory; finished mp4s are still served from `out/` after a restart.
- No LaTeX: math is Unicode text, so stacked fractions and big matrices are drawn as `a/b` and the kit's `matrix()`.
- The scene model can still produce layouts with small overlaps; the prompt asks for a region plan and the kit has `fit`/`keep_in_frame`, but nothing checks the frames.
- Renders run in parallel with no queue; several jobs at once share the CPU.
- `POST /explain/:id/continue` and memory endpoints from the plan are not built yet.
